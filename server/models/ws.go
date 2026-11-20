package models

import "time"

type WSMessage struct {
	Type             string    `json:"type"`
	SenderID         string    `json:"sender_id,omitempty"`
	ReceiverID       string    `json:"receiver_id,omitempty"`
	GroupID          string    `json:"group_id,omitempty"`
	Content          string    `json:"content,omitempty"`
	MessageID        string    `json:"message_id,omitempty"`
	ReplyToMessageID string    `json:"reply_to_message_id,omitempty"`
	Timestamp        time.Time `json:"timestamp,omitempty"`
	CallID           string    `json:"call_id,omitempty"`
	Reason           string    `json:"reason,omitempty"`
	Silent           bool      `json:"silent,omitempty"` // an action carried in a chat message (migration 017)
}
