package models

import "time"

type QuotedMessage struct {
	ID       string `json:"id"`
	SenderID string `json:"sender_id"`
	Content  string `json:"content"`
}

type Message struct {
	ID               string         `json:"id"`
	SenderID         string         `json:"sender_id"`
	ReceiverID       string         `json:"receiver_id,omitempty"`
	GroupID          string         `json:"group_id,omitempty"`
	Content          string         `json:"content"`
	CreatedAt        time.Time      `json:"created_at"`
	IsRead           bool           `json:"is_read"`
	EditedAt         *time.Time     `json:"edited_at,omitempty"`
	DeletedAt        *time.Time     `json:"deleted_at,omitempty"`
	ReplyToMessageID *string        `json:"reply_to_message_id,omitempty"`
	QuotedMessage    *QuotedMessage `json:"quoted_message,omitempty"`
}
