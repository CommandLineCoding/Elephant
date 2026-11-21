package routes

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
)

var sessionsDBOnce sync.Once

func sessionsDB(t *testing.T) {
	t.Helper()
	sessionsDBOnce.Do(func() {
		dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
			env.POSTGRES_USER, env.POSTGRES_PASSWORD, env.POSTGRES_HOST, env.POSTGRES_PORT, env.POSTGRES_DB)
		pool, err := pgxpool.New(context.Background(), dsn)
		if err == nil {
			err = pool.Ping(context.Background())
		}
		if err == nil {
			config.DB = pool
		}
	})
	if config.DB == nil {
		t.Skip("no database available")
	}
}

func sessionUser(t *testing.T) string {
	t.Helper()
	sessionsDB(t)
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash) VALUES ($1, 'Sessions', 'x') RETURNING id::text`,
		fmt.Sprintf("sessions.%d", time.Now().UnixNano())).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

func startSession(t *testing.T, uid, device string) *services.TokenPair {
	t.Helper()
	pair, err := services.NewAuthService().StartSession(context.Background(), uid, device)
	if err != nil {
		t.Fatal(err)
	}
	return pair
}

type sessionRow struct {
	ID         string    `json:"id"`
	DeviceName string    `json:"device_name"`
	StartedAt  time.Time `json:"started_at"`
	Current    bool      `json:"current"`
}

func callSessions(t *testing.T, method, path, token string) (int, models.JSONResponse) {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	newTestRouter().ServeHTTP(w, req)
	var resp models.JSONResponse
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	return w.Code, resp
}

func listSessions(t *testing.T, token string) []sessionRow {
	t.Helper()
	code, resp := callSessions(t, "GET", "/api/users/me/sessions", token)
	if code != http.StatusOK || !resp.Success {
		t.Fatalf("list: %d %+v", code, resp)
	}
	raw, _ := json.Marshal(resp.Data)
	var rows []sessionRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestSessionsListShowsEachDeviceAndMarksThisOne(t *testing.T) {
	uid := sessionUser(t)
	phone := startSession(t, uid, "Pixel 8")
	tablet := startSession(t, uid, "Galaxy Tab S9")

	rows := listSessions(t, phone.AccessToken)
	if len(rows) != 2 {
		t.Fatalf("expected 2 devices, got %+v", rows)
	}
	for _, r := range rows {
		wantCurrent := r.ID == phone.SessionID
		if r.Current != wantCurrent {
			t.Errorf("%s: current=%v, want %v", r.DeviceName, r.Current, wantCurrent)
		}
	}
	for _, r := range listSessions(t, tablet.AccessToken) {
		if r.Current != (r.ID == tablet.SessionID) {
			t.Errorf("from the tablet, %s has current=%v", r.DeviceName, r.Current)
		}
	}
}

func TestSessionsNeedASignedInUser(t *testing.T) {
	for _, m := range []string{"GET", "DELETE"} {
		if code, _ := callSessions(t, m, "/api/users/me/sessions", ""); code != http.StatusUnauthorized {
			t.Errorf("%s without a token: %d", m, code)
		}
	}
}

func TestSigningOutADeviceStopsItRefreshingAndReconnecting(t *testing.T) {
	uid := sessionUser(t)
	phone := startSession(t, uid, "Pixel 8")
	tablet := startSession(t, uid, "Galaxy Tab S9")

	code, resp := callSessions(t, "DELETE", "/api/users/me/sessions/"+tablet.SessionID, phone.AccessToken)
	if code != http.StatusOK || !resp.Success {
		t.Fatalf("sign out: %d %+v", code, resp)
	}
	if rows := listSessions(t, phone.AccessToken); len(rows) != 1 || rows[0].ID != phone.SessionID {
		t.Fatalf("after signing the tablet out: %+v", rows)
	}

	auth := services.NewAuthService()
	if _, err := auth.Refresh(context.Background(), tablet.RefreshToken, ""); err == nil {
		t.Error("a signed-out device could still refresh")
	}
	if _, err := auth.Refresh(context.Background(), phone.RefreshToken, ""); err != nil {
		t.Errorf("the other device was affected: %v", err)
	}

	repo := repository.NewRefreshTokenRepository()
	if active, _ := repo.SessionActive(context.Background(), uid, tablet.SessionID); active {
		t.Error("the signed-out session is still active, so its websocket could reconnect")
	}
	if active, _ := repo.SessionActive(context.Background(), uid, phone.SessionID); !active {
		t.Error("the other session stopped being active")
	}
}

func TestSigningOutTheOthersKeepsThisDevice(t *testing.T) {
	uid := sessionUser(t)
	phone := startSession(t, uid, "Pixel 8")
	startSession(t, uid, "Galaxy Tab S9")
	startSession(t, uid, "Old laptop")

	code, resp := callSessions(t, "DELETE", "/api/users/me/sessions", phone.AccessToken)
	if code != http.StatusOK || !resp.Success {
		t.Fatalf("sign out the others: %d %+v", code, resp)
	}
	if data, _ := resp.Data.(map[string]interface{}); data["signed_out"] != float64(2) {
		t.Errorf("reported %v signed out, want 2", resp.Data)
	}
	rows := listSessions(t, phone.AccessToken)
	if len(rows) != 1 || !rows[0].Current {
		t.Fatalf("only this device should be left: %+v", rows)
	}
}

func TestSigningOutTheOthersNeedsToKnowWhichDeviceThisIs(t *testing.T) {
	uid := sessionUser(t)
	startSession(t, uid, "Pixel 8")
	startSession(t, uid, "Galaxy Tab S9")

	// A token from before sessions existed has no session in it.
	old := legacyAccessToken(t, uid)
	code, _ := callSessions(t, "DELETE", "/api/users/me/sessions", old)
	if code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", code)
	}
	if rows := listSessions(t, old); len(rows) != 2 {
		t.Errorf("nothing should have been signed out, got %+v", rows)
	}
}

func TestOneUserCannotSeeOrSignOutAnothersDevices(t *testing.T) {
	mine, theirs := sessionUser(t), sessionUser(t)
	me := startSession(t, mine, "Pixel 8")
	other := startSession(t, theirs, "Their phone")

	if rows := listSessions(t, me.AccessToken); len(rows) != 1 || rows[0].ID != me.SessionID {
		t.Fatalf("my list: %+v", rows)
	}
	if code, _ := callSessions(t, "DELETE", "/api/users/me/sessions/"+other.SessionID, me.AccessToken); code != http.StatusNotFound {
		t.Errorf("signing out someone else's device: %d, want 404", code)
	}
	if rows := listSessions(t, other.AccessToken); len(rows) != 1 {
		t.Errorf("their device went away: %+v", rows)
	}
	callSessions(t, "DELETE", "/api/users/me/sessions", me.AccessToken)
	if rows := listSessions(t, other.AccessToken); len(rows) != 1 {
		t.Errorf("signing out my others signed out theirs: %+v", rows)
	}
}

func TestSigningOutBadIDs(t *testing.T) {
	uid := sessionUser(t)
	me := startSession(t, uid, "Pixel 8")
	if code, _ := callSessions(t, "DELETE", "/api/users/me/sessions/not-a-uuid", me.AccessToken); code != http.StatusBadRequest {
		t.Errorf("a malformed ID: %d, want 400", code)
	}
	if code, _ := callSessions(t, "DELETE", "/api/users/me/sessions/"+services.NewSessionID(), me.AccessToken); code != http.StatusNotFound {
		t.Errorf("an unknown ID: %d, want 404", code)
	}
}

func TestSigningOutThisDeviceWorks(t *testing.T) {
	uid := sessionUser(t)
	me := startSession(t, uid, "Pixel 8")
	if code, _ := callSessions(t, "DELETE", "/api/users/me/sessions/"+me.SessionID, me.AccessToken); code != http.StatusOK {
		t.Fatalf("signing out this device: %d", code)
	}
	if _, err := services.NewAuthService().Refresh(context.Background(), me.RefreshToken, ""); err == nil {
		t.Error("a device that signed itself out could refresh")
	}
}

func TestRefreshKeepsTheSessionAndWhenItStarted(t *testing.T) {
	uid := sessionUser(t)
	first := startSession(t, uid, "Pixel 8")
	before := listSessions(t, first.AccessToken)[0]

	next, err := services.NewAuthService().Refresh(context.Background(), first.RefreshToken, "")
	if err != nil {
		t.Fatal(err)
	}
	if next.SessionID != first.SessionID {
		t.Errorf("a refresh started a new session: %s -> %s", first.SessionID, next.SessionID)
	}
	after := listSessions(t, next.AccessToken)
	if len(after) != 1 || after[0].ID != first.SessionID || after[0].DeviceName != "Pixel 8" {
		t.Fatalf("after refresh: %+v", after)
	}
	if !after[0].StartedAt.Equal(before.StartedAt) {
		t.Errorf("started_at moved from %v to %v", before.StartedAt, after[0].StartedAt)
	}

	// The old refresh token is single use.
	if _, err := services.NewAuthService().Refresh(context.Background(), first.RefreshToken, ""); err == nil {
		t.Error("a refresh token worked twice")
	}
}

func TestADeviceCanBeNamedOnItsFirstRefresh(t *testing.T) {
	uid := sessionUser(t)
	// Signing in with Google or GitHub happens in a browser, which can't name the phone.
	first := startSession(t, uid, "")
	if got := listSessions(t, first.AccessToken)[0].DeviceName; got != "" {
		t.Fatalf("expected no name yet, got %q", got)
	}
	next, err := services.NewAuthService().Refresh(context.Background(), first.RefreshToken, "Pixel 8")
	if err != nil {
		t.Fatal(err)
	}
	if got := listSessions(t, next.AccessToken)[0].DeviceName; got != "Pixel 8" {
		t.Errorf("name after refresh = %q", got)
	}
	// A refresh that doesn't send one keeps what is there.
	again, err := services.NewAuthService().Refresh(context.Background(), next.RefreshToken, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := listSessions(t, again.AccessToken)[0].DeviceName; got != "Pixel 8" {
		t.Errorf("name was lost: %q", got)
	}
}

func TestDeviceNamesAreCleaned(t *testing.T) {
	if got := services.CleanDeviceName("  Pixel \n  8\t Pro "); got != "Pixel 8 Pro" {
		t.Errorf("whitespace: %q", got)
	}
	long := strings.Repeat("é", 200)
	if got := services.CleanDeviceName(long); len([]rune(got)) != services.MaxDeviceNameLength {
		t.Errorf("long name has %d characters", len([]rune(got)))
	}
}

func TestTokensCarryTheirSession(t *testing.T) {
	pair, err := services.GenerateTokenPair("00000000-0000-0000-0000-000000000001")
	if err != nil {
		t.Fatal(err)
	}
	for _, tok := range []string{pair.AccessToken, pair.RefreshToken} {
		uid, sid, err := services.ParseToken(tok)
		if err != nil || uid != "00000000-0000-0000-0000-000000000001" || sid != pair.SessionID || sid == "" {
			t.Errorf("ParseToken = %q, %q, %v", uid, sid, err)
		}
	}
}

// legacyAccessToken is what the app held before sessions existed: a valid
// access token with no session in it.
func legacyAccessToken(t *testing.T, uid string) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": uid,
		"exp": time.Now().Add(time.Minute).Unix(),
	})
	s, err := tok.SignedString([]byte(env.JWT_SECRET))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

var hubOnce sync.Once

// A device that was signed out can't open a connection with the access token
// it still holds, but a device that wasn't can.
func TestSignedOutDeviceCannotReconnect(t *testing.T) {
	hubOnce.Do(func() { go services.Hub.Run() })
	uid := sessionUser(t)
	phone := startSession(t, uid, "Pixel 8")
	tablet := startSession(t, uid, "Galaxy Tab S9")

	srv := httptest.NewServer(newTestRouter())
	defer srv.Close()
	dial := func(token string) (*http.Response, error) {
		url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/ws?token=" + token
		conn, resp, err := websocket.DefaultDialer.Dial(url, nil)
		if conn != nil {
			conn.Close()
		}
		return resp, err
	}

	if _, err := dial(tablet.AccessToken); err != nil {
		t.Fatalf("a signed-in device could not connect: %v", err)
	}
	if code, _ := callSessions(t, "DELETE", "/api/users/me/sessions/"+tablet.SessionID, phone.AccessToken); code != http.StatusOK {
		t.Fatalf("sign out: %d", code)
	}
	resp, err := dial(tablet.AccessToken)
	if err == nil {
		t.Fatal("a signed-out device reconnected")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401, got %v (err %v)", resp, err)
	}
	if _, err := dial(phone.AccessToken); err != nil {
		t.Errorf("the other device could not connect: %v", err)
	}
	// A token from before sessions still connects: there is no session to check.
	if _, err := dial(legacyAccessToken(t, uid)); err != nil {
		t.Errorf("a token without a session was refused: %v", err)
	}
}
