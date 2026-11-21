package routes

import (
	"context"
	"encoding/base32"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/services"
)

const goodPassword = "correct horse battery"

// secondsAhead moves the server's clock, and puts it back after the test.
func clockAt(t *testing.T, at time.Time) {
	t.Helper()
	old := services.TOTPNow
	services.TOTPNow = func() time.Time { return at }
	t.Cleanup(func() { services.TOTPNow = old })
}

type twoFactorFixture struct {
	user   *models.User
	token  string
	secret []byte
	codes  []string
	base   time.Time
}

func (f *twoFactorFixture) code(stepsAhead int64) string {
	return services.TOTPCode(f.secret, f.base.Unix()/30+stepsAhead)
}

func data(t *testing.T, resp models.JSONResponse) map[string]interface{} {
	t.Helper()
	m, _ := resp.Data.(map[string]interface{})
	return m
}

func decodeSecret(t *testing.T, text string) []byte {
	t.Helper()
	// base32 without padding
	pad := strings.Repeat("=", (8-len(text)%8)%8)
	raw, err := base32.StdEncoding.DecodeString(text + pad)
	if err != nil {
		t.Fatalf("secret %q: %v", text, err)
	}
	return raw
}

// setUpTwoFactor signs up, and turns two-step sign-in on.
func setUpTwoFactor(t *testing.T) *twoFactorFixture {
	t.Helper()
	user, token := realUser(t, uniquePrefix(t))
	f := &twoFactorFixture{user: user, token: token, base: time.Now()}
	clockAt(t, f.base)

	code, resp := callJSON(t, "POST", "/api/users/me/2fa/setup", token, nil)
	if code != http.StatusOK {
		t.Fatalf("setup: %d %+v", code, resp)
	}
	d := data(t, resp)
	f.secret = decodeSecret(t, d["secret"].(string))
	if uri, _ := d["otpauth_uri"].(string); !strings.HasPrefix(uri, "otpauth://totp/Elephant:") {
		t.Fatalf("uri %v", d["otpauth_uri"])
	}

	code, resp = callJSON(t, "POST", "/api/users/me/2fa/enable", token, map[string]string{"code": f.code(0)})
	if code != http.StatusOK {
		t.Fatalf("enable: %d %+v", code, resp)
	}
	for _, c := range data(t, resp)["recovery_codes"].([]interface{}) {
		f.codes = append(f.codes, c.(string))
	}
	if len(f.codes) != 10 {
		t.Fatalf("%d recovery codes", len(f.codes))
	}
	return f
}

func login(t *testing.T, f *twoFactorFixture) (int, models.JSONResponse) {
	t.Helper()
	return callJSON(t, "POST", "/api/auth/login", "", map[string]string{
		"username": f.user.Username, "password": goodPassword, "device_name": "Pixel 8",
	})
}

func TestSigningInWithoutTwoStepIsUnchanged(t *testing.T) {
	user, _ := realUser(t, uniquePrefix(t))
	code, resp := callJSON(t, "POST", "/api/auth/login", "", map[string]string{"username": user.Username, "password": goodPassword})
	d := data(t, resp)
	if code != http.StatusOK || d["tokens"] == nil || d["two_factor_required"] != nil {
		t.Errorf("a normal sign-in: %d %+v", code, d)
	}
}

func TestSettingUpTwoStepSignIn(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	clockAt(t, time.Now())

	_, resp := callJSON(t, "GET", "/api/users/me/2fa", token, nil)
	if d := data(t, resp); d["enabled"] != false || d["recovery_codes_left"] != float64(0) {
		t.Fatalf("status before: %+v", d)
	}

	// It isn't on after setup alone: a password is still enough to sign in.
	callJSON(t, "POST", "/api/users/me/2fa/setup", token, nil)
	_, resp = callJSON(t, "POST", "/api/auth/login", "", map[string]string{"username": user.Username, "password": goodPassword})
	if data(t, resp)["tokens"] == nil {
		t.Error("two-step sign-in was on before a code was confirmed")
	}

	// A wrong code doesn't turn it on.
	if code, _ := callJSON(t, "POST", "/api/users/me/2fa/enable", token, map[string]string{"code": "000000"}); code != http.StatusUnauthorized {
		t.Errorf("a wrong code: %d, want 401", code)
	}
	_, resp = callJSON(t, "GET", "/api/users/me/2fa", token, nil)
	if data(t, resp)["enabled"] != false {
		t.Error("enabled with a wrong code")
	}
}

