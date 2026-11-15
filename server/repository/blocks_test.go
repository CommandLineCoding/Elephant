package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

func isBlocked(t *testing.T, blocker, sender string) bool {
	t.Helper()
	got, err := NewBlockRepository().IsBlocked(context.Background(), blocker, sender)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestBlockIsOneWayAndCanBeUndone(t *testing.T) {
	ctx := context.Background()
	repo := NewBlockRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")

	if err := repo.Block(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if err := repo.Block(ctx, alice, bob); err != nil {
		t.Fatalf("blocking twice should be fine, got %v", err)
	}
	if !isBlocked(t, alice, bob) {
		t.Error("alice blocked bob, but IsBlocked says no")
	}
	if isBlocked(t, bob, alice) {
		t.Error("blocking is one way: bob didn't block alice")
	}

	list, err := repo.ListBlocked(ctx, alice)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].ID != bob || list[0].Username == "" {
		t.Errorf("alice's blocked list should be just bob, got %+v", list)
	}

	if err := repo.Unblock(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if err := repo.Unblock(ctx, alice, bob); err != nil {
		t.Fatalf("unblocking twice should be fine, got %v", err)
	}
	if isBlocked(t, alice, bob) {
		t.Error("still blocked after unblocking")
	}
	if list, _ := repo.ListBlocked(ctx, alice); len(list) != 0 {
		t.Errorf("the list should be empty after unblocking, got %+v", list)
	}
}

func TestBlockingAnUnknownUserOrYourselfFails(t *testing.T) {
	ctx := context.Background()
	repo := NewBlockRepository()
	alice := contactTestUser(t, "alice")

	if err := repo.Block(ctx, alice, "00000000-0000-4000-8000-000000000000"); !errors.Is(err, ErrUnknownPeer) {
		t.Errorf("unknown user: want ErrUnknownPeer, got %v", err)
	}
	if err := repo.Block(ctx, alice, alice); err == nil {
		t.Error("the database must refuse blocking yourself")
	}
}

func TestBlockedPeopleLeaveEachOthersContacts(t *testing.T) {
	ctx := context.Background()
	repo := NewBlockRepository()
	alice, bob, carol := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "carol")
	sendAt(t, alice, bob, "hi bob", time.Now())
	sendAt(t, carol, alice, "hi alice", time.Now())

	if err := repo.Block(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if got := contactsOf(t, alice); !equal(got, sorted(carol)) {
		t.Errorf("alice's contacts should drop bob, got %v", got)
	}
	if got := contactsOf(t, bob); len(got) != 0 {
		t.Errorf("bob must not have alice as a contact once she blocked him, got %v", got)
	}

	if err := repo.Unblock(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if got := contactsOf(t, alice); !equal(got, sorted(bob, carol)) {
		t.Errorf("unblocking should bring bob back, got %v", got)
	}
}

func TestBlocksAreRemovedWithTheAccount(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	if err := NewBlockRepository().Block(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := config.DB.Exec(ctx, "DELETE FROM users WHERE id = $1::uuid", bob); err != nil {
		t.Fatal(err)
	}
	if list, _ := NewBlockRepository().ListBlocked(ctx, alice); len(list) != 0 {
		t.Errorf("a deleted account should leave the blocked list, got %+v", list)
	}
}
