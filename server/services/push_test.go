package services

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestValidatePushEndpoint(t *testing.T) {
	long := "https://ntfy.example.org/" + strings.Repeat("a", maxPushEndpointLength)

	cases := []struct {
		name         string
		endpoint     string
		allowPrivate bool
		ok           bool
	}{
		{"https public host", "https://ntfy.example.org/upAbC123", false, true},
		{"https with port", "https://ntfy.example.org:8443/upAbC123", false, true},
		{"empty", "", false, false},
		{"not a url", "not a url", false, false},
		{"no host", "https:///path", false, false},
		{"plain http", "http://ntfy.example.org/up", false, false},
		{"ftp", "ftp://ntfy.example.org/up", false, false},
		{"credentials", "https://user:pass@ntfy.example.org/up", false, false},
		{"too long", long, false, false},
		{"localhost", "https://localhost/up", false, false},
		{"loopback v4", "https://127.0.0.1/up", false, false},
		{"loopback v6", "https://[::1]/up", false, false},
		{"private 10/8", "https://10.1.2.3/up", false, false},
		{"private 192.168", "https://192.168.1.10/up", false, false},
		{"private 172.16", "https://172.16.0.5/up", false, false},
		{"unique local v6", "https://[fd00::1]/up", false, false},
		{"cgnat / tailscale", "https://100.101.102.103/up", false, false},
		{"cloud metadata", "https://169.254.169.254/latest/meta-data", false, false},
		{"unspecified", "https://0.0.0.0/up", false, false},
		{"v4-mapped loopback", "https://[::ffff:127.0.0.1]/up", false, false},

		// A self-hosted ntfy on the LAN is fine when the operator allows it.
		{"http on LAN, allowed", "http://192.168.1.10:8080/up", true, true},
		{"localhost, allowed", "http://localhost:8080/up", true, true},
		{"loopback, allowed", "http://127.0.0.1:8080/up", true, true},
		{"tailscale, allowed", "https://100.101.102.103/up", true, true},
		// ...but never the metadata address or other reserved ranges.
		{"metadata, even if allowed", "http://169.254.169.254/latest", true, false},
		{"link-local v6, even if allowed", "http://[fe80::1]/up", true, false},
		{"unspecified, even if allowed", "http://0.0.0.0/up", true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := validatePushEndpoint(c.endpoint, c.allowPrivate)
			if c.ok && err != nil {
				t.Errorf("expected %q to be accepted, got %v", c.endpoint, err)
			}
			if !c.ok {
				if err == nil {
					t.Fatalf("expected %q to be rejected", c.endpoint)
				}
				if !errors.Is(err, ErrInvalidPushEndpoint) {
					t.Errorf("rejection should wrap ErrInvalidPushEndpoint, got %v", err)
				}
			}
		})
	}
}

// The real enforcement: the client checks the address it connects to, so a
// hostname that resolves to a private address is refused too.
func TestPushClientRefusesPrivateAddresses(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
	}))
	t.Cleanup(srv.Close)

	// srv listens on 127.0.0.1.
	strict := &PushService{client: newPushClient(false)}
	if _, err := strict.send(context.Background(), srv.URL); !errors.Is(err, errBlockedAddress) {
		t.Errorf("connecting to loopback should be blocked, got %v", err)
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Error("the request reached a loopback server")
	}

	// A hostname that resolves to loopback is blocked as well.
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if _, err := strict.send(context.Background(), "http://localhost:"+port); !errors.Is(err, errBlockedAddress) {
		t.Errorf("a name resolving to loopback should be blocked, got %v", err)
	}

	lenient := &PushService{client: newPushClient(true)}
	if _, err := lenient.send(context.Background(), srv.URL); err != nil {
		t.Errorf("loopback should be reachable when private endpoints are allowed: %v", err)
	}
	if atomic.LoadInt32(&hits) != 1 {
		t.Errorf("expected one request to the allowed server, got %d", hits)
	}

	// Cloud metadata is never reachable, whatever the setting.
	if _, err := lenient.send(context.Background(), "http://169.254.169.254/latest/meta-data"); !errors.Is(err, errBlockedAddress) {
		t.Errorf("the metadata address must always be blocked, got %v", err)
	}
}

func TestPushClientDoesNotFollowRedirects(t *testing.T) {
	var targetHits int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&targetHits, 1)
	}))
	t.Cleanup(target.Close)
	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	t.Cleanup(redirector.Close)

	p := &PushService{client: newPushClient(true)}
	gone, err := p.send(context.Background(), redirector.URL)

	if atomic.LoadInt32(&targetHits) != 0 {
		t.Error("the redirect was followed")
	}
	if gone || err == nil {
		t.Errorf("a redirect should be a plain failure, got gone=%v err=%v", gone, err)
	}
}

func TestPushSendInterpretsStatusCodes(t *testing.T) {
	for status, want := range map[int]struct{ gone, failed bool }{
		200: {false, false},
		201: {false, false},
		204: {false, false},
		404: {true, false},
		410: {true, false},
		400: {false, true},
		500: {false, true},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
		p := &PushService{client: newPushClient(true)}
		gone, err := p.send(context.Background(), srv.URL)
		srv.Close()

		if gone != want.gone || (err != nil) != want.failed {
			t.Errorf("status %d: gone=%v err=%v, want gone=%v failed=%v", status, gone, err, want.gone, want.failed)
		}
	}
}