func TestEnablingNeedsSetupFirstAndCannotBeDoneTwice(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	clockAt(t, time.Now())
	if code, _ := callJSON(t, "POST", "/api/users/me/2fa/enable", token, map[string]string{"code": "123456"}); code != http.StatusBadRequest {
		t.Errorf("enabling before setup: %d, want 400", code)
	}
	if code, _ := callJSON(t, "POST", "/api/users/me/2fa/enable", token, map[string]string{}); code != http.StatusBadRequest {
		t.Errorf("enabling with no code: %d, want 400", code)
	}

	f := setUpTwoFactor(t)
	if code, _ := callJSON(t, "POST", "/api/users/me/2fa/setup", f.token, nil); code != http.StatusConflict {
		t.Errorf("setting up again while on: %d, want 409", code)
	}
	if code, _ := callJSON(t, "POST", "/api/users/me/2fa/enable", f.token, map[string]string{"code": f.code(1)}); code != http.StatusConflict {
		t.Errorf("enabling twice: %d, want 409", code)
	}
	_, resp := callJSON(t, "GET", "/api/users/me/2fa", f.token, nil)
	if d := data(t, resp); d["enabled"] != true || d["recovery_codes_left"] != float64(10) {
		t.Errorf("status after: %+v", d)
	}
}

func TestSigningInNeedsACodeAfterThePassword(t *testing.T) {
	f := setUpTwoFactor(t)

	code, resp := login(t, f)
	d := data(t, resp)
	if code != http.StatusOK || d["two_factor_required"] != true || d["tokens"] != nil || d["user"] != nil {
		t.Fatalf("after the password: %d %+v", code, d)
	}
	challenge := d["challenge"].(string)

	// A wrong password gets no challenge.
	wrong, _ := callJSON(t, "POST", "/api/auth/login", "", map[string]string{"username": f.user.Username, "password": "not the password"})
	if wrong != http.StatusUnauthorized {
		t.Errorf("a wrong password: %d", wrong)
	}

	// The code finishes it. (The code used to turn it on is spent, so the next
	// step's code, which the server allows for a clock a little fast.)
	code, resp = callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{
		"challenge": challenge, "code": f.code(1), "device_name": "Pixel 8",
	})
	d = data(t, resp)
	if code != http.StatusOK || d["tokens"] == nil {
		t.Fatalf("with the code: %d %+v", code, resp)
	}
	user, _ := d["user"].(map[string]interface{})
	if user["id"] != f.user.ID {
		t.Errorf("signed in as %v", user["id"])
	}
	tokens := d["tokens"].(map[string]interface{})
	if c, _ := callJSON(t, "GET", "/api/users/me", tokens["access_token"].(string), nil); c != http.StatusOK {
		t.Errorf("the new access token doesn't work: %d", c)
	}
}

func TestACodeCannotBeUsedTwice(t *testing.T) {
	f := setUpTwoFactor(t)
	d := data(t, func() models.JSONResponse { _, r := login(t, f); return r }())
	challenge := d["challenge"].(string)

	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": challenge, "code": f.code(1)}); c != http.StatusOK {
		t.Fatalf("first use: %d", c)
	}
	d = data(t, func() models.JSONResponse { _, r := login(t, f); return r }())
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": d["challenge"].(string), "code": f.code(1)}); c != http.StatusUnauthorized {
		t.Errorf("the same code again: %d, want 401", c)
	}
	// Nor the one used to turn it on.
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": d["challenge"].(string), "code": f.code(0)}); c != http.StatusUnauthorized {
		t.Errorf("the code from setup: %d, want 401", c)
	}
}

