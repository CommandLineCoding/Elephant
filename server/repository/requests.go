package repository

import (
	"context"

	"github.com/commandlinecoding/elephant/server/config"
)

type RequestRepository struct{}

func NewRequestRepository() *RequestRepository {
	return &RequestRepository{}
}

// Pending reports whether sender's messages to recipient are a request the
// recipient hasn't accepted.
func (r *RequestRepository) Pending(ctx context.Context, recipientID, senderID string) (bool, error) {
	var pending bool
	err := config.DB.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM message_requests
			WHERE recipient_id = $1::uuid AND sender_id = $2::uuid
		)`, recipientID, senderID).Scan(&pending)
	return pending, err
}

// Open is called for a direct message from sender to recipient, before the
// message is stored. If the two have never exchanged a direct message and share
// no group, it starts a request. It reports whether the message is part of a
// pending request.
func (r *RequestRepository) Open(ctx context.Context, recipientID, senderID string) (bool, error) {
	if _, err := config.DB.Exec(ctx, `
		INSERT INTO message_requests (recipient_id, sender_id)
		SELECT $1::uuid, $2::uuid
		WHERE NOT EXISTS (
			SELECT 1 FROM messages
			WHERE group_id IS NULL
			  AND ((sender_id = $1::uuid AND receiver_id = $2::uuid)
			    OR (sender_id = $2::uuid AND receiver_id = $1::uuid))
		)
		AND NOT EXISTS (
			SELECT 1 FROM group_members a
			JOIN group_members b ON b.group_id = a.group_id
			WHERE a.user_id = $1::uuid AND b.user_id = $2::uuid
		)
		ON CONFLICT DO NOTHING`, recipientID, senderID); err != nil {
		return false, err
	}
	return r.Pending(ctx, recipientID, senderID)
}

// Accept ends the request from sender to recipient, so it is a conversation
// like any other. It reports whether there was one.
func (r *RequestRepository) Accept(ctx context.Context, recipientID, senderID string) (bool, error) {
	tag, err := config.DB.Exec(ctx, `
		DELETE FROM message_requests
		WHERE recipient_id = $1::uuid AND sender_id = $2::uuid`, recipientID, senderID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}
