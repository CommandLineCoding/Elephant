package services

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // RFC 6238 authenticator apps use HMAC-SHA1
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
)

// Time-based one-time passwords as authenticator apps make them (RFC 6238):
// HMAC-SHA1, 30 second steps, 6 digits.
const (
	totpPeriod = 30
	totpDigits = 6
)

// TOTPNow is the clock for codes and sign-in steps. A variable so a test can move it.
var TOTPNow = time.Now

var totpEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// NewTOTPSecret makes a random 160 bit secret.
func NewTOTPSecret() ([]byte, error) {
	secret := make([]byte, 20)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	return secret, nil
}

// TOTPSecretText is a secret as an authenticator app asks for it: base32.
func TOTPSecretText(secret []byte) string { return totpEncoding.EncodeToString(secret) }

// TOTPURI is the otpauth:// address an authenticator app scans as a QR code.
func TOTPURI(secret []byte, username string) string {
	label := url.PathEscape("Elephant:" + username)
	q := url.Values{}
	q.Set("secret", TOTPSecretText(secret))
	q.Set("issuer", "Elephant")
	q.Set("algorithm", "SHA1")
	q.Set("digits", fmt.Sprint(totpDigits))
	q.Set("period", fmt.Sprint(totpPeriod))
	return "otpauth://totp/" + label + "?" + q.Encode()
}

// totpStep is the 30 second step that contains t.
func totpStep(t time.Time) int64 { return t.Unix() / totpPeriod }

// TOTPCode is the code for a step.
func TOTPCode(secret []byte, step int64) string {
	mac := hmac.New(sha1.New, secret) //nolint:gosec
	var counter [8]byte
	binary.BigEndian.PutUint64(counter[:], uint64(step))
	mac.Write(counter[:])
	sum := mac.Sum(nil)

	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	mod := uint32(1)
	for i := 0; i < totpDigits; i++ {
		mod *= 10
	}
	return fmt.Sprintf("%0*d", totpDigits, value%mod)
}

// VerifyTOTP checks a code against the current step and one either side, to
// allow for a clock that is a little off. A step at or before lastUsedStep is
// refused, so a code works once. It returns the step that matched.
func VerifyTOTP(secret []byte, code string, lastUsedStep int64) (int64, bool) {
	code = strings.ReplaceAll(strings.TrimSpace(code), " ", "")
	if len(code) != totpDigits {
		return 0, false
	}
	now := totpStep(TOTPNow())
	matched := int64(-1)
	// Every step is compared, whichever matches, so the time taken doesn't
	// say how close a guess was.
	for step := now - 1; step <= now+1; step++ {
		if subtle.ConstantTimeCompare([]byte(TOTPCode(secret, step)), []byte(code)) == 1 && step > lastUsedStep {
			matched = step
		}
	}
	return matched, matched >= 0
}

// totpKey is what secrets are encrypted with.
func totpKey() [32]byte {
	source := env.TOTP_ENCRYPTION_KEY
	if source == "" {
		source = env.JWT_SECRET
	}
	return sha256.Sum256([]byte("elephant-totp-secret:" + source))
}

// EncryptTOTPSecret seals a secret for the database (AES-256-GCM, with the
// nonce in front). The user ID is bound in, so a sealed secret copied to
// another account doesn't open.
func EncryptTOTPSecret(secret []byte, userID string) ([]byte, error) {
	key := totpKey()
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, secret, []byte(strings.ToLower(userID))), nil
}

// DecryptTOTPSecret opens what EncryptTOTPSecret sealed.
func DecryptTOTPSecret(sealed []byte, userID string) ([]byte, error) {
	key := totpKey()
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(sealed) < gcm.NonceSize() {
		return nil, errors.New("sealed secret is too short")
	}
	nonce, body := sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():]
	return gcm.Open(nil, nonce, body, []byte(strings.ToLower(userID)))
}

// RecoveryCodeCount is how many one-time codes setup gives.
const RecoveryCodeCount = 10

// recoveryAlphabet has no 0, 1, i, l, o or u, which are easy to misread.
const recoveryAlphabet = "23456789abcdefghjkmnpqrstvwxyz"

// NewRecoveryCodes makes the one-time codes, like "k3f9-p2mx".
func NewRecoveryCodes() ([]string, error) {
	codes := make([]string, RecoveryCodeCount)
	for i := range codes {
		raw := make([]byte, 8)
		if _, err := rand.Read(raw); err != nil {
			return nil, err
		}
		chars := make([]byte, 8)
		for j, b := range raw {
			chars[j] = recoveryAlphabet[int(b)%len(recoveryAlphabet)]
		}
		codes[i] = string(chars[:4]) + "-" + string(chars[4:])
	}
	return codes, nil
}

// NormalizeRecoveryCode lowercases a code and drops spaces and dashes.
func NormalizeRecoveryCode(code string) string {
	code = strings.ToLower(strings.TrimSpace(code))
	return strings.NewReplacer("-", "", " ", "").Replace(code)
}

// HashRecoveryCode is what is stored for a code. The codes have about 38 bits
// of randomness and are single use, and attempts are limited, so a plain hash
// is enough.
func HashRecoveryCode(code string) string {
	sum := sha256.Sum256([]byte("elephant-recovery:" + NormalizeRecoveryCode(code)))
	return hex.EncodeToString(sum[:])
}