func TestRecoveryCodesWorkOnce(t *testing.T) {
	f := setUpTwoFactor(t)
	fresh := func() string {
		_, r := login(t, f)
		return data(t, r)["challenge"].(string)
	}
	use := func(code string) int {
		c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": fresh(), "code": code})
		return c
	}
	if c := use(f.codes[0]); c != http.StatusOK {
		t.Fatalf("a recovery code: %d", c)
	}
	if c := use(f.codes[0]); c != http.StatusUnauthorized {
		t.Errorf("the same recovery code again: %d, want 401", c)
	}
	if c := use(strings.ToUpper(strings.ReplaceAll(f.codes[1], "-", " "))); c != http.StatusOK {
		t.Errorf("a recovery code typed in capitals: %d", c)
	}
	_, resp := callJSON(t, "GET", "/api/users/me/2fa", f.token, nil)
	if d := data(t, resp); d["recovery_codes_left"] != float64(8) {
		t.Errorf("codes left: %v, want 8", d["recovery_codes_left"])
	}
}

func TestTooManyWrongCodesLockCodeEntry(t *testing.T) {
	f := setUpTwoFactor(t)
	challenge := func() string { _, r := login(t, f); return data(t, r)["challenge"].(string) }

	for i := 0; i < 5; i++ {
		c, resp := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": challenge(), "code": "000000"})
		want := http.StatusUnauthorized
		if i == 4 {
			want = http.StatusTooManyRequests
		}
		if c != want {
			t.Fatalf("wrong code %d: %d %q, want %d", i+1, c, resp.Error, want)
		}
	}
	// Even the right code is refused while it is locked.
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": challenge(), "code": f.code(1)}); c != http.StatusTooManyRequests {
		t.Errorf("a right code while locked: %d, want 429", c)
	}
	// After the lock ends, the right code works and the count starts again.
	clockAt(t, f.base.Add(16*time.Minute))
	fresh := challenge()
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": fresh, "code": services.TOTPCode(f.secret, f.base.Add(16*time.Minute).Unix()/30)}); c != http.StatusOK {
		t.Errorf("after the lock: %d, want 200", c)
	}
}

func TestAWrongCodeDoesNotCountAfterARightOne(t *testing.T) {
	f := setUpTwoFactor(t)
	challenge := func() string { _, r := login(t, f); return data(t, r)["challenge"].(string) }
	for i := 0; i < 4; i++ {
		callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": challenge(), "code": "000000"})
	}
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": challenge(), "code": f.code(1)}); c != http.StatusOK {
		t.Fatalf("a right code after 4 wrong ones: %d", c)
	}
	for i := 0; i < 4; i++ {
		if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": challenge(), "code": "000000"}); c != http.StatusUnauthorized {
			t.Fatalf("wrong code %d after a success: %d, want 401 (the count restarts)", i+1, c)
		}
	}
}

func TestTheSignInStepMustBeGenuineAndFresh(t *testing.T) {
	f := setUpTwoFactor(t)
	_, r := login(t, f)
	challenge := data(t, r)["challenge"].(string)

	for name, bad := range map[string]string{"empty": "", "made up": "abc.def.ghi", "altered": challenge + "x"} {
		c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": bad, "code": f.code(1)})
		want := http.StatusUnauthorized
		if bad == "" {
			want = http.StatusBadRequest
		}
		if c != want {
			t.Errorf("%s: %d, want %d", name, c, want)
		}
	}

	// An access token is not a sign-in step.
	pair := startSession(t, f.user.ID, "x")
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{"challenge": pair.AccessToken, "code": f.code(1)}); c != http.StatusUnauthorized {
		t.Errorf("an access token as a challenge: %d, want 401", c)
	}
	// And the other way round: a sign-in step is not an access token.
	if c, _ := callJSON(t, "GET", "/api/users/me", challenge, nil); c != http.StatusUnauthorized {
		t.Errorf("a challenge used as an access token: %d, want 401", c)
	}

	// It runs out after five minutes.
	clockAt(t, f.base.Add(6*time.Minute))
	if c, _ := callJSON(t, "POST", "/api/auth/login/2fa", "", map[string]string{
		"challenge": challenge, "code": services.TOTPCode(f.secret, f.base.Add(6*time.Minute).Unix()/30),
	}); c != http.StatusUnauthorized {
		t.Errorf("an old challenge: %d, want 401", c)
	}
}

