package routes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

// newTestRouter wires the API the same way main.go does.
func newTestRouter() http.Handler {
	r := chi.NewRouter()
	ErrorHandlers(r)
	r.Route("/api", ApiRoute)
	return r
}

func TestUnknownRoutesAndMethodsReturnJSON(t *testing.T) {
	tokens, err := services.GenerateTokenPair("00000000-0000-0000-0000-000000000001")
	if err != nil {
		t.Fatal(err)
	}
	auth := "Bearer " + tokens.AccessToken

	cases := []struct {
		name, method, path, auth string
		want                     int
	}{
		{"unknown top-level path", "GET", "/nope", "", http.StatusNotFound},
		{"unknown path under /api", "GET", "/api/nope", "", http.StatusNotFound},
		{"unknown path in a nested router", "GET", "/api/messages/nope/deeper", auth, http.StatusNotFound},
		{"wrong method on a known path", "POST", "/api/health", "", http.StatusMethodNotAllowed},
		{"wrong method in a nested router", "PATCH", "/api/messages/conversations", auth, http.StatusMethodNotAllowed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(c.method, c.path, nil)
			if c.auth != "" {
				req.Header.Set("Authorization", c.auth)
			}
			w := httptest.NewRecorder()
			newTestRouter().ServeHTTP(w, req)

			if w.Code != c.want {
				t.Fatalf("expected status %d, got %d (body %q)", c.want, w.Code, w.Body.String())
			}
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("expected JSON content type, got %q", ct)
			}
			var resp models.JSONResponse
			if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
				t.Fatalf("body is not JSON: %v", err)
			}
			if resp.Success || resp.Error == "" {
				t.Errorf("expected a failure envelope with an error, got %+v", resp)
			}
		})
	}
}

func TestPushRoutesRequireAuth(t *testing.T) {
	for _, method := range []string{"POST", "DELETE"} {
		req := httptest.NewRequest(method, "/api/users/me/push", nil)
		w := httptest.NewRecorder()
		newTestRouter().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("%s /api/users/me/push without a token: expected 401, got %d", method, w.Code)
		}
	}
}
