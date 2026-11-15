package services

import (
	"context"
	"log"

	"github.com/commandlinecoding/elephant/server/repository"
)

// blockedBy reports whether recipient has blocked sender. A failed lookup is
// logged and treated as "not blocked", so a database hiccup doesn't silently
// drop someone's messages. It is a variable so tests can run the hub without
// a database.
var blockedBy = func(ctx context.Context, recipient, sender string) bool {
	blocked, err := repository.NewBlockRepository().IsBlocked(ctx, recipient, sender)
	if err != nil {
		log.Printf("Couldn't check for a block, delivering anyway: %v", err)
		return false
	}
	return blocked
}

// IsBlockedBy reports whether recipient has blocked sender. A blocked
// sender's direct messages, typing indicators, read receipts and edits are
// dropped without telling them.
func IsBlockedBy(ctx context.Context, recipient, sender string) bool {
	return blockedBy(ctx, recipient, sender)
}
