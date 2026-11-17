package services

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
)

// setStaticTURN sets a fixed TURN login for one test.
func setStaticTURN(t *testing.T, user, pass string) {
	t.Helper()
	oldUser, oldPass := env.TURN_USERNAME, env.TURN_PASSWORD
	env.TURN_USERNAME, env.TURN_PASSWORD = user, pass
	t.Cleanup(func() { env.TURN_USERNAME, env.TURN_PASSWORD = oldUser, oldPass })
}

func TestTURNWithAFixedLogin(t *testing.T) {
	setICEEnv(t, "stun:stun.example.org:3478", "turn:relay.example.org:80,turns:relay.example.org:443?transport=tcp", "", "", "")
	setStaticTURN(t, "elephant", "pa55")
	got := ICEServers(context.Background(), "u1")
	want := []ICEServer{
		{URLs: []string{"stun:stun.example.org:3478"}},
		{URLs: []string{"turn:relay.example.org:80", "turns:relay.example.org:443?transport=tcp"}, Username: "elephant", Credential: "pa55"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}

	// Without a password there's no TURN.
	setStaticTURN(t, "elephant", "")
	if got := ICEServers(context.Background(), "u1"); len(got) != 1 {
		t.Errorf("a login without a password gave %+v", got)
	}
}

func TestCoturnSecretWinsOverAFixedLogin(t *testing.T) {
	setICEEnv(t, "", "turn:turn.example.org:3478", "s3cret", "", "")
	setStaticTURN(t, "elephant", "pa55")
	got := ICEServers(context.Background(), "u1")
	if len(got) != 1 || got[0].Username == "elephant" {
		t.Errorf("got %+v, want coturn credentials", got)
	}
}

// setICEEnv sets the call settings for one test.
func setICEEnv(t *testing.T, stun, turnURLs, turnSecret, cfKey, cfToken string) {
	t.Helper()
	old := []string{env.STUN_URLS, env.TURN_URLS, env.TURN_SECRET, env.CLOUDFLARE_TURN_KEY_ID, env.CLOUDFLARE_TURN_API_TOKEN}
	env.STUN_URLS, env.TURN_URLS, env.TURN_SECRET, env.CLOUDFLARE_TURN_KEY_ID, env.CLOUDFLARE_TURN_API_TOKEN = stun, turnURLs, turnSecret, cfKey, cfToken
	t.Cleanup(func() {
		env.STUN_URLS, env.TURN_URLS, env.TURN_SECRET, env.CLOUDFLARE_TURN_KEY_ID, env.CLOUDFLARE_TURN_API_TOKEN = old[0], old[1], old[2], old[3], old[4]
	})
}

func TestICEServersWithNoTURNAreJustSTUN(t *testing.T) {
	setICEEnv(t, "stun:stun.example.org:3478, stun:stun2.example.org:3478", "", "", "", "")
	got := ICEServers(context.Background(), "u1")
	want := []ICEServer{{URLs: []string{"stun:stun.example.org:3478", "stun:stun2.example.org:3478"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}

	setICEEnv(t, "", "", "", "", "")
	if got := ICEServers(context.Background(), "u1"); len(got) != 0 {
		t.Errorf("with STUN_URLS empty, got %+v", got)
	}
}

func TestCoturnCredentialsFollowTheRESTScheme(t *testing.T) {
	setICEEnv(t, "", "turn:turn.example.org:3478?transport=udp,turns:turn.example.org:5349", "s3cret", "", "")
	now := time.Unix(1_800_000_000, 0)
	old := iceNow
	iceNow = func() time.Time { return now }
	t.Cleanup(func() { iceNow = old })

	got := ICEServers(context.Background(), "user-1")
	if len(got) != 1 {
		t.Fatalf("got %+v", got)
	}
	turn := got[0]
	if !reflect.DeepEqual(turn.URLs, []string{"turn:turn.example.org:3478?transport=udp", "turns:turn.example.org:5349"}) {
		t.Errorf("urls = %v", turn.URLs)
	}
	wantUser := "1800086400:user-1" // a day later
	if turn.Username != wantUser {
		t.Errorf("username = %q, want %q", turn.Username, wantUser)
	}
	mac := hmac.New(sha1.New, []byte("s3cret"))
	mac.Write([]byte(wantUser))
	if want := base64.StdEncoding.EncodeToString(mac.Sum(nil)); turn.Credential != want {
		t.Errorf("credential = %q, want %q", turn.Credential, want)
	}
}

func TestCoturnNeedsBothURLsAndSecret(t *testing.T) {
	setICEEnv(t, "", "turn:turn.example.org:3478", "", "", "")
	if got := ICEServers(context.Background(), "u1"); len(got) != 0 {
		t.Errorf("TURN without a secret gave %+v", got)
	}
}

// fakeCloudflare answers like Cloudflare's generate-ice-servers endpoint.
func fakeCloudflare(t *testing.T, status int) (gotAuth, gotPath *string, gotTTL *int) {
	t.Helper()
	var auth, path string
	var ttl int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, path = r.Header.Get("Authorization"), r.URL.Path
		var body struct {
			TTL int `json:"ttl"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		ttl = body.TTL
		w.WriteHeader(status)
		_, _ = w.Write([]byte(`{"iceServers":[
			{"urls":["stun:stun.cloudflare.com:3478","stun:stun.cloudflare.com:53"]},
			{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turn:turn.cloudflare.com:53?transport=udp","turns:turn.cloudflare.com:443?transport=tcp"],
			 "username":"cf-user","credential":"cf-pass"}]}`))
	}))
	t.Cleanup(srv.Close)
	old := cloudflareTURNURL
	cloudflareTURNURL = srv.URL + "/v1/turn/keys/%s/credentials/generate-ice-servers"
	t.Cleanup(func() { cloudflareTURNURL = old })
	return &auth, &path, &ttl
}

func TestCloudflareTURN(t *testing.T) {
	auth, path, ttl := fakeCloudflare(t, http.StatusCreated)
	setICEEnv(t, "stun:stun.cloudflare.com:3478", "", "", "key-1", "token-1")

	got := ICEServers(context.Background(), "u1")
	want := []ICEServer{
		{URLs: []string{"stun:stun.cloudflare.com:3478"}},
		// The duplicate STUN entry and the port-53 URLs are left out.
		{URLs: []string{"turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"},
			Username: "cf-user", Credential: "cf-pass"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
	if *auth != "Bearer token-1" || !strings.Contains(*path, "/keys/key-1/") || *ttl != 86400 {
		t.Errorf("request: auth %q, path %q, ttl %d", *auth, *path, *ttl)
	}
}

func TestCloudflareFailureFallsBackToSTUN(t *testing.T) {
	fakeCloudflare(t, http.StatusUnauthorized)
	setICEEnv(t, "stun:stun.cloudflare.com:3478", "", "", "key-1", "bad-token")

	got := ICEServers(context.Background(), "u1")
	want := []ICEServer{{URLs: []string{"stun:stun.cloudflare.com:3478"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want STUN only", got)
	}
}
