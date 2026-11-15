package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

// sendAt stores a message with an explicit time, so tests don't depend on
// two NOW()s in a row being different.
func sendAt(t *testing.T, from, to, content string, at time.Time) {
	t.Helper()
	if _, err := config.DB.Exec(context.Background(),
		`INSERT INTO messages (sender_id, receiver_id, content, created_at) VALUES ($1::uuid, $2::uuid, $3, $4)`,
		from, to, content, at); err != nil {
		t.Fatal(err)
	}
}

func historyOf(t *testing.T, reader, peer string) []string {
	t.Helper()
	msgs, err := NewMessageRepository().GetChatHistory(context.Background(), reader, peer, time.Now().Add(time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, m := range msgs {
		out = append(out, m.Content)
	}
	return out
}

// conversationWith returns the caller's inbox entry for a peer or group, or
// nil when there is none.
func conversationWith(t *testing.T, reader, id string) *struct {
	Last   string
	Unread int
} {
	t.Helper()
	list, err := NewMessageRepository().GetConversations(context.Background(), reader)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range list {
		if c.ID == id {
			return &struct {
				Last   string
				Unread int
			}{c.LastMessage, c.UnreadCount}
		}
	}
	return nil
}

func TestClearDirectHidesHistoryForTheCallerOnly(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Minute)
	sendAt(t, alice, bob, "a1", past)
	sendAt(t, bob, alice, "b1", past.Add(time.Second))

	if _, err := NewMessageRepository().ClearDirect(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}

	if got := historyOf(t, alice, bob); len(got) != 0 {
		t.Errorf("alice should see no history after clearing, got %v", got)
	}
	if c := conversationWith(t, alice, bob); c != nil {
		t.Errorf("the conversation should leave alice's inbox, got %+v", *c)
	}
	if got := historyOf(t, bob, alice); len(got) != 2 {
		t.Errorf("bob's history must be untouched, got %v", got)
	}
	if c := conversationWith(t, bob, alice); c == nil {
		t.Error("the conversation must stay in bob's inbox")
	}
}

func TestClearedConversationComesBackWithANewMessage(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Minute)
	sendAt(t, bob, alice, "old 1", past)
	sendAt(t, bob, alice, "old 2", past.Add(time.Second))

	if c := conversationWith(t, alice, bob); c == nil || c.Unread != 2 {
		t.Fatalf("expected 2 unread before clearing, got %+v", c)
	}
	if _, err := NewMessageRepository().ClearDirect(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	sendAt(t, bob, alice, "new", time.Now().Add(time.Second))

	c := conversationWith(t, alice, bob)
	if c == nil || c.Last != "new" {
		t.Fatalf("a new message should bring the conversation back, got %+v", c)
	}
	if c.Unread != 1 {
		t.Errorf("cleared messages must not count as unread: got %d, want 1", c.Unread)
	}
	if got := historyOf(t, alice, bob); len(got) != 1 || got[0] != "new" {
		t.Errorf("alice should see only the new message, got %v", got)
	}
}

func TestClearingAgainMovesTheCutOffForward(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	repo := NewMessageRepository()

	first, err := repo.ClearDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	sendAt(t, bob, alice, "between", time.Now().Add(time.Second))
	time.Sleep(1100 * time.Millisecond)
	second, err := repo.ClearDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if !second.After(first) {
		t.Errorf("second clear %v should be after the first %v", second, first)
	}
	if got := historyOf(t, alice, bob); len(got) != 0 {
		t.Errorf("the second clear should hide the message in between, got %v", got)
	}
}

func TestDeleteForEveryoneRemovesOnlyYourOwnMessages(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Minute)
	sendAt(t, alice, bob, "from alice 1", past)
	sendAt(t, bob, alice, "from bob", past.Add(time.Second))
	sendAt(t, alice, bob, "from alice 2", past.Add(2*time.Second))

	deleted, _, err := NewMessageRepository().DeleteOwnDirectMessages(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 2 {
		t.Errorf("deleted %d messages, want alice's 2", deleted)
	}
	if got := historyOf(t, bob, alice); len(got) != 1 || got[0] != "from bob" {
		t.Errorf("bob should keep only his own message, got %v", got)
	}
	if got := historyOf(t, alice, bob); len(got) != 0 {
		t.Errorf("alice's view should be cleared too, got %v", got)
	}
}

func TestDeletingAConversationWithAnUnknownUserFails(t *testing.T) {
	ctx := context.Background()
	alice := contactTestUser(t, "alice")
	nobody := "00000000-0000-4000-8000-000000000000"
	repo := NewMessageRepository()

	if _, err := repo.ClearDirect(ctx, alice, nobody); !errors.Is(err, ErrUnknownPeer) {
		t.Errorf("clear: want ErrUnknownPeer, got %v", err)
	}
	if _, _, err := repo.DeleteOwnDirectMessages(ctx, alice, nobody); !errors.Is(err, ErrUnknownPeer) {
		t.Errorf("delete: want ErrUnknownPeer, got %v", err)
	}
}

func groupHistory(t *testing.T, groupID, reader string) []string {
	t.Helper()
	msgs, err := NewGroupRepository().GetGroupMessages(context.Background(), groupID, reader, time.Now().Add(time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, m := range msgs {
		out = append(out, m.Content)
	}
	return out
}

func TestClearGroupHidesHistoryForTheCallerOnly(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	groups := NewGroupRepository()
	group, err := groups.Create(ctx, "crew", alice)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = groups.Delete(context.Background(), group.ID) })
	if err := groups.AddMember(ctx, group.ID, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := config.DB.Exec(ctx,
		`INSERT INTO messages (sender_id, group_id, content, created_at) VALUES ($1::uuid, $2::uuid, 'hello crew', $3)`,
		alice, group.ID, time.Now().Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}

	if _, err := groups.ClearGroup(ctx, bob, group.ID); err != nil {
		t.Fatal(err)
	}
	if got := groupHistory(t, group.ID, bob); len(got) != 0 {
		t.Errorf("bob cleared the group, but still sees %v", got)
	}
	if got := groupHistory(t, group.ID, alice); len(got) != 1 {
		t.Errorf("alice's group history must be untouched, got %v", got)
	}
	if role, err := groups.GetRole(ctx, group.ID, bob); err != nil || role == "" {
		t.Errorf("clearing must not remove bob from the group (role %q, err %v)", role, err)
	}
}

func TestDeleteGroupRemovesItsMessagesAndMembers(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	groups := NewGroupRepository()
	group, err := groups.Create(ctx, "doomed", alice)
	if err != nil {
		t.Fatal(err)
	}
	if err := groups.AddMember(ctx, group.ID, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := config.DB.Exec(ctx,
		`INSERT INTO messages (sender_id, group_id, content) VALUES ($1::uuid, $2::uuid, 'bye')`, alice, group.ID); err != nil {
		t.Fatal(err)
	}

	if err := groups.Delete(ctx, group.ID); err != nil {
		t.Fatal(err)
	}

	var left int
	if err := config.DB.QueryRow(ctx,
		`SELECT (SELECT COUNT(*) FROM messages WHERE group_id = $1::uuid) + (SELECT COUNT(*) FROM group_members WHERE group_id = $1::uuid)`,
		group.ID).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("%d messages or memberships survived the group", left)
	}
	if c := conversationWith(t, bob, group.ID); c != nil {
		t.Errorf("the deleted group is still in bob's inbox: %+v", *c)
	}
}