func TestTurningItOffNeedsThePasswordAndACode(t *testing.T) {
	f := setUpTwoFactor(t)
	off := func(password, code string) int {
		c, _ := callJSON(t, "POST", "/api/users/me/2fa/disable", f.token, map[string]string{"password": password, "code": code})
		return c
	}
	if c := off("not the password", f.code(1)); c != http.StatusUnauthorized {
		t.Errorf("a wrong password: %d, want 401", c)
	}
	if c := off(goodPassword, "000000"); c != http.StatusUnauthorized {
		t.Errorf("a wrong code: %d, want 401", c)
	}
	if c := off(goodPassword, ""); c != http.StatusBadRequest {
		t.Errorf("no code: %d, want 400", c)
	}
	if c := off("", f.code(1)); c != http.StatusBadRequest {
		t.Errorf("no password: %d, want 400", c)
	}
	_, resp := callJSON(t, "GET", "/api/users/me/2fa", f.token, nil)
	if data(t, resp)["enabled"] != true {
		t.Fatal("it was turned off by a refused request")
	}

	if c := off(goodPassword, f.code(1)); c != http.StatusOK {
		t.Fatalf("with both: %d", c)
	}
	_, resp = callJSON(t, "GET", "/api/users/me/2fa", f.token, nil)
	if data(t, resp)["enabled"] != false {
		t.Error("still on")
	}
	// Signing in is back to a password.
	_, resp = login(t, f)
	if data(t, resp)["tokens"] == nil {
		t.Error("a password alone doesn't sign in after turning it off")
	}
	var n int
	_ = config.DB.QueryRow(context.Background(),
		`SELECT count(*) FROM two_factor_recovery_codes WHERE user_id = $1::uuid`, f.user.ID).Scan(&n)
	if n != 0 {
		t.Errorf("%d recovery codes left behind", n)
	}
}

func TestARecoveryCodeCanTurnItOffToo(t *testing.T) {
	f := setUpTwoFactor(t)
	c, _ := callJSON(t, "POST", "/api/users/me/2fa/disable", f.token, map[string]string{"password": goodPassword, "code": f.codes[3]})
	if c != http.StatusOK {
		t.Errorf("turning it off with a recovery code: %d", c)
	}
}

func TestAccountsWithoutAPasswordCannotSetItUp(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	if _, err := config.DB.Exec(context.Background(),
		`UPDATE users SET password_hash = 'OAUTH_PASSWORDLESS' WHERE id = $1::uuid`, user.ID); err != nil {
		t.Fatal(err)
	}
	if c, _ := callJSON(t, "POST", "/api/users/me/2fa/setup", token, nil); c != http.StatusBadRequest {
		t.Errorf("setup for an account with no password: %d, want 400", c)
	}
}

func TestTheSecretIsNotStoredInThePlain(t *testing.T) {
	f := setUpTwoFactor(t)
	var sealed []byte
	if err := config.DB.QueryRow(context.Background(),
		`SELECT secret_enc FROM user_two_factor WHERE user_id = $1::uuid`, f.user.ID).Scan(&sealed); err != nil {
		t.Fatal(err)
	}
	if len(sealed) == 0 || strings.Contains(string(sealed), string(f.secret)) {
		t.Error("the secret is stored in the plain")
	}
	opened, err := services.DecryptTOTPSecret(sealed, f.user.ID)
	if err != nil || string(opened) != string(f.secret) {
		t.Errorf("it doesn't open: %v", err)
	}
}

func TestTwoStepEndpointsNeedASignedInUser(t *testing.T) {
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/users/me/2fa"}, {"POST", "/api/users/me/2fa/setup"},
		{"POST", "/api/users/me/2fa/enable"}, {"POST", "/api/users/me/2fa/disable"},
	} {
		if code, _ := callJSON(t, c.method, c.path, "", nil); code != http.StatusUnauthorized {
			t.Errorf("%s %s without a token: %d", c.method, c.path, code)
		}
	}
}
