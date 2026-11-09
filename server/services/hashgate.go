package services

import (
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
)

// ErrServerBusy is returned when too many password hashes are already running.
var ErrServerBusy = errors.New("the server is busy, please try again in a moment")

// hashGate limits how many Argon2 hashes run at the same time. Each one holds
// ARGON_MEMORY of RAM, so without a limit a burst of logins (or someone sending
// them on purpose) can use more memory than a small instance has. Extra
// requests wait their turn, and give up after a while rather than queueing
// forever.
type hashGate struct {
	slots chan struct{}
	wait  time.Duration
}

func newHashGate(concurrent int, wait time.Duration) *hashGate {
	if concurrent < 1 {
		concurrent = 1
	}
	return &hashGate{slots: make(chan struct{}, concurrent), wait: wait}
}

func (g *hashGate) acquire() error {
	select {
	case g.slots <- struct{}{}:
		return nil
	default:
	}

	timer := time.NewTimer(g.wait)
	defer timer.Stop()
	select {
	case g.slots <- struct{}{}:
		return nil
	case <-timer.C:
		return ErrServerBusy
	}
}

// release gives a slot back. A release without a matching acquire is ignored
// rather than blocking, so a mistake can't wedge the server.
func (g *hashGate) release() {
	select {
	case <-g.slots:
	default:
	}
}

// passwordGate is shared by every place that hashes or verifies a password.
var passwordGate = newHashGate(maxConcurrentHashes(), 10*time.Second)

func maxConcurrentHashes() int {
	n, err := strconv.Atoi(strings.TrimSpace(env.ARGON_MAX_CONCURRENT))
	if err != nil || n < 1 {
		return 2
	}
	return n
}
