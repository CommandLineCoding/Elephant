package controllers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/go-chi/chi/v5"
)

func linkRouter() http.Handler {
	r := chi.NewRouter()
	r.Get("/.well-known/assetlinks.json", HandleAssetLinks)
	r.Get("/u/{username}", HandleProfileLink)
	return r
}

func get(t *testing.T, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	linkRouter().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestAssetLinksListTheAppAndItsKeys(t *testing.T) {
	old := env.APP_LINK_FINGERPRINTS
	env.APP_LINK_FINGERPRINTS = " aa:bb , CC:DD ,"
	t.Cleanup(func() { env.APP_LINK_FINGERPRINTS = old })

	rec := get(t, "/.well-known/assetlinks.json")
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("got %d %q", rec.Code, rec.Header().Get("Content-Type"))
	}
	var body []struct {
		Relation []string `json:"relation"`
		Target   struct {
			Namespace    string   `json:"namespace"`
			Package      string   `json:"package_name"`
			Fingerprints []string `json:"sha256_cert_fingerprints"`
		} `json:"target"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || len(body) != 1 {
		t.Fatalf("bad JSON %q: %v", rec.Body.String(), err)
	}
	got := body[0]
	if got.Target.Package != "in.commandlinecoding.elephant" || got.Target.Namespace != "android_app" {
		t.Errorf("wrong target: %+v", got.Target)
	}
	if len(got.Relation) != 1 || got.Relation[0] != "delegate_permission/common.handle_all_urls" {
		t.Errorf("wrong relation: %v", got.Relation)
	}
	if strings.Join(got.Target.Fingerprints, "|") != "AA:BB|CC:DD" {
		t.Errorf("fingerprints should be trimmed and upper-cased: %v", got.Target.Fingerprints)
	}
}

func TestProfileLinkPage(t *testing.T) {
	rec := get(t, "/u/Alex.4821")
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, `href="elephant://u/alex.4821"`) || !strings.Contains(body, "@alex.4821") {
		t.Errorf("the page should show the username and an app link:\n%s", body)
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.HasPrefix(csp, "default-src 'none'") {
		t.Errorf("missing a strict CSP: %q", csp)
	}
}

func TestProfileLinkRejectsAnythingButAUsername(t *testing.T) {
	for _, path := range []string{
		"/u/alex",
		"/u/alex.48211",
		"/u/%3Cscript%3E.1234",
		"/u/alex.4821%22onload%3D",
		"/u/a_b.1234",
	} {
		if rec := get(t, path); rec.Code != http.StatusNotFound {
			t.Errorf("%s: got %d, want 404", path, rec.Code)
		}
	}
}
