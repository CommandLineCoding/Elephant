package services

import (
	"testing"
	"time"
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
