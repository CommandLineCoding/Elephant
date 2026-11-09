package middlewares

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/models"
)

// fakeClock lets tests move time without sleeping.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestLimiter(rate, max float64) (*RateLimiter, *fakeClock) {
	clock := &fakeClock{t: time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)}
	rl := NewRateLimiter(rate, max)
	rl.now = clock.now
	return rl, clock
}

func TestLimiterAllowsABurstThenBlocks(t *testing.T) {
	rl, _ := newTestLimiter(1, 3)
	for i := 0; i < 3; i++ {
		if ok, _ := rl.allow("a"); !ok {
			t.Fatalf("request %d of the burst was refused", i+1)
		}
	}
	ok, retry := rl.allow("a")
	if ok {
		t.Fatal("the request after the burst should be refused")
	}
	if retry <= 0 || retry > time.Second {
		t.Errorf("retry-after should be up to one refill interval, got %v", retry)
	}
}

func TestLimiterRefillsOverTime(t *testing.T) {
	rl, clock := newTestLimiter(1.0/5, 2) // one token every 5 s
	rl.allow("a")
	rl.allow("a")
	if ok, _ := rl.allow("a"); ok {
		t.Fatal("bucket should be empty")
	}

	clock.advance(4 * time.Second)
	if ok, _ := rl.allow("a"); ok {
		t.Error("4 s is not enough for a token at 1 per 5 s")
	}
	clock.advance(2 * time.Second)
	if ok, _ := rl.allow("a"); !ok {
		t.Error("6 s should have refilled a token")
	}
}

func TestLimiterTracksClientsSeparately(t *testing.T) {
	rl, _ := newTestLimiter(1, 1)
	rl.allow("a")
	if ok, _ := rl.allow("a"); ok {
		t.Fatal("a should be limited")
	}
	if ok, _ := rl.allow("b"); !ok {
		t.Error("b must not be limited by a")
	}
}

func TestLimiterForgetsIdleClients(t *testing.T) {
	rl, clock := newTestLimiter(1, 5)
	for i := 0; i < 3000; i++ {
		rl.allow(fmt.Sprintf("10.0.%d.%d", i/250, i%250))
	}
	if len(rl.clients) != 3000 {
		t.Fatalf("expected 3000 tracked clients, got %d", len(rl.clients))
	}

	clock.advance(time.Minute) // well past the time a bucket takes to refill
	rl.allow("someone-new")
	if n := len(rl.clients); n > 2 {
		t.Errorf("idle clients should have been swept, %d remain", n)
	}
}

func TestLimiterTableIsBounded(t *testing.T) {
	rl, _ := newTestLimiter(1, 1)
	for i := 0; i < maxTrackedClients+500; i++ {
		rl.allow(strconv.Itoa(i))
	}
	if n := len(rl.clients); n > maxTrackedClients+1 {
		t.Errorf("table grew to %d entries, want at most %d", n, maxTrackedClients+1)
	}

	// Past the cap, new addresses share one bucket rather than being locked out.
	var allowed int
	for i := 0; i < 5; i++ {
		if ok, _ := rl.allow(fmt.Sprintf("overflow-%d", i)); ok {
			allowed++
		}
	}
	if allowed > 1 {
		t.Errorf("the shared overflow bucket let %d requests through, want at most 1", allowed)
	}
}

func TestLimitMiddlewareReturnsJSON429WithRetryAfter(t *testing.T) {
	rl, _ := newTestLimiter(1.0/5, 2)
	rl.WithMessage("Too many sign-in attempts.")
	var served int
	h := rl.Limit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { served++ }))

	do := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest("POST", "/login", nil)
		req.RemoteAddr = "203.0.113.7:4444"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}

	do()
	do()
	w := do()

	if served != 2 {
		t.Errorf("the handler ran %d times, want 2", served)
	}
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content type = %q", ct)
	}
	if secs, err := strconv.Atoi(w.Header().Get("Retry-After")); err != nil || secs < 1 || secs > 5 {
		t.Errorf("Retry-After = %q, want 1 to 5 seconds", w.Header().Get("Retry-After"))
	}
	var resp models.JSONResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil || resp.Success || resp.Error != "Too many sign-in attempts." {
		t.Errorf("unexpected body: %+v (%v)", resp, err)
	}
}

// Behind a proxy, users are told apart by the forwarded address, not the proxy's.
func TestLimitMiddlewareUsesTheForwardedClientBehindAProxy(t *testing.T) {
	old := env.TRUSTED_PROXY_HOPS
	env.TRUSTED_PROXY_HOPS = "auto"
	t.Cleanup(func() { env.TRUSTED_PROXY_HOPS = old })

	rl, _ := newTestLimiter(1.0/60, 1)
	h := rl.Limit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	from := func(client string) int {
		req := httptest.NewRequest("POST", "/login", nil)
		req.RemoteAddr = "10.0.0.5:4444" // the proxy
		req.Header.Set("X-Forwarded-For", client)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w.Code
	}

	if from("198.51.100.1") != http.StatusOK || from("198.51.100.1") != http.StatusTooManyRequests {
		t.Error("the same client should be limited")
	}
	if from("198.51.100.2") != http.StatusOK {
		t.Error("a different client behind the same proxy must not be limited")
	}
}
