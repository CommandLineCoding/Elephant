package controllers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
)

func TestMain(m *testing.M) {	
	config.InitDatabase()
	code := m.Run()
	if config.DB != nil {
		config.DB.Close()
	}
	os.Exit(code)
}

func TestHandleGetMe_Unauthorized(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/users/me", nil)
	w := httptest.NewRecorder()

	HandleGetMe(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401, got %d", w.Code)
	}

	var resp models.JSONResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}

	if resp.Success {
		t.Error("expected success flag to be false")
	}
}

func TestHandleDeleteMe_Unauthorized(t *testing.T) {
	req := httptest.NewRequest("DELETE", "/api/users/me", nil)
	w := httptest.NewRecorder()

	HandleDeleteMe(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401, got %d", w.Code)
	}
}

func TestHandleGetMe_SuccessContext(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/users/me", nil)
	
	ctx := context.WithValue(req.Context(), middlewares.UserIDKey, "00000000-0000-0000-0000-000000000000")
	req = req.WithContext(ctx)
	
	w := httptest.NewRecorder()

	HandleGetMe(w, req)

	if w.Code == http.StatusUnauthorized {
		t.Error("handler incorrectly blocked authorized context chain")
	}
}

func searchStatus(t *testing.T, rawQuery string) (int, models.JSONResponse) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/users/search?q="+rawQuery, nil)
	w := httptest.NewRecorder()

	HandleUserSearch(w, req)

	var resp models.JSONResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return w.Code, resp
}

func TestHandleUserSearch_TooShort(t *testing.T) {
	// empty, one character, whitespace around one character, one multi-byte character
	for _, q := range []string{"", "a", "%20a%20", "%C3%A9"} {
		code, resp := searchStatus(t, q)
		if code != http.StatusBadRequest {
			t.Errorf("q=%q: expected status 400, got %d", q, code)
		}
		if resp.Success {
			t.Errorf("q=%q: expected success to be false", q)
		}
	}
}

func TestHandleUserSearch_MinLengthAccepted(t *testing.T) {
	code, resp := searchStatus(t, "ab")
	if code != http.StatusOK {
		t.Errorf("expected status 200, got %d", code)
	}
	if !resp.Success {
		t.Error("expected a two-character search to succeed")
	}
}
