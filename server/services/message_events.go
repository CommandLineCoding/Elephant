package services

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

// groupMembers lists a group's members. It is a variable so tests can run the
// hub without a database.
var groupMembers = func(ctx context.Context, groupID string) ([]string, error) {
	return repository.NewGroupRepository().GetGroupMembers(ctx, groupID)
}

// PublishMessageEdit tells the other people in a conversation that a message
// was edited, so their open chat and inbox update without a reload. The sender
// already has the change, so isn't sent it. Anyone who is offline sees the
// edit when they next load the conversation, and an edit never triggers a push
// notification.
func (h *WSHub) PublishMessageEdit(ctx context.Context, msg *models.Message) {
	event := map[string]interface{}{
		"type":       "message_edited",
		"message_id": msg.ID,
		"sender_id":  msg.SenderID,
		"content":    msg.Content,
		"created_at": msg.CreatedAt,
		"edited_at":  msg.EditedAt,
	}

	if msg.GroupID == "" {
		if blockedBy(ctx, msg.ReceiverID, msg.SenderID) {
			return
		}
		event["receiver_id"] = msg.ReceiverID
		bytes, _ := json.Marshal(event)
		h.sendToUser(msg.ReceiverID, bytes)
		return
	}

	event["group_id"] = msg.GroupID
	bytes, _ := json.Marshal(event)
	members, err := groupMembers(ctx, msg.GroupID)
	if err != nil {
		log.Printf("Couldn't tell group members about an edit: %v", err)
		return
	}
	h.sendToUsers(members, msg.SenderID, bytes)
}

// PublishMessageDeleted tells the other people in a conversation that one
// message was deleted for everyone, so their open chat and chat list show
// "This message was deleted" without a reload. The deleter already has the
// change. Anyone offline sees it when they next load the conversation.
func (h *WSHub) PublishMessageDeleted(ctx context.Context, msg *models.Message) {
	event := map[string]interface{}{
		"type":       "message_deleted",
		"message_id": msg.ID,
		"sender_id":  msg.SenderID,
		"deleted_at": msg.DeletedAt,
	}

	if msg.GroupID == "" {
		if blockedBy(ctx, msg.ReceiverID, msg.SenderID) {
			return
		}
		event["receiver_id"] = msg.ReceiverID
		bytes, _ := json.Marshal(event)
		h.sendToUser(msg.ReceiverID, bytes)
		return
	}

	event["group_id"] = msg.GroupID
	bytes, _ := json.Marshal(event)
	members, err := groupMembers(ctx, msg.GroupID)
	if err != nil {
		log.Printf("Couldn't tell group members about a deleted message: %v", err)
		return
	}
	h.sendToUsers(members, msg.SenderID, bytes)
}

// PublishMessagesDeleted tells the other person in a direct conversation that
// senderID deleted every message they sent to them up to `before`, so their
// app can remove those messages. Anyone offline sees the change when they next
// load the conversation.
func (h *WSHub) PublishMessagesDeleted(senderID, receiverID string, before time.Time) {
	bytes, _ := json.Marshal(map[string]interface{}{
		"type":        "messages_deleted",
		"sender_id":   senderID,
		"receiver_id": receiverID,
		"before":      before,
	})
	h.sendToUser(receiverID, bytes)
}

// PublishGroupDeleted tells a deleted group's members, except the admin who
// deleted it, so their apps can remove the group.
func (h *WSHub) PublishGroupDeleted(groupID, deletedBy string, members []string) {
	bytes, _ := json.Marshal(map[string]interface{}{
		"type":       "group_deleted",
		"group_id":   groupID,
		"deleted_by": deletedBy,
	})
	h.sendToUsers(members, deletedBy, bytes)
}
