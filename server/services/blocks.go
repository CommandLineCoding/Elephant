package services

import (
	"context"
	"log"
	"sync"

	"github.com/commandlinecoding/elephant/server/repository"
)

// blockLookup reports whether recipient has blocked sender. A failed lookup is
// logged and treated as "not blocked", so a database hiccup doesn't silently
// drop someone's messages. It is a variable so tests can run the hub without
// a database; they replace it under blockLookupLock while the hub's
// goroutines run.
var (
	blockLookup = func(ctx context.Context, recipient, sender string) bool {
		blocked, err := repository.NewBlockRepository().IsBlocked(ctx, recipient, sender)
		if err != nil {
			log.Printf("Couldn't check for a block, delivering anyway: %v", err)
			return false
		}
		return blocked
	}
	blockLookupLock sync.RWMutex
)

func blockedBy(ctx context.Context, recipient, sender string) bool {
	blockLookupLock.RLock()
	lookup := blockLookup
	blockLookupLock.RUnlock()
	return lookup(ctx, recipient, sender)
}

// IsBlockedBy reports whether recipient has blocked sender. A blocked
// sender's direct messages, typing indicators, read receipts and edits are
// dropped without telling them.
func IsBlockedBy(ctx context.Context, recipient, sender string) bool {
	return blockedBy(ctx, recipient, sender)
}
