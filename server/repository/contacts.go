package repository

import (
	"context"

	"github.com/commandlinecoding/elephant/server/config"
)

type ContactRepository struct{}

func NewContactRepository() *ContactRepository {
	return &ContactRepository{}
}

// GetContactIDs returns everyone the user shares a conversation with: people
// they have exchanged a direct message with, in either direction, and people
// who are in a group with them. These are the only people who may see the
// user's online status.
func (r *ContactRepository) GetContactIDs(ctx context.Context, userID string) ([]string, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT other::text FROM (
			SELECT receiver_id AS other FROM messages
			WHERE sender_id = $1::uuid AND receiver_id IS NOT NULL
			UNION
			SELECT sender_id FROM messages WHERE receiver_id = $1::uuid
			UNION
			SELECT gm2.user_id FROM group_members gm1
			JOIN group_members gm2 ON gm2.group_id = gm1.group_id
			WHERE gm1.user_id = $1::uuid
		) contacts
		WHERE other <> $1::uuid;
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
