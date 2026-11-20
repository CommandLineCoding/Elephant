package services

import (
	"context"
	"encoding/json"
	"log"
	"regexp"
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

// PublishDelivered tells each sender which of their messages reached
// receiverID's phone, so they can show the second tick. bySender maps a
// sender to their delivered message IDs.
func (h *WSHub) PublishDelivered(receiverID string, bySender map[string][]string, at time.Time) {
	for sender, ids := range bySender {
		bytes, _ := json.Marshal(map[string]interface{}{
			"type":         "message_delivered",
			"message_ids":  ids,
			"receiver_id":  receiverID,
			"delivered_at": at,
		})
		h.sendToUser(sender, bytes)
	}
}

// maxDeliveredIDs is how many messages one "delivered" event may report.
const maxDeliveredIDs = 100

var uuidShape = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// markDelivered stores that messages reached receiverID. A variable so tests
// can run without a database.
var markDelivered = func(ctx context.Context, receiverID string, ids []string) (map[string][]string, time.Time, error) {
	return repository.NewMessageRepository().MarkDelivered(ctx, receiverID, ids)
}

// ackDelivered handles a "delivered" event from receiverID's phone: it records
// the messages and tells their senders. Anything that isn't a message ID is
// ignored, and so is an event reporting far more than a phone could have
// received at once.
func ackDelivered(ctx context.Context, receiverID string, ids []string) {
	if len(ids) == 0 || len(ids) > maxDeliveredIDs {
		return
	}
	valid := make([]string, 0, len(ids))
	for _, id := range ids {
		if uuidShape.MatchString(id) {
			valid = append(valid, id)
		}
	}
	if len(valid) == 0 {
		return
	}
	bySender, at, err := markDelivered(ctx, receiverID, valid)
	if err != nil {
		log.Printf("Couldn't record delivered messages: %v", err)
		return
	}
	Hub.PublishDelivered(receiverID, bySender, at)
}
