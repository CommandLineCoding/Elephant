package routes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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

// Sign-in and sign-up cost a password hash, so both are limited per address.
func TestAuthRoutesAreRateLimited(t *testing.T) {
	router := newTestRouter() // one router, so the limiters keep their state

	post := func(path, remote string) (int, models.JSONResponse) {
		req := httptest.NewRequest("POST", path, strings.NewReader("not json")) // refused before any database work
		req.RemoteAddr = remote
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		var resp models.JSONResponse
		_ = json.NewDecoder(w.Body).Decode(&resp)
		return w.Code, resp
	}

	// login: burst of 10
	for i := 1; i <= 10; i++ {
		if code, _ := post("/api/auth/login", "203.0.113.7:1000"); code != http.StatusBadRequest {
			t.Fatalf("login attempt %d: expected the handler's 400, got %d", i, code)
		}
	}
	code, resp := post("/api/auth/login", "203.0.113.7:1000")
	if code != http.StatusTooManyRequests || !strings.Contains(resp.Error, "sign-in") {
		t.Errorf("11th login: expected 429 about sign-in, got %d %q", code, resp.Error)
	}
	if code, _ := post("/api/auth/login", "203.0.113.8:1000"); code != http.StatusBadRequest {
		t.Errorf("another address must not share the limit, got %d", code)
	}

	// register: burst of 5
	for i := 1; i <= 5; i++ {
		if code, _ := post("/api/auth/register", "203.0.113.7:1000"); code != http.StatusBadRequest {
			t.Fatalf("register attempt %d: expected 400, got %d", i, code)
		}
	}
	code, resp = post("/api/auth/register", "203.0.113.7:1000")
	if code != http.StatusTooManyRequests || !strings.Contains(resp.Error, "sign-up") {
		t.Errorf("6th register: expected 429 about sign-up, got %d %q", code, resp.Error)
	}

	// the two limits are independent
	if code, _ := post("/api/auth/login", "203.0.113.9:1000"); code != http.StatusBadRequest {
		t.Errorf("login should be unaffected by register, got %d", code)
	}
}
