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
	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/models"
)

func setRegistration(t *testing.T, value string) {
	t.Helper()
	old := env.REGISTRATION
	env.REGISTRATION = value
	t.Cleanup(func() { env.REGISTRATION = old })
}

func registerRequest(prefix string) (*httptest.ResponseRecorder, models.JSONResponse) {
	body, _ := json.Marshal(map[string]string{
		"username":     prefix,
		"display_name": "Registration Test",
		"password":     "password123",
	})
	req := httptest.NewRequest("POST", "/api/auth/register", bytes.NewReader(body))
	w := httptest.NewRecorder()
	HandleRegister(w, req)

	var resp models.JSONResponse
	_ = json.NewDecoder(bytes.NewReader(w.Body.Bytes())).Decode(&resp)
	return w, resp
}

func countUsers(t *testing.T, prefix string) int {
	t.Helper()
	var n int
	err := config.DB.QueryRow(context.Background(), "SELECT count(*) FROM users WHERE username LIKE $1", prefix+".%").Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestRegisterRefusedWhenClosed(t *testing.T) {
	setRegistration(t, "closed")
	prefix := fmt.Sprintf("closedtest%d", time.Now().UnixNano()%1_000_000_000)

	w, resp := registerRequest(prefix)

	if w.Code != http.StatusForbidden {
		t.Errorf("expected status 403, got %d", w.Code)
	}
	if resp.Success || resp.Error != "Registration is closed on this server" {
		t.Errorf("unexpected response: %+v", resp)
	}
	if n := countUsers(t, prefix); n != 0 {
		t.Errorf("a user was created even though registration is closed (%d)", n)
	}
}

func TestRegisterWorksWhenOpen(t *testing.T) {
	setRegistration(t, "open")
	prefix := fmt.Sprintf("opentest%d", time.Now().UnixNano()%1_000_000_000)
	t.Cleanup(func() {
		_, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE username LIKE $1", prefix+".%")
	})

	w, resp := registerRequest(prefix)

	if w.Code != http.StatusCreated || !resp.Success {
		t.Fatalf("expected 201 and success, got %d %+v", w.Code, resp)
	}
	if n := countUsers(t, prefix); n != 1 {
		t.Errorf("expected one new user, found %d", n)
	}
}

func TestHealthReportsRegistration(t *testing.T) {
	for _, mode := range []string{"open", "closed"} {
		setRegistration(t, mode)

		w := httptest.NewRecorder()
		HandleHealthCheck(w, httptest.NewRequest("GET", "/api/health", nil))

		var resp struct {
			Data map[string]interface{} `json:"data"`
		}
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		if resp.Data["registration"] != mode {
			t.Errorf("REGISTRATION=%s: health reported %v", mode, resp.Data["registration"])
		}
	}
}
