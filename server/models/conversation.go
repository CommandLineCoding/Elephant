package models

import "time"

type Conversation struct {
	ID              string    `json:"id"`
	Type            string    `json:"type"`
	Name            string    `json:"name"`
	DisplayName     string    `json:"display_name"`
	LastMessage     string    `json:"last_message"`
	LastMessageTime time.Time `json:"last_message_time"`
	SenderID        string    `json:"sender_id"`
	IsRead          bool      `json:"is_read"`
	UnreadCount     int       `json:"unread_count"`
	// LastMessageDeleted is true when the last message was deleted for
	// everyone: LastMessage is empty and the app says so.
	LastMessageDeleted bool `json:"last_message_deleted,omitempty"`
	// IsRequest is true for a direct chat the user hasn't accepted: a first
	// message from someone they haven't chatted with. See migration 030.
	IsRequest bool `json:"is_request"`
}
