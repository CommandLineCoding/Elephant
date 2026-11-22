package repository

import (
	"context"
	"errors"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5"
)

// StatusLife is how long a status lasts.
const StatusLife = 24 * time.Hour

type StatusRepository struct{}

func NewStatusRepository() *StatusRepository { return &StatusRepository{} }

// StatusCopy is a status as encrypted for one recipient.
type StatusCopy struct {
	RecipientID string `json:"recipient_id"`
	Content     string `json:"content"`
}

// PostedStatus is a status someone posted.
type PostedStatus struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

// Create stores a status with one copy for each recipient, in one go.
func (r *StatusRepository) Create(ctx context.Context, authorID string, copies []StatusCopy) (PostedStatus, error) {
	tx, err := config.DB.Begin(ctx)
	if err != nil {
		return PostedStatus{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var s PostedStatus
	err = tx.QueryRow(ctx, `
		INSERT INTO statuses (author_id, expires_at)
		VALUES ($1::uuid, NOW() + make_interval(secs => $2))
		RETURNING id::text, created_at, expires_at`,
		authorID, StatusLife.Seconds()).Scan(&s.ID, &s.CreatedAt, &s.ExpiresAt)
	if err != nil {
		return PostedStatus{}, err
	}
	for _, c := range copies {
		if _, err := tx.Exec(ctx, `
			INSERT INTO status_copies (status_id, recipient_id, content)
			VALUES ($1::uuid, $2::uuid, $3)`, s.ID, c.RecipientID, c.Content); err != nil {
			return PostedStatus{}, err
		}
	}
	return s, tx.Commit(ctx)
}

// CountSince returns how many statuses authorID has posted since t.
func (r *StatusRepository) CountSince(ctx context.Context, authorID string, t time.Time) (int, error) {
	var n int
	err := config.DB.QueryRow(ctx,
		`SELECT count(*) FROM statuses WHERE author_id = $1::uuid AND created_at > $2`,
		authorID, t).Scan(&n)
	return n, err
}

// ReceivedStatus is a status as the recipient sees it.
type ReceivedStatus struct {
	ID        string    `json:"id"`
	AuthorID  string    `json:"author_id"`
	Content   string    `json:"content"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
	Viewed    bool      `json:"viewed"`
}

// ListFor returns the statuses posted for userID that haven't run out, newest
// first. Statuses of someone the user blocked, or who blocked the user, are
// left out even if they were posted before the block.
func (r *StatusRepository) ListFor(ctx context.Context, userID string, limit int) ([]ReceivedStatus, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT s.id::text, s.author_id::text, c.content, s.created_at, s.expires_at, c.viewed_at IS NOT NULL
		FROM status_copies c
		JOIN statuses s ON s.id = c.status_id
		WHERE c.recipient_id = $1::uuid
		  AND s.expires_at > NOW()
		  AND NOT EXISTS (
			SELECT 1 FROM blocked_users b
			WHERE (b.user_id = $1::uuid AND b.blocked_user_id = s.author_id)
			   OR (b.user_id = s.author_id AND b.blocked_user_id = $1::uuid)
		  )
		ORDER BY s.created_at DESC
		LIMIT $2`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReceivedStatus{}
	for rows.Next() {
		var s ReceivedStatus
		if err := rows.Scan(&s.ID, &s.AuthorID, &s.Content, &s.CreatedAt, &s.ExpiresAt, &s.Viewed); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// Viewer is someone who saw a status.
type Viewer struct {
	UserID   string    `json:"user_id"`
	ViewedAt time.Time `json:"viewed_at"`
}

// OwnStatus is a status as its author sees it.
type OwnStatus struct {
	ID         string    `json:"id"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	Recipients int       `json:"recipients"`
	Viewers    []Viewer  `json:"viewers"`
}

// ListOwn returns authorID's statuses that haven't run out, newest first, with
// who has seen them. A person who turned read receipts off is never listed as
// having seen it.
func (r *StatusRepository) ListOwn(ctx context.Context, authorID string) ([]OwnStatus, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT s.id::text, s.created_at, s.expires_at,
		       (SELECT count(*) FROM status_copies c WHERE c.status_id = s.id)
		FROM statuses s
		WHERE s.author_id = $1::uuid AND s.expires_at > NOW()
		ORDER BY s.created_at DESC`, authorID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OwnStatus
	index := map[string]int{}
	for rows.Next() {
		var s OwnStatus
		if err := rows.Scan(&s.ID, &s.CreatedAt, &s.ExpiresAt, &s.Recipients); err != nil {
			return nil, err
		}
		s.Viewers = []Viewer{}
		index[s.ID] = len(out)
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if len(out) == 0 {
		return []OwnStatus{}, nil
	}

	seen, err := config.DB.Query(ctx, `
		SELECT c.status_id::text, c.recipient_id::text, c.viewed_at
		FROM status_copies c
		JOIN statuses s ON s.id = c.status_id
		LEFT JOIN user_settings us ON us.user_id = c.recipient_id
		WHERE s.author_id = $1::uuid AND s.expires_at > NOW()
		  AND c.viewed_at IS NOT NULL
		  AND COALESCE(us.read_receipts, TRUE)
		ORDER BY c.viewed_at`, authorID)
	if err != nil {
		return nil, err
	}
	defer seen.Close()
	for seen.Next() {
		var id, who string
		var at time.Time
		if err := seen.Scan(&id, &who, &at); err != nil {
			return nil, err
		}
		if i, ok := index[id]; ok {
			out[i].Viewers = append(out[i].Viewers, Viewer{UserID: who, ViewedAt: at})
		}
	}
	return out, seen.Err()
}

// Delete removes one of authorID's statuses, for everyone. It reports whether
// there was one.
func (r *StatusRepository) Delete(ctx context.Context, authorID, statusID string) (bool, error) {
	tag, err := config.DB.Exec(ctx,
		`DELETE FROM statuses WHERE id = $1::uuid AND author_id = $2::uuid`, statusID, authorID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// MarkViewed records that userID saw a status. It returns the author, whether
// this was the first time, and whether the user has that status at all (it
// may be missing, expired, or someone else's).
func (r *StatusRepository) MarkViewed(ctx context.Context, userID, statusID string) (authorID string, first bool, found bool, err error) {
	err = config.DB.QueryRow(ctx, `
		WITH target AS (
			SELECT s.author_id, c.viewed_at IS NULL AS first
			FROM status_copies c JOIN statuses s ON s.id = c.status_id
			WHERE c.status_id = $1::uuid AND c.recipient_id = $2::uuid AND s.expires_at > NOW()
		), mark AS (
			UPDATE status_copies SET viewed_at = NOW()
			WHERE status_id = $1::uuid AND recipient_id = $2::uuid AND viewed_at IS NULL
			  AND EXISTS (SELECT 1 FROM target)
		)
		SELECT author_id::text, first FROM target`, statusID, userID).Scan(&authorID, &first)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, false, nil
	}
	if err != nil {
		return "", false, false, err
	}
	return authorID, first, true, nil
}

// DeleteExpiredStatuses removes statuses that have run out, with their copies.
func (r *CleanupRepository) DeleteExpiredStatuses(ctx context.Context, limit int) (int64, error) {
	tag, err := config.DB.Exec(ctx, `
		DELETE FROM statuses
		WHERE id IN (SELECT id FROM statuses WHERE expires_at < NOW() LIMIT $1);
	`, limit)
	return tag.RowsAffected(), err
}
