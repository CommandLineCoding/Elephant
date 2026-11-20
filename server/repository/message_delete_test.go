package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/jackc/pgx/v5"
)

// sendMsg stores a direct message and returns its ID.
func sendMsg(t *testing.T, from, to, content string, at time.Time) string {
	t.Helper()
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO messages (sender_id, receiver_id, content, created_at) VALUES ($1::uuid, $2::uuid, $3, $4) RETURNING id::text`,
		from, to, content, at).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func historyMessages(t *testing.T, reader, peer string) []models.Message {
	t.Helper()
	msgs, err := NewMessageRepository().GetChatHistory(context.Background(), reader, peer, time.Now().Add(time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	return msgs
}

func TestDeleteForEveryoneLeavesATombstone(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	sendMsg(t, alice, bob, "first", past)
	oops := sendMsg(t, alice, bob, "oops, wrong chat", past.Add(time.Minute))

	deleted, err := repo.DeleteForEveryone(ctx, alice, oops)
	if err != nil {
		t.Fatal(err)
	}
	if deleted.ID != oops || deleted.DeletedAt == nil || deleted.ReceiverID != bob || deleted.Content != "" {
		t.Fatalf("returned %+v", deleted)
	}

	// Both people see the same tombstone, in the same place.
	for _, reader := range []struct{ who, peer string }{{alice, bob}, {bob, alice}} {
		msgs := historyMessages(t, reader.who, reader.peer)
		if len(msgs) != 2 || msgs[0].ID != oops {
			t.Fatalf("history = %+v", msgs)
		}
		if msgs[0].Content != "" || msgs[0].DeletedAt == nil {
			t.Errorf("not a tombstone: %+v", msgs[0])
		}
		if msgs[1].Content != "first" || msgs[1].DeletedAt != nil {
			t.Errorf("an ordinary message changed: %+v", msgs[1])
		}
	}
}

func TestDeleteForEveryoneIsForTheSenderOnly(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob, eve := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "eve")
	id := sendMsg(t, alice, bob, "mine", time.Now().Add(-time.Minute))

	for name, who := range map[string]string{"the receiver": bob, "a stranger": eve} {
		if _, err := repo.DeleteForEveryone(ctx, who, id); !errors.Is(err, ErrNotYourMessage) {
			t.Errorf("%s: want ErrNotYourMessage, got %v", name, err)
		}
	}
	if got := historyOf(t, bob, alice); len(got) != 1 || got[0] != "mine" {
		t.Errorf("the message must be untouched, got %v", got)
	}
}

func TestDeleteForEveryoneWorksAtAnyAge(t *testing.T) {
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	id := sendMsg(t, alice, bob, "from long ago", time.Now().Add(-90*24*time.Hour))
	if _, err := NewMessageRepository().DeleteForEveryone(context.Background(), alice, id); err != nil {
		t.Errorf("a 90-day-old message: %v", err)
	}
}

func TestDeletingTwiceOrUnknownIsNotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	id := sendMsg(t, alice, bob, "x", time.Now().Add(-time.Minute))

	if _, err := repo.DeleteForEveryone(ctx, alice, id); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.DeleteForEveryone(ctx, alice, id); !errors.Is(err, ErrMessageNotFound) {
		t.Errorf("deleting again: want ErrMessageNotFound, got %v", err)
	}
	// Not the sender's to know it exists either, once it's gone.
	if _, err := repo.DeleteForEveryone(ctx, bob, id); !errors.Is(err, ErrMessageNotFound) {
		t.Errorf("someone else, after it's deleted: want ErrMessageNotFound, got %v", err)
	}
	if _, err := repo.DeleteForEveryone(ctx, alice, "00000000-0000-4000-8000-000000000000"); !errors.Is(err, ErrMessageNotFound) {
		t.Errorf("unknown message: want ErrMessageNotFound, got %v", err)
	}
}

func TestADeletedMessageShowsInTheInboxAsDeletedAndIsNotUnread(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	sendMsg(t, alice, bob, "hello", past)
	oops := sendMsg(t, alice, bob, "secret", past.Add(time.Minute))

	if c := conversationWith(t, bob, alice); c == nil || c.Unread != 2 || c.Last != "secret" {
		t.Fatalf("before: %+v", c)
	}

	if _, err := repo.DeleteForEveryone(ctx, alice, oops); err != nil {
		t.Fatal(err)
	}
	list, err := repo.GetConversations(ctx, bob)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, c := range list {
		if c.ID != alice {
			continue
		}
		found = true
		if c.LastMessage != "" || !c.LastMessageDeleted {
			t.Errorf("last message should be a deleted one with no text: %+v", c)
		}
		if c.UnreadCount != 1 {
			t.Errorf("unread = %d, want 1 (the deleted one doesn't count)", c.UnreadCount)
		}
	}
	if !found {
		t.Fatal("no conversation")
	}
}

func TestAReplyToADeletedMessageQuotesNothing(t *testing.T) {
	ctx := context.Background()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	original := sendMsg(t, alice, bob, "the original words", past)
	if _, err := config.DB.Exec(ctx,
		`INSERT INTO messages (sender_id, receiver_id, content, created_at, reply_to_message_id) VALUES ($1::uuid, $2::uuid, 'reply', $3, $4::uuid)`,
		bob, alice, past.Add(time.Minute), original); err != nil {
		t.Fatal(err)
	}
	if _, err := NewMessageRepository().DeleteForEveryone(ctx, alice, original); err != nil {
		t.Fatal(err)
	}

	msgs := historyMessages(t, bob, alice)
	reply := msgs[0]
	if reply.Content != "reply" || reply.QuotedMessage == nil {
		t.Fatalf("reply = %+v", reply)
	}
	if reply.QuotedMessage.Content != "" {
		t.Errorf("the quote still has the deleted text: %q", reply.QuotedMessage.Content)
	}
	if _, err := NewMessageRepository().GetMessagePreview(ctx, original); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("a deleted message has no preview, got %v", err)
	}
}

func TestHideForMeHidesItFromTheCallerOnly(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Hour)
	sendMsg(t, alice, bob, "keep", past)
	hideMe := sendMsg(t, alice, bob, "hide me", past.Add(time.Minute))

	if err := repo.HideForMe(ctx, bob, hideMe); err != nil {
		t.Fatal(err)
	}
	if got := historyOf(t, bob, alice); len(got) != 1 || got[0] != "keep" {
		t.Errorf("bob's history = %v", got)
	}
	if got := historyOf(t, alice, bob); len(got) != 2 {
		t.Errorf("alice must still see both, got %v", got)
	}

	// The chat list moves back to the message before it, and doesn't count it.
	if c := conversationWith(t, bob, alice); c == nil || c.Last != "keep" || c.Unread != 1 {
		t.Errorf("bob's chat list = %+v", c)
	}
	if c := conversationWith(t, alice, bob); c == nil || c.Last != "hide me" {
		t.Errorf("alice's chat list = %+v", c)
	}

	// Doing it again is fine.
	if err := repo.HideForMe(ctx, bob, hideMe); err != nil {
		t.Errorf("hiding twice: %v", err)
	}
}

func TestTheSenderCanHideTheirOwnMessageToo(t *testing.T) {
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	id := sendMsg(t, alice, bob, "mine", time.Now().Add(-time.Minute))
	if err := NewMessageRepository().HideForMe(context.Background(), alice, id); err != nil {
		t.Fatal(err)
	}
	if got := historyOf(t, alice, bob); len(got) != 0 {
		t.Errorf("alice's history = %v", got)
	}
	if got := historyOf(t, bob, alice); len(got) != 1 {
		t.Errorf("bob must still see it, got %v", got)
	}
}

func TestOnlyPeopleInAChatCanHideItsMessages(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob, eve := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "eve")
	id := sendMsg(t, alice, bob, "private", time.Now().Add(-time.Minute))

	if err := repo.HideForMe(ctx, eve, id); !errors.Is(err, ErrMessageNotFound) {
		t.Errorf("a stranger: want ErrMessageNotFound, got %v", err)
	}
	if err := repo.HideForMe(ctx, alice, "00000000-0000-4000-8000-000000000000"); !errors.Is(err, ErrMessageNotFound) {
		t.Errorf("unknown message: want ErrMessageNotFound, got %v", err)
	}
}

func TestGroupMessagesCanBeDeletedAndHidden(t *testing.T) {
	ctx := context.Background()
	alice, bob, eve := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "eve")
	groups := NewGroupRepository()
	group, err := groups.Create(ctx, "crew", alice)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = groups.Delete(context.Background(), group.ID) })
	if err := groups.AddMember(ctx, group.ID, bob); err != nil {
		t.Fatal(err)
	}
	var gm1, gm2 string
	past := time.Now().Add(-time.Hour)
	for i, dest := range []*string{&gm1, &gm2} {
		if err := config.DB.QueryRow(ctx,
			`INSERT INTO messages (sender_id, group_id, content, created_at) VALUES ($1::uuid, $2::uuid, $3, $4) RETURNING id::text`,
			alice, group.ID, []string{"one", "two"}[i], past.Add(time.Duration(i)*time.Minute)).Scan(dest); err != nil {
			t.Fatal(err)
		}
	}
	repo := NewMessageRepository()

	deleted, err := repo.DeleteForEveryone(ctx, alice, gm2)
	if err != nil {
		t.Fatal(err)
	}
	if deleted.GroupID != group.ID || deleted.ReceiverID != "" {
		t.Errorf("a group message should carry its group: %+v", deleted)
	}
	msgs, err := groups.GetGroupMessages(ctx, group.ID, bob, time.Now().Add(time.Hour), 100)
	if err != nil || len(msgs) != 2 || msgs[0].DeletedAt == nil || msgs[0].Content != "" {
		t.Fatalf("bob sees %+v (%v)", msgs, err)
	}

	if err := repo.HideForMe(ctx, bob, gm1); err != nil {
		t.Fatal(err)
	}
	if got := groupHistory(t, group.ID, bob); len(got) != 1 {
		t.Errorf("bob's group history = %v", got)
	}
	if got := groupHistory(t, group.ID, alice); len(got) != 2 {
		t.Errorf("alice's group history = %v", got)
	}
	if err := repo.HideForMe(ctx, eve, gm1); !errors.Is(err, ErrMessageNotFound) {
		t.Errorf("a non-member hiding a group message: want ErrMessageNotFound, got %v", err)
	}
}
