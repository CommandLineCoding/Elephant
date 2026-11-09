package controllers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

func pushUser(t *testing.T) string {
	t.Helper()
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash) VALUES ($1, 'Push Ctl', 'x') RETURNING id::text`,
		fmt.Sprintf("pushctl.%d", time.Now().UnixNano())).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

func callPush(handler http.HandlerFunc, uid string, body interface{}) (*httptest.ResponseRecorder, models.JSONResponse) {
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/api/users/me/push", bytes.NewReader(raw))
	if uid != "" {
		req = req.WithContext(context.WithValue(req.Context(), middlewares.UserIDKey, uid))
	}
	w := httptest.NewRecorder()
	handler(w, req)

	var resp models.JSONResponse
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	return w, resp
}

func storedEndpoints(t *testing.T, uid string) int {
	t.Helper()
	targets, err := repository.NewPushRepository().ListByUser(context.Background(), uid)
	if err != nil {
		t.Fatal(err)
	}
	return len(targets)
}

func TestPushRegisterAndUnregister(t *testing.T) {
	uid := pushUser(t)
	ep := map[string]string{"endpoint": "https://ntfy.example.org/upAbC123"}

	for i := 0; i < 2; i++ { // registering twice is fine
		w, resp := callPush(HandlePushRegister, uid, ep)
		if w.Code != http.StatusOK || !resp.Success {
			t.Fatalf("register: %d %+v", w.Code, resp)
		}
	}
	if n := storedEndpoints(t, uid); n != 1 {
		t.Fatalf("expected 1 stored endpoint, got %d", n)
	}

	w, resp := callPush(HandlePushUnregister, uid, ep)
	if w.Code != http.StatusOK || !resp.Success {
		t.Fatalf("unregister: %d %+v", w.Code, resp)
	}
	if n := storedEndpoints(t, uid); n != 0 {
		t.Errorf("expected the endpoint to be gone, got %d", n)
	}

	// Removing something that isn't there still succeeds.
	if w, _ := callPush(HandlePushUnregister, uid, ep); w.Code != http.StatusOK {
		t.Errorf("unregistering a missing endpoint should succeed, got %d", w.Code)
	}
}

func TestPushRegisterRejectsUnsafeEndpoints(t *testing.T) {
	uid := pushUser(t)

	for _, endpoint := range []string{
		"",
		"not a url",
		"http://ntfy.example.org/up", // plain http
		"https://127.0.0.1/up",       // loopback
		"https://localhost/up",       // loopback by name
		"https://10.0.0.5/up",        // private
		"https://169.254.169.254/latest/meta-data", // cloud metadata
		"https://user:pass@ntfy.example.org/up",    // credentials
		"ftp://ntfy.example.org/up",
	} {
		w, resp := callPush(HandlePushRegister, uid, map[string]string{"endpoint": endpoint})
		if w.Code != http.StatusBadRequest || resp.Success || resp.Error == "" {
			t.Errorf("endpoint %q: expected 400 with an error, got %d %+v", endpoint, w.Code, resp)
		}
	}
	if n := storedEndpoints(t, uid); n != 0 {
		t.Errorf("a rejected endpoint was stored (%d)", n)
	}

	if w, _ := callPush(HandlePushRegister, uid, "not an object"); w.Code != http.StatusBadRequest {
		t.Errorf("a malformed body should be a 400, got %d", w.Code)
	}
}

func TestPushRequiresASignedInUser(t *testing.T) {
	body := map[string]string{"endpoint": "https://ntfy.example.org/up"}
	for name, h := range map[string]http.HandlerFunc{"register": HandlePushRegister, "unregister": HandlePushUnregister} {
		if w, _ := callPush(h, "", body); w.Code != http.StatusUnauthorized {
			t.Errorf("%s without a user: expected 401, got %d", name, w.Code)
		}
	}
}

func TestPushKeepsAtMostFiveEndpointsPerUser(t *testing.T) {
	uid := pushUser(t)
	for i := 1; i <= 8; i++ {
		w, _ := callPush(HandlePushRegister, uid, map[string]string{"endpoint": fmt.Sprintf("https://ntfy.example.org/up%d", i)})
		if w.Code != http.StatusOK {
			t.Fatalf("register %d: %d", i, w.Code)
		}
	}
	if n := storedEndpoints(t, uid); n != 5 {
		t.Errorf("expected the cap of 5, got %d", n)
	}
}
