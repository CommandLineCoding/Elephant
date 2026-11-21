package routes

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

func callJSON(t *testing.T, method, path, token string, body interface{}) (int, models.JSONResponse) {
	t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rdr = bytes.NewReader(raw)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rdr)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	newTestRouter().ServeHTTP(w, req)
	var resp models.JSONResponse
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	return w.Code, resp
}

func settingsOf(t *testing.T, resp models.JSONResponse) repository.UserSettings {
	t.Helper()
	raw, _ := json.Marshal(resp.Data)
	var s repository.UserSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSettingsNeedASignedInUser(t *testing.T) {
	for _, m := range []string{"GET", "PATCH"} {
		if code, _ := callJSON(t, m, "/api/users/me/settings", "", nil); code != http.StatusUnauthorized {
			t.Errorf("%s without a token: %d", m, code)
		}
	}
}

func TestSettingsStartAtTheDefaultsAndChangeOnRequest(t *testing.T) {
	uid := sessionUser(t)
	tok := startSession(t, uid, "Pixel 8").AccessToken

	code, resp := callJSON(t, "GET", "/api/users/me/settings", tok, nil)
	if code != http.StatusOK || settingsOf(t, resp) != repository.DefaultUserSettings() {
		t.Fatalf("defaults: %d %+v", code, resp.Data)
	}

	code, resp = callJSON(t, "PATCH", "/api/users/me/settings", tok, map[string]interface{}{"online_status": "nobody"})
	if code != http.StatusOK {
		t.Fatalf("patch: %d %+v", code, resp)
	}
	want := repository.DefaultUserSettings()
	want.OnlineStatus = "nobody"
	if got := settingsOf(t, resp); got != want {
		t.Errorf("patch returned %+v, want %+v", got, want)
	}

	code, resp = callJSON(t, "PATCH", "/api/users/me/settings", tok, map[string]interface{}{"read_receipts": false, "group_adds": "contacts"})
	want.ReadReceipts, want.GroupAdds = false, "contacts"
	if got := settingsOf(t, resp); code != http.StatusOK || got != want {
		t.Errorf("second patch: %d %+v, want %+v", code, got, want)
	}

	_, resp = callJSON(t, "GET", "/api/users/me/settings", tok, nil)
	if got := settingsOf(t, resp); got != want {
		t.Errorf("saved %+v, want %+v", got, want)
	}
}

func TestSettingsRejectUnknownAudiences(t *testing.T) {
	uid := sessionUser(t)
	tok := startSession(t, uid, "Pixel 8").AccessToken
	for _, body := range []map[string]interface{}{
		{"online_status": "friends"},
		{"group_adds": ""},
		{"online_status": "nobody", "group_adds": "anyone"},
	} {
		if code, _ := callJSON(t, "PATCH", "/api/users/me/settings", tok, body); code != http.StatusBadRequest {
			t.Errorf("%v: %d, want 400", body, code)
		}
	}
	// Nothing from the rejected request was applied.
	_, resp := callJSON(t, "GET", "/api/users/me/settings", tok, nil)
	if got := settingsOf(t, resp); got != repository.DefaultUserSettings() {
		t.Errorf("a rejected patch changed things: %+v", got)
	}
	if code, _ := callJSON(t, "PATCH", "/api/users/me/settings", tok, "not an object"); code != http.StatusBadRequest {
		t.Errorf("a malformed body: %d, want 400", code)
	}
}

// Who may add someone to a group follows their setting, checked by the server.
func TestGroupAddsFollowTheTargetsSetting(t *testing.T) {
	admin, friend, stranger := sessionUser(t), sessionUser(t), sessionUser(t)
	adminTok := startSession(t, admin, "Pixel 8").AccessToken
	group, err := repository.NewGroupRepository().Create(context.Background(), "Trek", admin)
	if err != nil {
		t.Fatal(err)
	}
	// admin and friend have chatted, so they are contacts.
	if _, err := config.DB.Exec(context.Background(),
		`INSERT INTO messages (sender_id, receiver_id, content) VALUES ($1::uuid, $2::uuid, 'hi')`, admin, friend); err != nil {
		t.Fatal(err)
	}

	set := func(user, field, value string) {
		tok := startSession(t, user, "x").AccessToken
		if code, _ := callJSON(t, "PATCH", "/api/users/me/settings", tok, map[string]interface{}{field: value}); code != http.StatusOK {
			t.Fatalf("setting %s=%s: %d", field, value, code)
		}
	}
	add := func(target string) int {
		code, _ := callJSON(t, "POST", "/api/groups/"+group.ID+"/members", adminTok, map[string]string{"user_id": target})
		return code
	}
	inGroup := func(user string) bool {
		var n int
		_ = config.DB.QueryRow(context.Background(),
			`SELECT count(*) FROM group_members WHERE group_id = $1::uuid AND user_id = $2::uuid`, group.ID, user).Scan(&n)
		return n == 1
	}

	// Default: everyone may add.
	if code := add(stranger); code != http.StatusOK || !inGroup(stranger) {
		t.Fatalf("by default anyone can be added: %d", code)
	}

	set(friend, "group_adds", "nobody")
	if code := add(friend); code != http.StatusForbidden || inGroup(friend) {
		t.Errorf("a person who allows nobody was added: %d", code)
	}

	set(friend, "group_adds", "contacts")
	if code := add(friend); code != http.StatusOK || !inGroup(friend) {
		t.Errorf("a contact may add someone who allows contacts: %d", code)
	}

	// A person who allows contacts refuses someone they never chatted with.
	other := sessionUser(t)
	set(other, "group_adds", "contacts")
	if code := add(other); code != http.StatusForbidden || inGroup(other) {
		t.Errorf("a stranger added someone who allows contacts: %d", code)
	}
}
