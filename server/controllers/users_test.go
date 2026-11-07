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

func TestHandleUserSearch_EmptyQuery(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/users/search?q=", nil)
	w := httptest.NewRecorder()

	HandleUserSearch(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", w.Code)
	}

	var resp models.JSONResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}

	if !resp.Success {
		t.Error("expected search request query sequence to succeed")
	}
}