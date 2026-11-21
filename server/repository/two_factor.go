package repository

import (
	"context"
	"errors"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5"
)

// Too many wrong codes lock code entry for a while.
const (
	TwoFactorMaxFailures = 5
	TwoFactorLockFor     = 15 * time.Minute
)

// TwoFactor is a person's two-step sign-in state.
type TwoFactor struct {
	SecretEnc    []byte
	Enabled      bool
	LastUsedStep int64
	LockedUntil  *time.Time
}

// Locked reports whether code entry is locked at now.
func (t *TwoFactor) Locked(now time.Time) bool {
	return t.LockedUntil != nil && t.LockedUntil.After(now)
}

type TwoFactorRepository struct{}

func NewTwoFactorRepository() *TwoFactorRepository { return &TwoFactorRepository{} }

// Get returns the person's state, or nil if they never started setting it up.
func (r *TwoFactorRepository) Get(ctx context.Context, userID string) (*TwoFactor, error) {
	var t TwoFactor
	err := config.DB.QueryRow(ctx, `
		SELECT secret_enc, enabled, last_used_step, locked_until
		FROM user_two_factor WHERE user_id = $1::uuid;
	`, userID).Scan(&t.SecretEnc, &t.Enabled, &t.LastUsedStep, &t.LockedUntil)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// Enabled reports whether two-step sign-in is on for the person.
func (r *TwoFactorRepository) Enabled(ctx context.Context, userID string) (bool, error) {
	var on bool
	err := config.DB.QueryRow(ctx,
		`SELECT COALESCE((SELECT enabled FROM user_two_factor WHERE user_id = $1::uuid), FALSE);`, userID).Scan(&on)
	return on, err
}

// StartSetup stores a new secret that isn't on yet, replacing an earlier one
// that was never confirmed. It does nothing and returns false if two-step
// sign-in is already on.
func (r *TwoFactorRepository) StartSetup(ctx context.Context, userID string, secretEnc []byte) (bool, error) {
	tag, err := config.DB.Exec(ctx, `
		INSERT INTO user_two_factor (user_id, secret_enc) VALUES ($1::uuid, $2)
		ON CONFLICT (user_id) DO UPDATE
			SET secret_enc = EXCLUDED.secret_enc, failed_attempts = 0, locked_until = NULL, last_used_step = 0
			WHERE user_two_factor.enabled = FALSE;
	`, userID, secretEnc)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// Enable turns two-step sign-in on after the first code was confirmed, and
// stores the hashes of the recovery codes that were handed out.
func (r *TwoFactorRepository) Enable(ctx context.Context, userID string, step int64, codeHashes []string) error {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `
		UPDATE user_two_factor SET enabled = TRUE, last_used_step = $2, failed_attempts = 0, locked_until = NULL
		WHERE user_id = $1::uuid;`, userID, step); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM two_factor_recovery_codes WHERE user_id = $1::uuid;`, userID); err != nil {
		return err
	}
	for _, h := range codeHashes {
		if _, err := tx.Exec(ctx,
			`INSERT INTO two_factor_recovery_codes (user_id, code_hash) VALUES ($1::uuid, $2);`, userID, h); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// Disable removes two-step sign-in and its recovery codes.
func (r *TwoFactorRepository) Disable(ctx context.Context, userID string) error {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `DELETE FROM two_factor_recovery_codes WHERE user_id = $1::uuid;`, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM user_two_factor WHERE user_id = $1::uuid;`, userID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// RecoveryCodesLeft is how many recovery codes have not been used.
func (r *TwoFactorRepository) RecoveryCodesLeft(ctx context.Context, userID string) (int, error) {
	var n int
	err := config.DB.QueryRow(ctx, `
		SELECT count(*) FROM two_factor_recovery_codes WHERE user_id = $1::uuid AND used_at IS NULL;`, userID).Scan(&n)
	return n, err
}

// UseRecoveryCode spends a recovery code. It reports whether the code was one
// that hadn't been used.
func (r *TwoFactorRepository) UseRecoveryCode(ctx context.Context, userID, codeHash string) (bool, error) {
	tag, err := config.DB.Exec(ctx, `
		UPDATE two_factor_recovery_codes SET used_at = NOW()
		WHERE user_id = $1::uuid AND code_hash = $2 AND used_at IS NULL;`, userID, codeHash)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// RecordSuccess notes the step of the code that was accepted, and clears the
// failures. step is 0 for a recovery code.
func (r *TwoFactorRepository) RecordSuccess(ctx context.Context, userID string, step int64) error {
	_, err := config.DB.Exec(ctx, `
		UPDATE user_two_factor
		SET failed_attempts = 0, locked_until = NULL, last_used_step = GREATEST(last_used_step, $2)
		WHERE user_id = $1::uuid;`, userID, step)
	return err
}

// RecordFailure counts a wrong code. After TwoFactorMaxFailures in a row,
// code entry is locked for TwoFactorLockFor. It returns whether it is locked.
func (r *TwoFactorRepository) RecordFailure(ctx context.Context, userID string, now time.Time) (bool, error) {
	var locked bool
	err := config.DB.QueryRow(ctx, `
		UPDATE user_two_factor SET
			failed_attempts = CASE WHEN failed_attempts + 1 >= $2 THEN 0 ELSE failed_attempts + 1 END,
			locked_until = CASE WHEN failed_attempts + 1 >= $2 THEN $3::timestamptz ELSE locked_until END
		WHERE user_id = $1::uuid
		RETURNING locked_until IS NOT NULL AND locked_until > $4::timestamptz;`,
		userID, TwoFactorMaxFailures, now.Add(TwoFactorLockFor), now).Scan(&locked)
	return locked, err
}

// PasswordHash is the person's stored password hash.
func (r *UserRepository) PasswordHash(ctx context.Context, userID string) (string, error) {
	var h string
	err := config.DB.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1::uuid;`, userID).Scan(&h)
	return h, err
}
