package routes

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
)

func exportFor(t *testing.T, token string) (int, string, models.AccountExport) {
	t.Helper()
	return exportWith(t, token, "")
}

func exportWith(t *testing.T, token, query string) (int, string, models.AccountExport) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/users/me/export?"+query, nil)
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
	mustExec(t, `INSERT INTO message_hides (user_id, message_id) SELECT $1::uuid, id FROM messages WHERE content = 'sent to me' AND receiver_id = $1::uuid`, me)

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

	// By default only what the person said in groups: direct messages are
	// ciphertext they can't read.
	if c := messageContents(got.Messages); c != "my group message" {
		t.Errorf("messages: %q", c)
	}
	if got.MessagesTruncated || got.MessagesNext != nil {
		t.Errorf("a few messages are cut: truncated %v, next %v", got.MessagesTruncated, got.MessagesNext)
	}

	code, _, got = exportWith(t, tok, "include=direct_messages")
	if code != http.StatusOK {
		t.Fatalf("export with direct messages: %d", code)
	}
	if c := messageContents(got.Messages); c != "sent by me|sent to me|my group message" {
		t.Errorf("messages with direct messages: %q", c)
	}
	for _, m := range got.Messages {
		if m.Hidden != (m.Content == "sent to me") {
			t.Errorf("%q hidden: %v", m.Content, m.Hidden)
		}
	}
}

func messageContents(messages []models.ExportMessage) string {
	var contents []string
	for _, m := range messages {
		contents = append(contents, m.Content)
	}
	return strings.Join(contents, "|")
}

