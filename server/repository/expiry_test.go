package repository

import (
	"context"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

func setExpiry(t *testing.T, id string, at time.Time) {
	t.Helper()
	if _, err := config.DB.Exec(context.Background(),
		`UPDATE messages SET expires_at = $2 WHERE id = $1::uuid`, id, at); err != nil {
		t.Fatal(err)
	}
}

func inHistory(t *testing.T, reader, peer, id string) (found bool, expires *time.Time) {
	t.Helper()
	for _, m := range historyMessages(t, reader, peer) {
		if m.ID == id {
			return true, m.ExpiresAt
		}
	}
	return false, nil
}

func TestAMessageThatHasExpiredLeavesTheHistory(t *testing.T) {
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	live := sendMsg(t, alice, bob, "still here", past)
	soon := sendMsg(t, alice, bob, "goes soon", past.Add(time.Second))
	gone := sendMsg(t, alice, bob, "already gone", past.Add(2*time.Second))
	forever := sendMsg(t, alice, bob, "stays", past.Add(3*time.Second))
	setExpiry(t, soon, time.Now().Add(time.Hour))
	setExpiry(t, gone, time.Now().Add(-time.Second))

	for who, pair := range map[string][2]string{"the sender": {alice, bob}, "the recipient": {bob, alice}} {
		if ok, _ := inHistory(t, pair[0], pair[1], gone); ok {
			t.Errorf("%s still gets the expired message", who)
		}
		for name, id := range map[string]string{"plain": live, "forever": forever} {
			if ok, at := inHistory(t, pair[0], pair[1], id); !ok || at != nil {
				t.Errorf("%s: the %s message is missing or has an expiry (found=%v at=%v)", who, name, ok, at)
			}
		}
		if ok, at := inHistory(t, pair[0], pair[1], soon); !ok || at == nil || time.Until(*at) < 50*time.Minute {
			t.Errorf("%s: a message with an hour left: found=%v expires=%v", who, ok, at)
		}
	}
}

func TestTheChatListIgnoresExpiredMessages(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	old := sendMsg(t, alice, bob, "the one that stays", past)
	_ = old
	newest := sendMsg(t, alice, bob, "this one disappears", past.Add(time.Minute))

	last := func() (text string, unread int) {
		convs, err := repo.GetConversations(ctx, bob)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range convs {
			if c.ID == alice {
				return c.LastMessage, c.UnreadCount
			}
		}
		return "", 0
	}
	if text, unread := last(); text != "this one disappears" || unread != 2 {
		t.Fatalf("before: %q unread %d", text, unread)
	}
	setExpiry(t, newest, time.Now().Add(-time.Second))
	if text, unread := last(); text != "the one that stays" || unread != 1 {
		t.Errorf("after it expired: last %q, unread %d, want the earlier one and 1", text, unread)
	}
}

func TestAnExpiredMessageCannotBeQuoted(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	id := sendMsg(t, alice, bob, "secret plan", time.Now().Add(-time.Hour))
	if q, err := repo.GetMessagePreview(ctx, id); err != nil || q == nil {
		t.Fatalf("a live message can be quoted: %v %v", q, err)
	}
	setExpiry(t, id, time.Now().Add(-time.Second))
	if q, err := repo.GetMessagePreview(ctx, id); err == nil && q != nil {
		t.Errorf("an expired message was quoted: %+v", q)
	}
}

func TestAGroupHistoryLeavesOutExpiredMessages(t *testing.T) {
	ctx := context.Background()
	alice := contactTestUser(t, "alice")
	g, err := NewGroupRepository().Create(ctx, "Trek", alice)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(ctx, "DELETE FROM groups WHERE id = $1::uuid", g.ID) })
	add := func(text string) string {
		var id string
		if err := config.DB.QueryRow(ctx,
			`INSERT INTO messages (sender_id, group_id, content) VALUES ($1::uuid, $2::uuid, $3) RETURNING id::text`,
			alice, g.ID, text).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	keep, soon, gone := add("keep"), add("soon"), add("gone")
	setExpiry(t, soon, time.Now().Add(time.Hour))
	setExpiry(t, gone, time.Now().Add(-time.Second))

	msgs, err := NewGroupRepository().GetGroupMessages(ctx, g.ID, alice, time.Now().Add(time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, m := range msgs {
		seen[m.ID] = true
		if m.ID == soon && m.ExpiresAt == nil {
			t.Error("a message with time left doesn't say when it ends")
		}
	}
	if !seen[keep] || !seen[soon] || seen[gone] {
		t.Errorf("keep=%v soon=%v gone=%v", seen[keep], seen[soon], seen[gone])
	}
}

func TestTheCleanupDeletesOnlyWhatHasExpired(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	keep := sendMsg(t, alice, bob, "keep", past)
	later := sendMsg(t, alice, bob, "later", past.Add(time.Second))
	gone1 := sendMsg(t, alice, bob, "gone 1", past.Add(2*time.Second))
	gone2 := sendMsg(t, alice, bob, "gone 2", past.Add(3*time.Second))
	setExpiry(t, later, time.Now().Add(time.Hour))
	setExpiry(t, gone1, time.Now().Add(-time.Minute))
	setExpiry(t, gone2, time.Now().Add(-time.Second))

	count := func(id string) int {
		var n int
		_ = config.DB.QueryRow(ctx, `SELECT count(*) FROM messages WHERE id = $1::uuid`, id).Scan(&n)
		return n
	}
	repo := NewCleanupRepository()
	// A batch of one deletes one, and a second call the other.
	n1, err := repo.DeleteExpiredMessages(ctx, 1)
	if err != nil || n1 != 1 {
		t.Fatalf("first batch: %d %v", n1, err)
	}
	for {
		n, err := repo.DeleteExpiredMessages(ctx, 100)
		if err != nil {
			t.Fatal(err)
		}
		if n == 0 {
			break
		}
	}
	if count(gone1) != 0 || count(gone2) != 0 {
		t.Error("an expired message is still stored")
	}
	if count(keep) != 1 || count(later) != 1 {
		t.Error("a message that hasn't expired was deleted")
	}
}
