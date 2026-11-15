package repository

import (
	"context"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

type BlockRepository struct{}

func NewBlockRepository() *BlockRepository {
	return &BlockRepository{}
}

// BlockedUser is one entry in a user's list of people they blocked.
type BlockedUser struct {
	ID          string    `json:"id"`
	Username    string    `json:"username"`
	DisplayName string    `json:"display_name"`
	BlockedAt   time.Time `json:"blocked_at"`
}

// Block records that userID blocked targetID. Blocking someone already
// blocked is not an error. It returns ErrUnknownPeer if targetID doesn't exist.
func (r *BlockRepository) Block(ctx context.Context, userID, targetID string) error {
	_, err := config.DB.Exec(ctx, `
		INSERT INTO blocked_users (user_id, blocked_user_id)
		VALUES ($1::uuid, $2::uuid)
		ON CONFLICT DO NOTHING;
	`, userID, targetID)
	return foreignKeyAsUnknownPeer(err)
}

// Unblock removes a block. Unblocking someone who isn't blocked is not an
// error.
func (r *BlockRepository) Unblock(ctx context.Context, userID, targetID string) error {
	_, err := config.DB.Exec(ctx,
		`DELETE FROM blocked_users WHERE user_id = $1::uuid AND blocked_user_id = $2::uuid;`,
		userID, targetID)
	return err
}

// ListBlocked returns the people userID has blocked, most recent first.
func (r *BlockRepository) ListBlocked(ctx context.Context, userID string) ([]BlockedUser, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT u.id::text, u.username, COALESCE(u.display_name, ''), b.created_at
		FROM blocked_users b
		JOIN users u ON u.id = b.blocked_user_id
		WHERE b.user_id = $1::uuid
		ORDER BY b.created_at DESC;
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	list := []BlockedUser{}
	for rows.Next() {
		var b BlockedUser
		if err := rows.Scan(&b.ID, &b.Username, &b.DisplayName, &b.BlockedAt); err != nil {
			return nil, err
		}
		list = append(list, b)
	}
	return list, rows.Err()
}

// IsBlocked reports whether blockerID has blocked senderID.
func (r *BlockRepository) IsBlocked(ctx context.Context, blockerID, senderID string) (bool, error) {
	var blocked bool
	err := config.DB.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM blocked_users
			WHERE user_id = $1::uuid AND blocked_user_id = $2::uuid
		);
	`, blockerID, senderID).Scan(&blocked)
	return blocked, err
}