func exportPage(t *testing.T, token, query string) (int, models.ExportMessagePage) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/users/me/export/messages?"+query, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	newTestRouter().ServeHTTP(w, req)

	var resp struct {
		Data models.ExportMessagePage `json:"data"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if w.Code == http.StatusOK && w.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("a page may be cached: Cache-Control %q", w.Header().Get("Cache-Control"))
	}
	return w.Code, resp.Data
}

// A big account comes out in bounded pages: the export has the first one and
// a cursor, and following the cursors gives every message once, in order,
// even when many share the same time.
func TestABigExportComesOutInPages(t *testing.T) {
	me, friend := sessionUser(t), sessionUser(t)
	tok := startSession(t, me, "Pixel 8").AccessToken

	var group string
	if err := config.DB.QueryRow(context.Background(),
		`INSERT INTO groups (name, created_by) VALUES ('Big', $1::uuid) RETURNING id::text`, me).Scan(&group); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), `DELETE FROM groups WHERE id = $1::uuid`, group) })
	mustExec(t, `INSERT INTO group_members (group_id, user_id, role) VALUES ($1::uuid, $2::uuid, 'admin'), ($1::uuid, $3::uuid, 'member')`, group, me, friend)

	// Three messages to each second, so pages have to break ties by id.
	const mine, direct = 3000, 200
	mustExec(t, `INSERT INTO messages (sender_id, group_id, content, created_at)
		SELECT $1::uuid, $2::uuid, 'group ' || i, TIMESTAMPTZ '2026-01-01 00:00:00Z' + (i / 3) * INTERVAL '1 second'
		FROM generate_series(1, $3::int) i`, me, group, mine)
	mustExec(t, `INSERT INTO messages (sender_id, group_id, content)
		SELECT $1::uuid, $2::uuid, 'theirs' FROM generate_series(1, 50)`, friend, group)
	mustExec(t, `INSERT INTO messages (sender_id, receiver_id, content, created_at)
		SELECT CASE WHEN i % 2 = 0 THEN $1::uuid ELSE $2::uuid END,
		       CASE WHEN i % 2 = 0 THEN $2::uuid ELSE $1::uuid END,
		       'direct ' || i, TIMESTAMPTZ '2026-01-01 00:00:00Z' + (i / 3) * INTERVAL '1 second'
		FROM generate_series(1, $3::int) i`, me, friend, direct)

	code, _, got := exportFor(t, tok)
	if code != http.StatusOK {
		t.Fatalf("export: %d", code)
	}
	if len(got.Messages) != models.ExportMessagesDefault || !got.MessagesTruncated || got.MessagesNext == nil {
		t.Fatalf("export: %d messages, truncated %v, next %v; want %d, true and a cursor",
			len(got.Messages), got.MessagesTruncated, got.MessagesNext, models.ExportMessagesDefault)
	}

	// follow asks for the pages after the first one with query, until there
	// is no next one.
	follow := func(first []models.ExportMessage, next *string, query string) []models.ExportMessage {
		t.Helper()
		all := first
		for pages := 0; next != nil; pages++ {
			if pages > 100 {
				t.Fatal("the pages never end")
			}
			code, page := exportPage(t, tok, query+"&after="+url.QueryEscape(*next))
			if code != http.StatusOK {
				t.Fatalf("page %d: %d", pages, code)
			}
			if len(page.Messages) > models.ExportMessagesMax {
				t.Fatalf("page %d has %d messages, more than %d", pages, len(page.Messages), models.ExportMessagesMax)
			}
			all, next = append(all, page.Messages...), page.Next
		}
		return all
	}
	check := func(name string, all []models.ExportMessage, want int) {
		t.Helper()
		seen := map[string]bool{}
		for i, m := range all {
			if seen[m.ID] {
				t.Fatalf("%s: %s twice", name, m.ID)
			}
			seen[m.ID] = true
			if i > 0 {
				p := all[i-1]
				if m.CreatedAt.Before(p.CreatedAt) || (m.CreatedAt.Equal(p.CreatedAt) && m.ID < p.ID) {
					t.Fatalf("%s: %s comes before %s", name, m.ID, p.ID)
				}
			}
			if m.Content == "theirs" {
				t.Fatalf("%s: has another member's group message", name)
			}
		}
		if len(all) != want {
			t.Errorf("%s: %d messages, want %d", name, len(all), want)
		}
	}

	all := follow(got.Messages, got.MessagesNext, "limit=700")
	check("default", all, mine)
	for _, m := range all {
		if m.GroupID == nil {
			t.Fatalf("a direct message without include=direct_messages: %+v", m)
		}
	}

	most := strconv.Itoa(models.ExportMessagesMax)
	code, _, got = exportWith(t, tok, "include=direct_messages&limit="+most)
	if code != http.StatusOK || len(got.Messages) != models.ExportMessagesMax {
		t.Fatalf("export with direct messages: %d, %d messages", code, len(got.Messages))
	}
	check("with direct messages", follow(got.Messages, got.MessagesNext, "include=direct_messages&limit="+most), mine+direct)
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

// The statuses in the export are the ones the app would show: not one that ran
// out, and not one from someone either person blocked, which would give the
// block away.
func TestTheExportHasOnlyTheStatusesThePersonCanSee(t *testing.T) {
	me, friend, blocker, blocked := sessionUser(t), sessionUser(t), sessionUser(t), sessionUser(t)
	tok := startSession(t, me, "Pixel 8").AccessToken
	mustExec(t, `INSERT INTO blocked_users (user_id, blocked_user_id) VALUES ($1::uuid, $2::uuid), ($3::uuid, $1::uuid)`, me, blocked, blocker)

	post := func(author, content, expires string) {
		t.Helper()
		var id string
		if err := config.DB.QueryRow(context.Background(),
			`INSERT INTO statuses (author_id, expires_at) VALUES ($1::uuid, NOW() + $2::interval) RETURNING id::text`,
			author, expires).Scan(&id); err != nil {
			t.Fatal(err)
		}
		mustExec(t, `INSERT INTO status_copies (status_id, recipient_id, content) VALUES ($1::uuid, $2::uuid, $3)`, id, me, content)
	}
	post(friend, "visible", "1 hour")
	post(friend, "ran out", "-1 hour")
	post(blocker, "from someone who blocked me", "1 hour")
	post(blocked, "from someone I blocked", "1 hour")

	code, _, got := exportFor(t, tok)
	if code != http.StatusOK {
		t.Fatalf("export: %d", code)
	}
	var contents []string
	for _, s := range got.ReceivedStatuses {
		contents = append(contents, s.Content)
	}
	if strings.Join(contents, "|") != "visible" {
		t.Errorf("received statuses: %q, want only the visible one", contents)
	}
}
