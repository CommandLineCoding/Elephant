package services

import (
	"context"
	"encoding/json"
	"log"

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
