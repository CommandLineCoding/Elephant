package repository

import (
	"context"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

func deliveredAt(t *testing.T, id string) *time.Time {
	t.Helper()
	var at *time.Time
	if err := config.DB.QueryRow(context.Background(),
		`SELECT delivered_at FROM messages WHERE id = $1::uuid`, id).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func TestMarkDeliveredTellsEachSenderWhatReached(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob, carol := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "carol")
	past := time.Now().Add(-time.Minute)
	a1 := sendMsg(t, alice, carol, "from alice", past)
	b1 := sendMsg(t, bob, carol, "from bob", past)
	a2 := sendMsg(t, alice, carol, "alice again", past.Add(time.Second))

	bySender, at, err := repo.MarkDelivered(ctx, carol, []string{a1, b1, a2})
	if err != nil {
		t.Fatal(err)
	}
	if len(bySender) != 2 || len(bySender[alice]) != 2 || len(bySender[bob]) != 1 || bySender[bob][0] != b1 {
		t.Errorf("by sender = %v", bySender)
	}
	if at.IsZero() {
		t.Error("no delivery time")
	}
	for _, id := range []string{a1, b1, a2} {
		if deliveredAt(t, id) == nil {
			t.Errorf("message %s was not marked", id)
		}
	}
}

func TestMarkDeliveredOnlyCountsMessagesToTheCaller(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob, eve := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "eve")
	toBob := sendMsg(t, alice, bob, "for bob", time.Now().Add(-time.Minute))

	// Someone else can't say it reached Bob, and the sender can't say it for them.
	for name, who := range map[string]string{"a stranger": eve, "the sender": alice} {
		bySender, _, err := repo.MarkDelivered(ctx, who, []string{toBob})
		if err != nil {
			t.Fatal(err)
		}
		if len(bySender) != 0 {
			t.Errorf("%s marked it: %v", name, bySender)
		}
	}
	if deliveredAt(t, toBob) != nil {
		t.Fatal("the message was marked by someone it wasn't sent to")
	}
}

func TestMarkDeliveredHappensOnceAndKeepsItsTime(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	id := sendMsg(t, alice, bob, "hi", time.Now().Add(-time.Minute))

	if _, _, err := repo.MarkDelivered(ctx, bob, []string{id}); err != nil {
		t.Fatal(err)
	}
	first := deliveredAt(t, id)
	time.Sleep(20 * time.Millisecond)

	bySender, _, err := repo.MarkDelivered(ctx, bob, []string{id})
	if err != nil {
		t.Fatal(err)
	}
	if len(bySender) != 0 {
		t.Errorf("reported again: %v", bySender)
	}
	if second := deliveredAt(t, id); !second.Equal(*first) {
		t.Errorf("delivery time moved from %v to %v", first, second)
	}
}

func TestMarkDeliveredIgnoresGroupMessagesAndUnknownIDs(t *testing.T) {
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
	var gid string
	if err := config.DB.QueryRow(ctx,
		`INSERT INTO messages (sender_id, group_id, content) VALUES ($1::uuid, $2::uuid, 'hello crew') RETURNING id::text`,
		alice, group.ID).Scan(&gid); err != nil {
		t.Fatal(err)
	}

	bySender, _, err := NewMessageRepository().MarkDelivered(ctx, bob,
		[]string{gid, "00000000-0000-4000-8000-000000000000"})
	if err != nil || len(bySender) != 0 {
		t.Fatalf("got %v, %v", bySender, err)
	}
	if deliveredAt(t, gid) != nil {
		t.Error("a group message was marked delivered")
	}
}

func TestReadingAMessageAlsoDeliversIt(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	id := sendMsg(t, alice, bob, "hi", time.Now().Add(-time.Minute))

	if err := NewMessageRepository().MarkAsRead(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}
	if deliveredAt(t, id) == nil {
		t.Error("a read message should count as delivered (older apps never say so)")
	}
}

func TestHistoryShowsWhenMessagesWereDelivered(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	sent := sendMsg(t, alice, bob, "delivered one", past)
	sendMsg(t, alice, bob, "waiting one", past.Add(time.Minute))
	if _, _, err := NewMessageRepository().MarkDelivered(ctx, bob, []string{sent}); err != nil {
		t.Fatal(err)
	}

	msgs := historyMessages(t, alice, bob)
	if len(msgs) != 2 {
		t.Fatalf("history = %+v", msgs)
	}
	if msgs[0].Content != "waiting one" || msgs[0].DeliveredAt != nil {
		t.Errorf("the waiting message: %+v", msgs[0])
	}
	if msgs[1].DeliveredAt == nil {
		t.Errorf("the delivered message has no delivered_at: %+v", msgs[1])
	}
}
