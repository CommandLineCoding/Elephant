package services

import (
	"context"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
)

func TestDeleteForEveryoneIsPushedToTheOtherPersonOnly(t *testing.T) {
	alice := hubClient(t, "del-alice") // deleted her messages
	bob := hubClient(t, "del-bob")
	carol := hubClient(t, "del-carol") // not in the conversation

	before := time.Now().UTC().Truncate(time.Millisecond)
	Hub.PublishMessagesDeleted("del-alice", "del-bob", before)

	got, ok := received(bob, "messages_deleted", 3*time.Second)
	if !ok {
		t.Fatal("the other person was never told about the deletion")
	}
	if got["sender_id"] != "del-alice" || got["receiver_id"] != "del-bob" {
		t.Errorf("wrong people in the event: %v", got)
	}
	if at, err := time.Parse(time.RFC3339Nano, got["before"].(string)); err != nil || !at.Equal(before) {
		t.Errorf("before = %v (%v), want %v", got["before"], err, before)
	}
	if _, ok := received(alice, "messages_deleted", 200*time.Millisecond); ok {
		t.Error("the person who deleted shouldn't be sent the event")
	}
	if _, ok := received(carol, "messages_deleted", 200*time.Millisecond); ok {
		t.Error("someone outside the conversation was told about it")
	}
}

func TestGroupDeletionIsPushedToTheOtherMembers(t *testing.T) {
	admin := hubClient(t, "gdel-admin")
	member := hubClient(t, "gdel-member")
	outsider := hubClient(t, "gdel-outsider")

	Hub.PublishGroupDeleted("group-1", "gdel-admin", []string{"gdel-admin", "gdel-member"})

	got, ok := received(member, "group_deleted", 3*time.Second)
	if !ok {
		t.Fatal("a member was never told the group was deleted")
	}
	if got["group_id"] != "group-1" || got["deleted_by"] != "gdel-admin" {
		t.Errorf("unexpected event: %v", got)
	}
	if _, ok := received(admin, "group_deleted", 200*time.Millisecond); ok {
		t.Error("the admin who deleted the group shouldn't be sent the event")
	}
	if _, ok := received(outsider, "group_deleted", 200*time.Millisecond); ok {
		t.Error("someone outside the group was told about it")
	}
}

func TestAMessageDeletedForEveryoneIsPushedToTheOtherPerson(t *testing.T) {
	alice := hubClient(t, "dm-alice")
	bob := hubClient(t, "dm-bob")
	carol := hubClient(t, "dm-carol")

	at := time.Now().UTC().Truncate(time.Millisecond)
	Hub.PublishMessageDeleted(context.Background(), &models.Message{
		ID: "msg-1", SenderID: "dm-alice", ReceiverID: "dm-bob", DeletedAt: &at,
	})

	got, ok := received(bob, "message_deleted", 3*time.Second)
	if !ok {
		t.Fatal("the other person was never told")
	}
	if got["message_id"] != "msg-1" || got["sender_id"] != "dm-alice" || got["receiver_id"] != "dm-bob" {
		t.Errorf("event = %v", got)
	}
	if _, has := got["content"]; has {
		t.Errorf("the event mustn't carry any content: %v", got)
	}
	if when, err := time.Parse(time.RFC3339Nano, got["deleted_at"].(string)); err != nil || !when.Equal(at) {
		t.Errorf("deleted_at = %v (%v), want %v", got["deleted_at"], err, at)
	}
	if _, ok := received(alice, "message_deleted", 200*time.Millisecond); ok {
		t.Error("the person who deleted shouldn't be sent the event")
	}
	if _, ok := received(carol, "message_deleted", 200*time.Millisecond); ok {
		t.Error("someone outside the chat was told")
	}
}

func TestAGroupMessageDeletedForEveryoneGoesToTheOtherMembers(t *testing.T) {
	setGroupMembers(t, []string{"gm-alice", "gm-bob"})
	alice := hubClient(t, "gm-alice")
	bob := hubClient(t, "gm-bob")
	outsider := hubClient(t, "gm-outsider")

	at := time.Now()
	Hub.PublishMessageDeleted(context.Background(), &models.Message{
		ID: "msg-2", SenderID: "gm-alice", GroupID: "g1", DeletedAt: &at,
	})

	got, ok := received(bob, "message_deleted", 3*time.Second)
	if !ok || got["group_id"] != "g1" || got["message_id"] != "msg-2" {
		t.Fatalf("member got %v (%v)", got, ok)
	}
	if _, ok := received(alice, "message_deleted", 200*time.Millisecond); ok {
		t.Error("the deleter was sent their own event")
	}
	if _, ok := received(outsider, "message_deleted", 200*time.Millisecond); ok {
		t.Error("a non-member was told")
	}
}

func TestADeletionIsNotPushedToSomeoneWhoBlockedTheSender(t *testing.T) {
	setBlocks(t, [2]string{"bl-bob", "bl-alice"}) // bob blocked alice
	bob := hubClient(t, "bl-bob")
	at := time.Now()
	Hub.PublishMessageDeleted(context.Background(), &models.Message{
		ID: "msg-3", SenderID: "bl-alice", ReceiverID: "bl-bob", DeletedAt: &at,
	})
	if _, ok := received(bob, "message_deleted", 300*time.Millisecond); ok {
		t.Error("a blocked sender's deletion reached the person who blocked them")
	}
}

// setGroupMembers makes every group have exactly these members for one test.
func setGroupMembers(t *testing.T, members []string) {
	t.Helper()
	old := groupMembers
	groupMembers = func(context.Context, string) ([]string, error) { return members, nil }
	t.Cleanup(func() { groupMembers = old })
}
