package repository

import (
	"context"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5"
)

type PushRepository struct{}

func NewPushRepository() *PushRepository {
	return &PushRepository{}
}

// PushTarget is one stored endpoint.
type PushTarget struct {
	ID       int64
	UserID   string
	Endpoint string
}

// Upsert stores an endpoint for a user, or refreshes it if it is already
// stored. A user keeps at most maxPerUser endpoints; the least recently
// refreshed ones are dropped, so reinstalling the app can't lock anyone out.
func (r *PushRepository) Upsert(ctx context.Context, userID, endpoint string, maxPerUser int) error {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `
		INSERT INTO push_endpoints (user_id, endpoint)
		VALUES ($1, $2)
		ON CONFLICT (user_id, endpoint) DO UPDATE SET updated_at = NOW();
	`, userID, endpoint); err != nil {
		return err
	}

	if _, err := tx.Exec(ctx, `
		DELETE FROM push_endpoints
		WHERE user_id = $1
		  AND id NOT IN (
			SELECT id FROM push_endpoints
			WHERE user_id = $1
			ORDER BY updated_at DESC, id DESC
			LIMIT $2
		  );
	`, userID, maxPerUser); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Delete removes one of a user's endpoints. It reports whether one was removed.
func (r *PushRepository) Delete(ctx context.Context, userID, endpoint string) (bool, error) {
	tag, err := config.DB.Exec(ctx,
		`DELETE FROM push_endpoints WHERE user_id = $1 AND endpoint = $2;`, userID, endpoint)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// DeleteByID removes an endpoint the push service found to be gone.
func (r *PushRepository) DeleteByID(ctx context.Context, id int64) error {
	_, err := config.DB.Exec(ctx, `DELETE FROM push_endpoints WHERE id = $1;`, id)
	return err
}

// ListByUser returns every endpoint stored for a user.
func (r *PushRepository) ListByUser(ctx context.Context, userID string) ([]PushTarget, error) {
	rows, err := config.DB.Query(ctx,
		`SELECT id, user_id::text, endpoint FROM push_endpoints WHERE user_id = $1::uuid ORDER BY id;`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []PushTarget
	for rows.Next() {
		var t PushTarget
		if err := rows.Scan(&t.ID, &t.UserID, &t.Endpoint); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