// The endpoint URL is a secret, so errors must not carry it into the logs.
func TestPushErrorsDoNotLeakTheEndpoint(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close() // nothing is listening any more

	p := &PushService{client: newPushClient(true)}
	_, err = p.send(context.Background(), "http://"+addr+"/up-secret-topic-123")
	if err == nil {
		t.Fatal("expected a connection error")
	}
	if strings.Contains(err.Error(), "secret-topic") {
		t.Errorf("error leaks the endpoint: %v", err)
	}
	if hostOf("https://ntfy.example.org/up-secret-topic-123") != "ntfy.example.org" {
		t.Error("hostOf should return only the host")
	}
}

// --- tests that need a database ---

var pushDBOnce sync.Once

// pushTestDB points config.DB at the test database, or skips the test.
func pushTestDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	pushDBOnce.Do(func() {
		dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
			env.POSTGRES_USER, env.POSTGRES_PASSWORD, env.POSTGRES_HOST, env.POSTGRES_PORT, env.POSTGRES_DB)
		pool, err := pgxpool.New(context.Background(), dsn)
		if err == nil {
			err = pool.Ping(context.Background())
		}
		if err == nil {
			config.DB = pool
		}
	})
	if config.DB == nil {
		t.Skip("no database available")
	}
	return config.DB
}

func newTestUser(t *testing.T) string {
	t.Helper()
	db := pushTestDB(t)
	var id string
	err := db.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash)
		 VALUES ($1, 'Push Test', 'x') RETURNING id::text`,
		fmt.Sprintf("pushtest.%d", time.Now().UnixNano())).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

func fastPushService() *PushService {
	p := NewPushService(true)
	p.settle = 20 * time.Millisecond
	p.minInterval = 300 * time.Millisecond
	p.Start(2)
	return p
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestPushPingsEndpointsAndDropsDeadOnes(t *testing.T) {
	db := pushTestDB(t)
	uid := newTestUser(t)

	type hit struct{ method, body, ttl, contentType string }
	hits := make(chan hit, 10)
	alive := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		hits <- hit{r.Method, string(b), r.Header.Get("TTL"), r.Header.Get("Content-Type")}
	}))
	t.Cleanup(alive.Close)
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusGone) }))
	t.Cleanup(dead.Close)

	repo := repository.NewPushRepository()
	for _, ep := range []string{alive.URL + "/up1", dead.URL + "/up2"} {
		if err := repo.Upsert(context.Background(), uid, ep, MaxPushEndpointsPerUser); err != nil {
			t.Fatal(err)
		}
	}

	p := fastPushService()
	p.NotifyUsers([]string{uid})

	select {
	case h := <-hits:
		if h.method != http.MethodPost || h.body != pushPayload || h.ttl != "3600" || h.contentType != "application/json" {
			t.Errorf("unexpected ping: %+v", h)
		}
		if strings.Contains(h.body, "content") || strings.Contains(h.body, uid) {
			t.Error("the ping must not carry message content or user identifiers")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the live endpoint was never pinged")
	}

	eventually(t, "the dead (410) endpoint to be removed", func() bool {
		var n int
		_ = db.QueryRow(context.Background(), "SELECT count(*) FROM push_endpoints WHERE user_id = $1::uuid", uid).Scan(&n)
		return n == 1
	})
}

func TestPushCoalescesBurstsAndSpacesPings(t *testing.T) {
	uid := newTestUser(t)

	var mu sync.Mutex
	var times []time.Time
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		times = append(times, time.Now())
		mu.Unlock()
	}))
	t.Cleanup(srv.Close)
	if err := repository.NewPushRepository().Upsert(context.Background(), uid, srv.URL+"/up", MaxPushEndpointsPerUser); err != nil {
		t.Fatal(err)
	}
	count := func() int { mu.Lock(); defer mu.Unlock(); return len(times) }

	p := fastPushService()

	// Five messages in a burst are one ping.
	for i := 0; i < 5; i++ {
		p.NotifyUsers([]string{uid})
	}
	eventually(t, "the first ping", func() bool { return count() >= 1 })
	time.Sleep(150 * time.Millisecond)
	if n := count(); n != 1 {
		t.Fatalf("a burst of 5 messages sent %d pings, want 1", n)
	}

	// A message right after that is not lost: it schedules a later ping,
	// no sooner than minInterval after the first.
	p.NotifyUsers([]string{uid})
	eventually(t, "the second ping", func() bool { return count() >= 2 })
	mu.Lock()
	gap := times[1].Sub(times[0])
	mu.Unlock()
	if gap < p.minInterval-40*time.Millisecond {
		t.Errorf("pings were %v apart, want at least about %v", gap, p.minInterval)
	}
}

func TestPushForUserWithNoEndpointsIsHarmless(t *testing.T) {
	uid := newTestUser(t)
	p := fastPushService()
	p.NotifyUsers([]string{uid, "00000000-0000-0000-0000-000000000000"})
	time.Sleep(150 * time.Millisecond) // must not panic or block
}
