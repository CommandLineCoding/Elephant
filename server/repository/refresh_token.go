package repository

import (
	"context"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5"
)

type RefreshTokenRepository struct{}

func NewRefreshTokenRepository() *RefreshTokenRepository {
	return &RefreshTokenRepository{}
}

// Session is one signed-in device: a refresh token that is rotated, with the
// same ID, each time it is used.
type Session struct {
	ID         string    `json:"id"`
	DeviceName string    `json:"device_name"`
	StartedAt  time.Time `json:"started_at"`
	LastUsedAt time.Time `json:"last_used_at"`
}

// StoreToken records a refresh token for a brand new session.
func (r *RefreshTokenRepository) StoreToken(ctx context.Context, userID, tokenHash string, expiresAt time.Time) error {
	return r.StoreSessionToken(ctx, userID, "", "", tokenHash, expiresAt)
}

// StoreSessionToken records the refresh token of a new session. sessionID is
// the ID the access token already carries; empty lets the database pick one.
func (r *RefreshTokenRepository) StoreSessionToken(ctx context.Context, userID, sessionID, deviceName, tokenHash string, expiresAt time.Time) error {
	query := `
		INSERT INTO refresh_tokens (user_id, token_hash, expires_at, session_id, device_name)
		VALUES ($1, $2, $3, COALESCE(NULLIF($4, '')::uuid, gen_random_uuid()), $5);
	`
	_, err := config.DB.Exec(ctx, query, userID, tokenHash, expiresAt, sessionID, deviceName)
	return err
}

func (r *RefreshTokenRepository) DeleteToken(ctx context.Context, tokenHash string) error {
	query := `DELETE FROM refresh_tokens WHERE token_hash = $1;`
	_, err := config.DB.Exec(ctx, query, tokenHash)
	return err
}

func (r *RefreshTokenRepository) GetValidTokenUser(ctx context.Context, tokenHash string) (string, error) {
	userID, _, err := r.GetValidToken(ctx, tokenHash)
	return userID, err
}

// GetValidToken returns the user and the session of a refresh token that has
// not expired or been signed out.
func (r *RefreshTokenRepository) GetValidToken(ctx context.Context, tokenHash string) (userID, sessionID string, err error) {
	query := `
		SELECT user_id::text, session_id::text FROM refresh_tokens
		WHERE token_hash = $1 AND expires_at > NOW();
	`
	err = config.DB.QueryRow(ctx, query, tokenHash).Scan(&userID, &sessionID)
	return userID, sessionID, err
}

// Rotate swaps a used refresh token for the next one in the same session,
// keeping when the session started and its device name (a non-empty
// deviceName replaces it). It does nothing and returns false if the old token
// is gone, for example because it was signed out a moment ago or used twice.
func (r *RefreshTokenRepository) Rotate(ctx context.Context, oldHash, newHash string, expiresAt time.Time, deviceName string) (bool, error) {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var userID, sessionID, oldName string
	var startedAt time.Time
	err = tx.QueryRow(ctx, `
		DELETE FROM refresh_tokens
		WHERE token_hash = $1 AND expires_at > NOW()
		RETURNING user_id::text, session_id::text, device_name, started_at;
	`, oldHash).Scan(&userID, &sessionID, &oldName, &startedAt)
	if err == pgx.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if deviceName == "" {
		deviceName = oldName
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO refresh_tokens (user_id, token_hash, expires_at, session_id, device_name, started_at, last_used_at)
		VALUES ($1::uuid, $2, $3, $4::uuid, $5, $6, NOW());
	`, userID, newHash, expiresAt, sessionID, deviceName, startedAt); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// ListSessions returns a user's signed-in devices, most recently used first.
func (r *RefreshTokenRepository) ListSessions(ctx context.Context, userID string) ([]Session, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT session_id::text, device_name, started_at, last_used_at
		FROM refresh_tokens
		WHERE user_id = $1::uuid AND expires_at > NOW()
		ORDER BY last_used_at DESC, started_at DESC;
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []Session{}
	for rows.Next() {
		var s Session
		if err := rows.Scan(&s.ID, &s.DeviceName, &s.StartedAt, &s.LastUsedAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// SessionActive reports whether a session still exists. A session that was
// signed out, or whose token ran out, is not active.
func (r *RefreshTokenRepository) SessionActive(ctx context.Context, userID, sessionID string) (bool, error) {
	var ok bool
	err := config.DB.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM refresh_tokens
			WHERE user_id = $1::uuid AND session_id = $2::uuid AND expires_at > NOW()
		);
	`, userID, sessionID).Scan(&ok)
	return ok, err
}

// DeleteSession signs one of a user's devices out. It reports whether there
// was such a session.
func (r *RefreshTokenRepository) DeleteSession(ctx context.Context, userID, sessionID string) (bool, error) {
	tag, err := config.DB.Exec(ctx,
		`DELETE FROM refresh_tokens WHERE user_id = $1::uuid AND session_id = $2::uuid;`, userID, sessionID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// DeleteOtherSessions signs out every device of the user except keepSessionID
// and returns the sessions it ended.
func (r *RefreshTokenRepository) DeleteOtherSessions(ctx context.Context, userID, keepSessionID string) ([]string, error) {
	rows, err := config.DB.Query(ctx, `
		DELETE FROM refresh_tokens
		WHERE user_id = $1::uuid AND session_id <> $2::uuid
		RETURNING session_id::text;
	`, userID, keepSessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ended []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ended = append(ended, id)
	}
	return ended, rows.Err()
}
