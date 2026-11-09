package controllers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/services"
)

func TestRespondIfBusy(t *testing.T) {
	w := httptest.NewRecorder()
	if !respondIfBusy(w, fmt.Errorf("wrapped: %w", services.ErrServerBusy)) {
		t.Fatal("a busy error should be handled")
	}
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("expected 503, got %d", w.Code)
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("a 503 should say when to retry")
	}
	var resp models.JSONResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil || resp.Success || resp.Error == "" {
		t.Errorf("unexpected body: %+v (%v)", resp, err)
	}

	other := httptest.NewRecorder()
	if respondIfBusy(other, errors.New("something else")) || other.Body.Len() != 0 {
		t.Error("other errors must be left for the caller")
	}
	if respondIfBusy(httptest.NewRecorder(), nil) {
		t.Error("no error is not a busy error")
	}
}
