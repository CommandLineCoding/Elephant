package controllers

import (
	"encoding/json"
	"html/template"
	"net/http"
	"regexp"
	"strings"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/go-chi/chi/v5"
)

const appPackage = "in.commandlinecoding.elephant"

// usernamePattern matches full usernames such as alex.4821.
var usernamePattern = regexp.MustCompile(`^[a-z0-9]{1,40}\.[0-9]{4}$`)

// HandleAssetLinks serves /.well-known/assetlinks.json, which lets Android
// open https profile links (/u/<username>) in the app directly instead of
// asking which app to use.
func HandleAssetLinks(w http.ResponseWriter, r *http.Request) {
	fingerprints := []string{}
	for _, f := range strings.Split(env.APP_LINK_FINGERPRINTS, ",") {
		if f = strings.TrimSpace(f); f != "" {
			fingerprints = append(fingerprints, strings.ToUpper(f))
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode([]map[string]interface{}{{
		"relation": []string{"delegate_permission/common.handle_all_urls"},
		"target": map[string]interface{}{
			"namespace":                "android_app",
			"package_name":             appPackage,
			"sha256_cert_fingerprints": fingerprints,
		},
	}})
}

var profilePage = template.Must(template.New("profile").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Username}} on Elephant</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; padding: 48px 24px; color: #111827; background: #f5f6f8; }
  main { max-width: 420px; margin: 0 auto; }
  h1 { font-size: 28px; margin: 0 0 8px; }
  p { color: #646c7b; line-height: 1.5; }
  a.button { display: block; text-align: center; padding: 14px; border-radius: 12px; background: #2b59e8; color: #fff; text-decoration: none; font-weight: 600; margin: 24px 0 12px; }
  a { color: #2b59e8; }
</style>
</head>
<body>
<main>
  <h1>@{{.Username}}</h1>
  <p>wants to chat with you on Elephant, a private, end-to-end encrypted messenger.</p>
  <a class="button" href="elephant://u/{{.Username}}">Open in Elephant</a>
  <p>Don't have Elephant yet? <a href="https://github.com/CommandLineCoding/Elephant/releases/latest">Get the app</a>, then open this link again, or search for <strong>{{.Username}}</strong> in the app.</p>
</main>
</body>
</html>
`))

// HandleProfileLink serves /u/{username}: the page someone without the app
// sees when they open a profile link. With the app installed, Android opens
// the chat instead and this page isn't shown.
func HandleProfileLink(w http.ResponseWriter, r *http.Request) {
	username := strings.ToLower(chi.URLParam(r, "username"))
	if !usernamePattern.MatchString(username) {
		http.NotFound(w, r)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	_ = profilePage.Execute(w, struct{ Username string }{username})
}

var groupPage = template.Must(template.New("group").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>You're invited to a group on Elephant</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; padding: 48px 24px; color: #111827; background: #f5f6f8; }
  main { max-width: 420px; margin: 0 auto; }
  h1 { font-size: 28px; margin: 0 0 8px; }
  p { color: #646c7b; line-height: 1.5; }
  a.button { display: block; text-align: center; padding: 14px; border-radius: 12px; background: #2b59e8; color: #fff; text-decoration: none; font-weight: 600; margin: 24px 0 12px; }
  a { color: #2b59e8; }
</style>
</head>
<body>
<main>
  <h1>You're invited to a group</h1>
  <p>Someone invited you to join a group on Elephant, a private, end-to-end encrypted messenger.</p>
  <a class="button" href="elephant://g/{{.Code}}">Open in Elephant</a>
  <p>Don't have Elephant yet? <a href="https://github.com/CommandLineCoding/Elephant/releases/latest">Get the app</a>, then open this link again.</p>
</main>
</body>
</html>
`))

// HandleGroupLink serves /g/{code}: the page someone without the app sees when
// they open a group invite link. With the app installed, Android opens the
// group's invitation instead and this page isn't shown. It doesn't name the
// group: the page can be fetched by anything that sees the link, such as a
// chat app making a preview.
func HandleGroupLink(w http.ResponseWriter, r *http.Request) {
	code := chi.URLParam(r, "code")
	if !inviteCodePattern.MatchString(code) {
		http.NotFound(w, r)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	_ = groupPage.Execute(w, struct{ Code string }{code})
}
