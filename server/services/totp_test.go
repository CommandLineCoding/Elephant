package services

import (
	"encoding/base32"
	"net/url"
	"strings"
	"testing"
	"time"
)

// RFC 6238 appendix B: the SHA-1 secret "12345678901234567890". The RFC lists
// 8 digit codes; the last 6 digits are the 6 digit code.
func TestCodesMatchTheRFCExamples(t *testing.T) {
	secret := []byte("12345678901234567890")
	cases := map[int64]string{
		59:          "287082",
		1111111109:  "081804",
		1111111111:  "050471",
		1234567890:  "005924",
		2000000000:  "279037",
		20000000000: "353130",
	}
	for unix, want := range cases {
		if got := TOTPCode(secret, unix/30); got != want {
			t.Errorf("at %d: %s, want %s", unix, got, want)
		}
	}
}

func atTime(t *testing.T, unix int64) {
	t.Helper()
	old := TOTPNow
	TOTPNow = func() time.Time { return time.Unix(unix, 0) }
	t.Cleanup(func() { TOTPNow = old })
}

func TestACodeIsAcceptedOneStepEitherSideAndNoFurther(t *testing.T) {
	secret := []byte("12345678901234567890")
	atTime(t, 1111111109)
	now := int64(1111111109 / 30)
	for _, c := range []struct {
		name string
		step int64
		ok   bool
	}{
		{"this step", now, true},
		{"the step before", now - 1, true},
		{"the step after", now + 1, true},
		{"two steps back", now - 2, false},
		{"two steps ahead", now + 2, false},
	} {
		step, ok := VerifyTOTP(secret, TOTPCode(secret, c.step), 0)
		if ok != c.ok || (ok && step != c.step) {
			t.Errorf("%s: step=%d ok=%v, want ok=%v", c.name, step, ok, c.ok)
		}
	}
}

func TestACodeWorksOnce(t *testing.T) {
	secret := []byte("12345678901234567890")
	atTime(t, 1111111109)
	now := int64(1111111109 / 30)
	step, ok := VerifyTOTP(secret, TOTPCode(secret, now), 0)
	if !ok {
		t.Fatal("a right code was refused")
	}
	if _, again := VerifyTOTP(secret, TOTPCode(secret, now), step); again {
		t.Error("the same code was accepted twice")
	}
	if _, earlier := VerifyTOTP(secret, TOTPCode(secret, now-1), step); earlier {
		t.Error("a code from before the last one used was accepted")
	}
	if _, next := VerifyTOTP(secret, TOTPCode(secret, now+1), step); !next {
		t.Error("the next step's code was refused")
	}
}

func TestBadCodesAreRefused(t *testing.T) {
	secret := []byte("12345678901234567890")
	atTime(t, 1111111109)
	good := TOTPCode(secret, 1111111109/30)
	for name, code := range map[string]string{
		"empty": "", "short": good[:5], "long": good + "0", "letters": "abcdef",
		"someone else's": "000000",
	} {
		if code == good {
			continue
		}
		if _, ok := VerifyTOTP(secret, code, 0); ok {
			t.Errorf("%s was accepted", name)
		}
	}
	if _, ok := VerifyTOTP(secret, " "+good[:3]+" "+good[3:]+" ", 0); !ok {
		t.Error("a code typed with spaces was refused")
	}
}

func TestTheAppURI(t *testing.T) {
	secret := []byte("12345678901234567890")
	uri := TOTPURI(secret, "maya.1234")
	u, err := url.Parse(uri)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if u.Scheme != "otpauth" || u.Host != "totp" || !strings.HasSuffix(u.Path, "Elephant:maya.1234") {
		t.Errorf("uri %s", uri)
	}
	if q.Get("secret") != "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" || q.Get("issuer") != "Elephant" ||
		q.Get("digits") != "6" || q.Get("period") != "30" || q.Get("algorithm") != "SHA1" {
		t.Errorf("query %v", q)
	}
	if _, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(TOTPSecretText(secret)); err != nil {
		t.Errorf("the secret isn't base32: %v", err)
	}
}

func TestSecretsAreRandomAndSealedPerAccount(t *testing.T) {
	a, _ := NewTOTPSecret()
	b, _ := NewTOTPSecret()
	if len(a) != 20 || string(a) == string(b) {
		t.Errorf("secrets %x %x", a, b)
	}

	sealed, err := EncryptTOTPSecret(a, "User-One")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(sealed), string(a)) {
		t.Error("the sealed secret contains the secret")
	}
	again, _ := EncryptTOTPSecret(a, "User-One")
	if string(again) == string(sealed) {
		t.Error("sealing twice gave the same bytes, so the nonce isn't random")
	}
	opened, err := DecryptTOTPSecret(sealed, "user-one")
	if err != nil || string(opened) != string(a) {
		t.Errorf("opened %x, %v", opened, err)
	}
	if _, err := DecryptTOTPSecret(sealed, "user-two"); err == nil {
		t.Error("a secret opened for another account")
	}
	tampered := append([]byte(nil), sealed...)
	tampered[len(tampered)-1] ^= 1
	if _, err := DecryptTOTPSecret(tampered, "user-one"); err == nil {
		t.Error("a changed secret opened")
	}
	if _, err := DecryptTOTPSecret([]byte("short"), "user-one"); err == nil {
		t.Error("a truncated secret opened")
	}
}

func TestRecoveryCodes(t *testing.T) {
	codes, err := NewRecoveryCodes()
	if err != nil || len(codes) != RecoveryCodeCount {
		t.Fatalf("codes %v %v", codes, err)
	}
	seen := map[string]bool{}
	for _, c := range codes {
		if len(c) != 9 || c[4] != '-' || seen[c] {
			t.Errorf("odd or repeated code %q", c)
		}
		seen[c] = true
		if strings.ContainsAny(c, "01ilou") {
			t.Errorf("%q has a character that is easy to misread", c)
		}
	}
	c := codes[0]
	if HashRecoveryCode(c) != HashRecoveryCode(strings.ToUpper(strings.ReplaceAll(c, "-", " "))) {
		t.Error("typing it in capitals, with a space, gives a different hash")
	}
	if HashRecoveryCode(c) == HashRecoveryCode(codes[1]) || HashRecoveryCode(c) == c {
		t.Error("hashes collide or are the code")
	}
}
