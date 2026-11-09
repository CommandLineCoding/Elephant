package services

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
)

// hubClient registers a client with the hub. What the hub sends to that user
// arrives on its Send channel, so no socket is needed.
func hubClient(t *testing.T, userID string) *WSClient {
	t.Helper()
	startHub()
	c := NewWSClient(userID, nil)
	Hub.Register <- c
	flushHub()
	t.Cleanup(func() { Hub.Unregister <- c })
	return c
}

// received waits up to wait for an event of the given type on the client.
func received(c *WSClient, eventType string, wait time.Duration) (map[string]interface{}, bool) {
	timeout := time.After(wait)
	for {
		select {
		case b := <-c.Send:
			var m map[string]interface{}
			if json.Unmarshal(b, &m) == nil && m["type"] == eventType {
				return m, true
			}
		case <-timeout:
			return nil, false
		}
	}
}

func editedMessage(sender, receiver, group string) *models.Message {
	created := time.Now().Add(-time.Minute)
	edited := time.Now()
	return &models.Message{
		ID: "11111111-2222-3333-4444-555555555555", SenderID: sender, ReceiverID: receiver, GroupID: group,
		Content: "the new text", CreatedAt: created, EditedAt: &edited,
	}
}

func TestEditIsPushedToTheOtherPersonOnly(t *testing.T) {
	alice := hubClient(t, "edit-alice") // the editor
	bob := hubClient(t, "edit-bob")
	carol := hubClient(t, "edit-carol") // not in the conversation

	Hub.PublishMessageEdit(context.Background(), editedMessage("edit-alice", "edit-bob", ""))

	got, ok := received(bob, "message_edited", 3*time.Second)
	if !ok {
		t.Fatal("the other person was never told about the edit")
	}
	for key, want := range map[string]interface{}{
		"message_id":  "11111111-2222-3333-4444-555555555555",
		"sender_id":   "edit-alice",
		"receiver_id": "edit-bob",
		"content":     "the new text",
	} {
		if got[key] != want {
			t.Errorf("%s = %v, want %v", key, got[key], want)
		}
	}
	if _, has := got["group_id"]; has {
		t.Error("a direct edit must not carry a group_id")
	}
	if got["edited_at"] == nil || got["created_at"] == nil {
		t.Errorf("the event should carry the edit and creation times: %v", got)
	}

	if _, leaked := received(alice, "message_edited", 300*time.Millisecond); leaked {
		t.Error("the editor already has the change and must not be sent it")
	}
	if _, leaked := received(carol, "message_edited", 300*time.Millisecond); leaked {
		t.Error("someone outside the conversation must not see the edit")
	}
}

func TestEditInAGroupReachesTheOtherMembersOnly(t *testing.T) {
	old := groupMembers
	groupMembers = func(context.Context, string) ([]string, error) {
		return []string{"gedit-alice", "gedit-bob", "gedit-dave"}, nil // dave is offline
	}
	t.Cleanup(func() { groupMembers = old })

	alice := hubClient(t, "gedit-alice")
	bob := hubClient(t, "gedit-bob")
	outsider := hubClient(t, "gedit-outsider")

	Hub.PublishMessageEdit(context.Background(), editedMessage("gedit-alice", "", "group-1"))

	got, ok := received(bob, "message_edited", 3*time.Second)
	if !ok {
		t.Fatal("a group member was never told about the edit")
	}
	if got["group_id"] != "group-1" || got["sender_id"] != "gedit-alice" {
		t.Errorf("unexpected group edit event: %v", got)
	}
	if _, has := got["receiver_id"]; has {
		t.Error("a group edit must not carry a receiver_id")
	}
	if _, leaked := received(alice, "message_edited", 300*time.Millisecond); leaked {
		t.Error("the editor must not be sent their own edit")
	}
	if _, leaked := received(outsider, "message_edited", 300*time.Millisecond); leaked {
		t.Error("a non-member must not see the edit")
	}
}

func TestEditEventToleratesOfflineRecipientsAndLookupFailures(t *testing.T) {
	// nobody connected: nothing to deliver, and nothing should panic or block
	Hub.PublishMessageEdit(context.Background(), editedMessage("nobody-a", "nobody-b", ""))

	old := groupMembers
	groupMembers = func(context.Context, string) ([]string, error) { return nil, errors.New("database is down") }
	t.Cleanup(func() { groupMembers = old })

	bob := hubClient(t, "fail-bob")
	Hub.PublishMessageEdit(context.Background(), editedMessage("fail-alice", "", "group-1"))
	if _, leaked := received(bob, "message_edited", 300*time.Millisecond); leaked {
		t.Error("no event should go out if the group's members couldn't be loaded")
	}
}
