package routes

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/commandlinecoding/elephant/server/services"
)

// A page the server can't give exactly is refused before anything is read,
// so these need no database.
func TestABadExportPageIsRefused(t *testing.T) {
	tokens, err := services.GenerateTokenPair("00000000-0000-0000-0000-000000000001")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		"/api/users/me/export?limit=0",
		"/api/users/me/export?limit=2001",
		"/api/users/me/export?limit=all",
		"/api/users/me/export?include=photos",
		"/api/users/me/export?after=MjAyNi0xMS0yN1QwMDowMDowMFogMGI2YzNmMWUtOGEyZC00YzVlLTlmMTAtMWEyYjNjNGQ1ZTZm",
		"/api/users/me/export/messages?limit=-1",
		"/api/users/me/export/messages?limit=5000",
		"/api/users/me/export/messages?include=everything",
		"/api/users/me/export/messages?after=not-a-cursor",
		"/api/users/me/export/messages?after=bm8gc3BhY2U",
	} {
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("Authorization", "Bearer "+tokens.AccessToken)
		w := httptest.NewRecorder()
		newTestRouter().ServeHTTP(w, req)
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", path, w.Code)
		}
	}
}

func TestTheExportPagesNeedASignedInUser(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/users/me/export/messages", nil)
	w := httptest.NewRecorder()
	newTestRouter().ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("without a token: %d, want 401", w.Code)
	}
}
