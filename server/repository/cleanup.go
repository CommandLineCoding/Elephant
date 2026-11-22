package repository

import (
	"context"

	"github.com/commandlinecoding/elephant/server/config"
)

// CleanupRepository deletes data that is no longer needed. Every method works
// in batches of at most limit rows, so a big backlog never holds a long lock,
// and returns how many rows it deleted. A caller that gets a full batch back
// should call again.
type CleanupRepository struct{}

func NewCleanupRepository() *CleanupRepository { return &CleanupRepository{} }

// DeleteExpiredRefreshTokens removes sign-in tokens that have run out. They
// can't be used any more, so nobody notices them going.
func (r *CleanupRepository) DeleteExpiredRefreshTokens(ctx context.Context, limit int) (int64, error) {
	tag, err := config.DB.Exec(ctx, `
		DELETE FROM refresh_tokens
		WHERE id IN (
			SELECT id FROM refresh_tokens WHERE expires_at < NOW() LIMIT $1
		);
	`, limit)
	return tag.RowsAffected(), err
}

// DeleteFailingPushEndpoints removes endpoints whose last minFailures pings
// all failed. The app registers its endpoint again on its next start, so a
// phone that was only offline for a while comes back by itself.
func (r *CleanupRepository) DeleteFailingPushEndpoints(ctx context.Context, minFailures, limit int) (int64, error) {
	tag, err := config.DB.Exec(ctx, `
		DELETE FROM push_endpoints
		WHERE id IN (
			SELECT id FROM push_endpoints WHERE failures >= $1 LIMIT $2
		);
	`, minFailures, limit)
	return tag.RowsAffected(), err
}

// DeleteExpiredMessages removes disappearing messages whose time has come.
func (r *CleanupRepository) DeleteExpiredMessages(ctx context.Context, limit int) (int64, error) {
	tag, err := config.DB.Exec(ctx, `
		DELETE FROM messages
		WHERE id IN (
			SELECT id FROM messages WHERE expires_at IS NOT NULL AND expires_at < NOW() LIMIT $1
		);
	`, limit)
	return tag.RowsAffected(), err
}
