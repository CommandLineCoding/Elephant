package repository

import (
	"context"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

func sendSilentAt(t *testing.T, from, to, content string, at time.Time) {
	t.Helper()
	if _, err := config.DB.Exec(context.Background(),
		`INSERT INTO messages (sender_id, receiver_id, content, created_at, silent) VALUES ($1::uuid, $2::uuid, $3, $4, TRUE)`,
		from, to, content, at); err != nil {
		t.Fatal(err)
	}
}

// A reaction is stored like a message, so history keeps it, but it must not be
// the chat's last message or count as unread.
func TestSilentMessagesStayInHistoryButNotInTheInbox(t *testing.T) {
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Minute)
	sendAt(t, alice, bob, "hello", past)
	sendSilentAt(t, alice, bob, "reaction", past.Add(time.Second))
	sendSilentAt(t, alice, bob, "another reaction", past.Add(2*time.Second))

	if got := historyOf(t, bob, alice); len(got) != 3 {
		t.Errorf("history should keep silent messages, got %v", got)
	}

	c := conversationWith(t, bob, alice)
	if c == nil {
		t.Fatal("bob has no conversation with alice")
	}
	if c.Last != "hello" {
		t.Errorf("last message = %q, want the last real message", c.Last)
	}
	if c.Unread != 1 {
		t.Errorf("unread = %d, want 1 (the silent ones don't count)", c.Unread)
	}
}

func TestAChatOfOnlySilentMessagesIsNotInTheInbox(t *testing.T) {
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	sendSilentAt(t, alice, bob, "reaction", time.Now().Add(-time.Minute))

	if c := conversationWith(t, bob, alice); c != nil {
		t.Errorf("a chat with only silent messages showed up: %+v", *c)
	}
}
