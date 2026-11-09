package middlewares

import (
	"encoding/json"
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
)

type clientBucket struct {
	tokens     float64
	lastRefill time.Time
}

const (
	// maxTrackedClients bounds the table, so a flood of different addresses
	// can't grow it without limit. Past it, new addresses share one bucket.
	maxTrackedClients = 50000
	overflowKey       = "overflow"
	sweepEvery        = 30 * time.Second
	sweepAbove        = 1024
)

type RateLimiter struct {
	mu        sync.Mutex
	clients   map[string]*clientBucket
	rate      float64 // tokens per second
	max       float64 // max burst capacity
	message   string
	now       func() time.Time
	lastSweep time.Time
}

func NewRateLimiter(rate, max float64) *RateLimiter {
	return &RateLimiter{
		clients: make(map[string]*clientBucket),
		rate:    rate,
		max:     max,
		message: "Rate limit exceeded. Please slow down.",
		now:     time.Now,
	}
}

// WithMessage sets the error text returned with a 429.
func (rl *RateLimiter) WithMessage(message string) *RateLimiter {
	rl.message = message
	return rl
}

// allow takes a token for the client. When there is none, it reports how long
// until one is available.
func (rl *RateLimiter) allow(key string) (ok bool, retryAfter time.Duration) {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := rl.now()
	rl.sweepLocked(now)

	bucket, exists := rl.clients[key]
	if !exists {
		if len(rl.clients) >= maxTrackedClients {
			key = overflowKey
			bucket, exists = rl.clients[key]
		}
		if !exists {
			bucket = &clientBucket{tokens: rl.max, lastRefill: now}
			rl.clients[key] = bucket
		}
	} else {
		bucket.tokens += now.Sub(bucket.lastRefill).Seconds() * rl.rate
		if bucket.tokens > rl.max {
			bucket.tokens = rl.max
		}
		bucket.lastRefill = now
	}

	if bucket.tokens < 1.0 {
		return false, time.Duration((1.0 - bucket.tokens) / rl.rate * float64(time.Second))
	}
	bucket.tokens -= 1.0
	return true, 0
}

// sweepLocked forgets clients that have been idle long enough to have a full
// bucket again, since they are indistinguishable from new ones.
func (rl *RateLimiter) sweepLocked(now time.Time) {
	if len(rl.clients) < sweepAbove || now.Sub(rl.lastSweep) < sweepEvery {
		return
	}
	rl.lastSweep = now
	idle := time.Duration(rl.max / rl.rate * float64(time.Second))
	for key, bucket := range rl.clients {
		if now.Sub(bucket.lastRefill) > idle {
			delete(rl.clients, key)
		}
	}
}

func (rl *RateLimiter) Limit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ok, retryAfter := rl.allow(ClientIP(r))
		if !ok {
			seconds := int(math.Ceil(retryAfter.Seconds()))
			if seconds < 1 {
				seconds = 1
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			w.WriteHeader(http.StatusTooManyRequests)
			_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: rl.message})
			return
		}

		next.ServeHTTP(w, r)
	})
}
