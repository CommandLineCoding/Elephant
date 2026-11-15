package repository

import (
	"context"
	"errors"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrUnknownPeer is returned when a direct conversation names a user that
// doesn't exist.
var ErrUnknownPeer = errors.New("unknown user")

// clearDirectSQL records, or moves forward, the time a user cleared a direct
// conversation. Their history, conversation list and unread counts skip
// messages from before it.
const clearDirectSQL = `
	INSERT INTO conversation_clears (user_id, peer_id, cleared_at)
	VALUES ($1::uuid, $2::uuid, NOW())
	ON CONFLICT (user_id, peer_id) WHERE peer_id IS NOT NULL
	DO UPDATE SET cleared_at = EXCLUDED.cleared_at
	RETURNING cleared_at;
`

// ClearDirect is "delete for me" for a direct conversation. Only the caller's
// view changes; the other person keeps every message. It returns the time the
// conversation was cleared at.
func (r *MessageRepository) ClearDirect(ctx context.Context, userID, peerID string) (time.Time, error) {
	var clearedAt time.Time
	err := config.DB.QueryRow(ctx, clearDirectSQL, userID, peerID).Scan(&clearedAt)
	return clearedAt, foreignKeyAsUnknownPeer(err)
}

// DeleteOwnDirectMessages is "delete for everyone" for a direct conversation:
// it removes every message the caller sent to peerID, for both people, and
// clears the conversation for the caller. The peer's own messages are never
// deleted. It returns how many messages were removed and the clear time.
func (r *MessageRepository) DeleteOwnDirectMessages(ctx context.Context, userID, peerID string) (int64, time.Time, error) {
	tx, err := config.DB.Begin(ctx)
	if err != nil {
		return 0, time.Time{}, err
	}
	defer tx.Rollback(ctx)

	var clearedAt time.Time
	if err := tx.QueryRow(ctx, clearDirectSQL, userID, peerID).Scan(&clearedAt); err != nil {
		return 0, time.Time{}, foreignKeyAsUnknownPeer(err)
	}

	tag, err := tx.Exec(ctx, `
		DELETE FROM messages
		WHERE sender_id = $1::uuid AND receiver_id = $2::uuid AND group_id IS NULL;
	`, userID, peerID)
	if err != nil {
		return 0, time.Time{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, time.Time{}, err
	}
	return tag.RowsAffected(), clearedAt, nil
}

// ClearGroup is "delete for me" for a group chat: the caller stays a member
// but no longer sees the earlier messages.
func (r *GroupRepository) ClearGroup(ctx context.Context, userID, groupID string) (time.Time, error) {
	var clearedAt time.Time
	err := config.DB.QueryRow(ctx, `
		INSERT INTO conversation_clears (user_id, group_id, cleared_at)
		VALUES ($1::uuid, $2::uuid, NOW())
		ON CONFLICT (user_id, group_id) WHERE group_id IS NOT NULL
		DO UPDATE SET cleared_at = EXCLUDED.cleared_at
		RETURNING cleared_at;
	`, userID, groupID).Scan(&clearedAt)
	return clearedAt, err
}

// Delete removes a group with its members and messages.
func (r *GroupRepository) Delete(ctx context.Context, groupID string) error {
	_, err := config.DB.Exec(ctx, `DELETE FROM groups WHERE id = $1::uuid;`, groupID)
	return err
}

// foreignKeyAsUnknownPeer turns the foreign key error for a peer that doesn't
// exist into ErrUnknownPeer.
func foreignKeyAsUnknownPeer(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" {
		return ErrUnknownPeer
	}
	return err
}
