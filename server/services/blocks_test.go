package services

import (
	"context"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/repository"
)

// The hub tests run without a database, so by default nobody has blocked
// anyone. The real lookup is tested in the repository package.
func init() {
	blockLookup = func(context.Context, string, string) bool { return false }
	// Likewise nobody has changed their privacy settings. Tests that care
	// install their own with setSettings. The hub's own ids aren't UUIDs, so
	// the real lookup would fail on them.
	Hub.settings = func(context.Context, string) (repository.UserSettings, error) {
		return repository.DefaultUserSettings(), nil
	}
	// And every group lets everyone in it post.
	groupPosting = func(context.Context, string, string) (bool, bool, error) { return true, true, nil }
	// And no direct chat is a message request.
	requestOpen = func(context.Context, string, string) (bool, error) { return false, nil }
	requestPending = func(context.Context, string, string) (bool, error) { return false, nil }
	requestAccept = func(context.Context, string, string) (bool, error) { return false, nil }
}

func setBlockLookup(f func(context.Context, string, string) bool) {
	blockLookupLock.Lock()
	defer blockLookupLock.Unlock()
	blockLookup = f
}

// setBlocks makes blockedBy answer from a fixed list of blocker->sender pairs.
func setBlocks(t *testing.T, pairs ...[2]string) {
	t.Helper()
	blockLookupLock.RLock()
	old := blockLookup
	blockLookupLock.RUnlock()
	setBlockLookup(func(_ context.Context, recipient, sender string) bool {
		for _, p := range pairs {
			if p[0] == recipient && p[1] == sender {
				return true
			}
		}
		return false
	})
	t.Cleanup(func() { setBlockLookup(old) })
}

func TestBlockedSenderCantReachYou(t *testing.T) {
	// alice blocked bob; carol is not blocked.
	setBlocks(t, [2]string{"blk-alice", "blk-bob"})
	alice := hubClient(t, "blk-alice")
	bob := connect(t, "blk-bob")
	carol := connect(t, "blk-carol")

	for _, event := range []string{"typing", "read_receipt", "chat"} {
		bob.send(t, map[string]interface{}{"type": event, "receiver_id": "blk-alice", "content": "x"})
		if _, ok := received(alice, event, 300*time.Millisecond); ok {
			t.Errorf("a %s from someone she blocked reached alice", event)
		}
	}

	// Someone else still gets through.
	carol.send(t, map[string]interface{}{"type": "typing", "receiver_id": "blk-alice"})
	if _, ok := received(alice, "typing", 3*time.Second); !ok {
		t.Error("typing from someone alice didn't block never arrived")
	}
}

func TestBlockingDoesNotStopTheOtherDirection(t *testing.T) {
	// alice blocked bob, but alice's own typing still reaches bob: blocking
	// is about what reaches the person who blocked.
	setBlocks(t, [2]string{"dir-alice", "dir-bob"})
	alice := connect(t, "dir-alice")
	bob := hubClient(t, "dir-bob")

	alice.send(t, map[string]interface{}{"type": "typing", "receiver_id": "dir-bob"})
	if _, ok := received(bob, "typing", 3*time.Second); !ok {
		t.Error("alice's typing should still reach bob")
	}
}

func TestEditsFromABlockedSenderAreDropped(t *testing.T) {
	setBlocks(t, [2]string{"edblk-alice", "edblk-bob"})
	alice := hubClient(t, "edblk-alice")

	Hub.PublishMessageEdit(context.Background(), editedMessage("edblk-bob", "edblk-alice", ""))
	if _, ok := received(alice, "message_edited", 300*time.Millisecond); ok {
		t.Error("an edit from someone alice blocked reached her")
	}
}
