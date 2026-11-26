package routes

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
)

func exportFor(t *testing.T, token string) (int, string, models.AccountExport) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/users/me/export", nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	newTestRouter().ServeHTTP(w, req)

	var resp struct {
		Success bool                 `json:"success"`
		Data    models.AccountExport `json:"data"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if w.Code == http.StatusOK && w.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("an export may be cached: Cache-Control %q", w.Header().Get("Cache-Control"))
	}
	return w.Code, w.Body.String(), resp.Data
}

func mustExec(t *testing.T, sql string, args ...interface{}) {
	t.Helper()
	if _, err := config.DB.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func TestTheExportNeedsASignedInUser(t *testing.T) {
	if code, _, _ := exportFor(t, ""); code != http.StatusUnauthorized {
		t.Errorf("without a token: %d, want 401", code)
	}
}

func TestTheExportHasWhatTheServerKeepsAboutThePerson(t *testing.T) {
	me, friend, stranger := sessionUser(t), sessionUser(t), sessionUser(t)
	tok := startSession(t, me, "Pixel 8").AccessToken

	mustExec(t, `UPDATE users SET bio = 'Hiker', status_emoji = '🏔', status_text = 'Away' WHERE id = $1::uuid`, me)
	mustExec(t, `INSERT INTO user_settings (user_id, online_status) VALUES ($1::uuid, 'nobody')`, me)
	mustExec(t, `INSERT INTO blocked_users (user_id, blocked_user_id) VALUES ($1::uuid, $2::uuid)`, me, stranger)
	mustExec(t, `INSERT INTO messages (sender_id, receiver_id, content) VALUES ($1::uuid, $2::uuid, 'sent by me')`, me, friend)
	mustExec(t, `INSERT INTO messages (sender_id, receiver_id, content) VALUES ($1::uuid, $2::uuid, 'sent to me')`, friend, me)
	// Someone else's chat is not in it.
	mustExec(t, `INSERT INTO messages (sender_id, receiver_id, content) VALUES ($1::uuid, $2::uuid, 'not mine')`, friend, stranger)

	var group string
	if err := config.DB.QueryRow(context.Background(),
		`INSERT INTO groups (name, created_by) VALUES ('Trek', $1::uuid) RETURNING id::text`, me).Scan(&group); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), `DELETE FROM groups WHERE id = $1::uuid`, group) })
	mustExec(t, `INSERT INTO group_members (group_id, user_id, role) VALUES ($1::uuid, $2::uuid, 'admin'), ($1::uuid, $3::uuid, 'member')`, group, me, friend)
	mustExec(t, `INSERT INTO messages (sender_id, group_id, content) VALUES ($1::uuid, $2::uuid, 'my group message')`, me, group)
	mustExec(t, `INSERT INTO messages (sender_id, group_id, content) VALUES ($1::uuid, $2::uuid, 'their group message')`, friend, group)
	mustExec(t, `INSERT INTO reports (reporter_id, reported_user_id, reason, note) VALUES ($1::uuid, $2::uuid, 'spam', 'ads')`, me, stranger)

	code, _, got := exportFor(t, tok)
	if code != http.StatusOK {
		t.Fatalf("export: %d", code)
	}
	if got.App != "elephant" || got.Format != models.ExportFormat || got.ExportedAt.IsZero() {
		t.Errorf("header: %q %d %v", got.App, got.Format, got.ExportedAt)
	}
	if got.Account.ID != me || got.Account.Bio != "Hiker" || got.Account.StatusText != "Away" {
		t.Errorf("account: %+v", got.Account)
	}
	if got.Settings.OnlineStatus != "nobody" || !got.Settings.ReadReceipts {
		t.Errorf("settings: %+v", got.Settings)
	}
	if len(got.Sessions) != 1 || got.Sessions[0].DeviceName != "Pixel 8" {
		t.Errorf("sessions: %+v", got.Sessions)
	}
	if len(got.Blocked) != 1 || got.Blocked[0].UserID != stranger {
		t.Errorf("blocked: %+v", got.Blocked)
	}
	if len(got.Groups) != 1 || got.Groups[0].ID != group || got.Groups[0].Role != "admin" {
		t.Errorf("groups: %+v", got.Groups)
	}
	if len(got.Reports) != 1 || got.Reports[0].ReportedUserID != stranger || got.Reports[0].Note != "ads" {
		t.Errorf("reports: %+v", got.Reports)
	}

	var contents []string
	for _, m := range got.Messages {
		contents = append(contents, m.Content)
	}
	if strings.Join(contents, "|") != "sent by me|sent to me|my group message" {
		t.Errorf("messages: %q", contents)
	}
}

func TestTheExportLeavesOutSecrets(t *testing.T) {
	me := sessionUser(t)
	pair := startSession(t, me, "Pixel 8")

	const (
		password = "$argon2id$v=19$the-password-hash"
		endpoint = "https://push.example.org/the-secret-endpoint"
		recovery = "the-recovery-code-hash"
	)
	mustExec(t, `UPDATE users SET password_hash = $2 WHERE id = $1::uuid`, me, password)
	mustExec(t, `INSERT INTO push_endpoints (user_id, endpoint) VALUES ($1::uuid, $2)`, me, endpoint)
	mustExec(t, `INSERT INTO user_two_factor (user_id, secret_enc, enabled) VALUES ($1::uuid, 'the-totp-secret'::bytea, TRUE)`, me)
	mustExec(t, `INSERT INTO two_factor_recovery_codes (user_id, code_hash) VALUES ($1::uuid, $2)`, me, recovery)

	var tokenHash string
	if err := config.DB.QueryRow(context.Background(),
		`SELECT token_hash FROM refresh_tokens WHERE user_id = $1::uuid`, me).Scan(&tokenHash); err != nil {
		t.Fatal(err)
	}

	code, body, got := exportFor(t, pair.AccessToken)
	if code != http.StatusOK {
		t.Fatalf("export: %d", code)
	}
	for name, secret := range map[string]string{
		"password hash": password,
		"push endpoint": endpoint,
		"2fa secret":    "the-totp-secret",
		"recovery code": recovery,
		"refresh token": pair.RefreshToken,
		"token hash":    tokenHash,
	} {
		if strings.Contains(body, secret) {
			t.Errorf("the export has the %s", name)
		}
	}
	// What they are for is still there.
	if !got.TwoFactor.Enabled || got.TwoFactor.RecoveryCodesLeft != 1 || len(got.Push) != 1 {
		t.Errorf("two_factor %+v, push %+v", got.TwoFactor, got.Push)
	}
}
