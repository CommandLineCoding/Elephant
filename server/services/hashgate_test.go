package services

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/repository"
)

func TestHashGateLimitsConcurrency(t *testing.T) {
	gate := newHashGate(2, 5*time.Second)

	var running, peak int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := gate.acquire(); err != nil {
				t.Error(err)
				return
			}
			n := atomic.AddInt32(&running, 1)
			for {
				old := atomic.LoadInt32(&peak)
				if n <= old || atomic.CompareAndSwapInt32(&peak, old, n) {
					break
				}
			}
			time.Sleep(10 * time.Millisecond)
			atomic.AddInt32(&running, -1)
			gate.release()
		}()
	}
	wg.Wait()

	if peak > 2 {
		t.Errorf("%d hashes ran at once, the limit is 2", peak)
	}
	if peak < 2 {
		t.Errorf("only %d ran at once, the gate is too strict", peak)
	}
}

func TestHashGateGivesUpWhenItStaysFull(t *testing.T) {
	gate := newHashGate(1, 40*time.Millisecond)
	if err := gate.acquire(); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	err := gate.acquire()
	if !errors.Is(err, ErrServerBusy) {
		t.Fatalf("expected ErrServerBusy, got %v", err)
	}
	if waited := time.Since(start); waited < 30*time.Millisecond || waited > time.Second {
		t.Errorf("waited %v, expected about 40ms", waited)
	}

	gate.release()
	if err := gate.acquire(); err != nil {
		t.Errorf("a released slot should be usable again: %v", err)
	}
}

func TestMaxConcurrentHashesParsing(t *testing.T) {
	old := env.ARGON_MAX_CONCURRENT
	t.Cleanup(func() { env.ARGON_MAX_CONCURRENT = old })

	for value, want := range map[string]int{"4": 4, " 3 ": 3, "": 2, "0": 2, "-1": 2, "many": 2} {
		env.ARGON_MAX_CONCURRENT = value
		if got := maxConcurrentHashes(); got != want {
			t.Errorf("ARGON_MAX_CONCURRENT=%q: got %d, want %d", value, got, want)
		}
	}
}

// Swaps the shared gate for a full one, so password work can't get a slot.
func fullPasswordGate(t *testing.T) {
	t.Helper()
	old := passwordGate
	passwordGate = newHashGate(1, 30*time.Millisecond)
	if err := passwordGate.acquire(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { passwordGate = old })
}

func TestPasswordHashingGoesThroughTheGate(t *testing.T) {
	hash, err := HashPassword("correct horse battery")
	if err != nil {
		t.Fatal(err)
	}

	fullPasswordGate(t)

	if _, err := HashPassword("another password"); !errors.Is(err, ErrServerBusy) {
		t.Errorf("HashPassword with a full gate: got %v, want ErrServerBusy", err)
	}
	if _, err := VerifyPassword("correct horse battery", hash); !errors.Is(err, ErrServerBusy) {
		t.Errorf("VerifyPassword with a full gate: got %v, want ErrServerBusy", err)
	}
}

// A busy server must not look like a wrong password: the user would retype a
// correct one, and clients would show "invalid credentials".
func TestLoginReportsBusyNotWrongPassword(t *testing.T) {
	uid := newTestUser(t) // inserts a user with a placeholder hash
	hash, err := HashPassword("correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	db := pushTestDB(t)
	var username string
	if err := db.QueryRow(context.Background(),
		`UPDATE users SET password_hash = $1 WHERE id = $2::uuid RETURNING username`, hash, uid).Scan(&username); err != nil {
		t.Fatal(err)
	}

	svc := &AuthService{repo: repository.NewUserRepository()}
	if _, _, err := svc.Login(context.Background(), username, "correct horse battery"); err != nil {
		t.Fatalf("a correct password should log in: %v", err)
	}

	fullPasswordGate(t)
	_, _, err = svc.Login(context.Background(), username, "correct horse battery")
	if !errors.Is(err, ErrServerBusy) {
		t.Errorf("a busy server should say so, got %v", err)
	}
}
