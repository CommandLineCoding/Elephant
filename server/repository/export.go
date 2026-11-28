package repository

import (
	"context"
	"errors"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/jackc/pgx/v5"
)

type ExportRepository struct{}

func NewExportRepository() *ExportRepository { return &ExportRepository{} }

// Export gathers what the server keeps about userID, read in one snapshot so
// the parts agree with each other, with the first page of messages. It
// returns pgx.ErrNoRows if there is no such user. What is left out, and why,
// is on models.AccountExport.
func (r *ExportRepository) Export(ctx context.Context, userID string, now time.Time, messages models.ExportMessageQuery) (*models.AccountExport, error) {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	out := &models.AccountExport{App: "elephant", Format: models.ExportFormat, ExportedAt: now.UTC()}

	a := &out.Account
	err = tx.QueryRow(ctx, `
		SELECT id::text, username, display_name, email, google_id, github_id, created_at,
		       username_changed_at, bio, status_emoji, status_text, status_expires_at
		FROM users WHERE id = $1::uuid;
	`, userID).Scan(&a.ID, &a.Username, &a.DisplayName, &a.Email, &a.GoogleID, &a.GithubID, &a.CreatedAt,
		&a.UsernameChangedAt, &a.Bio, &a.StatusEmoji, &a.StatusText, &a.StatusExpiresAt)
	if err != nil {
		return nil, err
	}

	d := DefaultUserSettings()
	out.Settings = models.ExportSettings{OnlineStatus: d.OnlineStatus, ReadReceipts: d.ReadReceipts, GroupAdds: d.GroupAdds}
	err = tx.QueryRow(ctx, `
		SELECT online_status, read_receipts, group_adds FROM user_settings WHERE user_id = $1::uuid;
	`, userID).Scan(&out.Settings.OnlineStatus, &out.Settings.ReadReceipts, &out.Settings.GroupAdds)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	// A two-step setup that was started but never finished is not "on".
	err = tx.QueryRow(ctx, `
		SELECT t.enabled, t.created_at,
		       (SELECT count(*) FROM two_factor_recovery_codes c WHERE c.user_id = t.user_id AND c.used_at IS NULL)
		FROM user_two_factor t WHERE t.user_id = $1::uuid;
	`, userID).Scan(&out.TwoFactor.Enabled, &out.TwoFactor.CreatedAt, &out.TwoFactor.RecoveryCodesLeft)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	if out.Sessions, err = exportRows(ctx, tx, `
		SELECT session_id::text, device_name, started_at, last_used_at, expires_at
		FROM refresh_tokens WHERE user_id = $1::uuid ORDER BY started_at;
	`, userID, func(rows pgx.Rows, s *models.ExportSession) error {
		return rows.Scan(&s.ID, &s.DeviceName, &s.StartedAt, &s.LastUsedAt, &s.ExpiresAt)
	}); err != nil {
		return nil, err
	}

	if out.Devices, err = exportRows(ctx, tx, `
		SELECT d.device_id, d.identity_key, d.signed_prekey, d.signed_prekey_signature,
		       (SELECT count(*) FROM one_time_prekeys k WHERE k.user_id = d.user_id AND k.device_id = d.device_id),
		       d.updated_at
		FROM user_devices d WHERE d.user_id = $1::uuid ORDER BY d.device_id;
	`, userID, func(rows pgx.Rows, k *models.ExportDevice) error {
		return rows.Scan(&k.DeviceID, &k.IdentityKey, &k.SignedPrekey, &k.SignedPrekeySignature, &k.OneTimePrekeys, &k.UpdatedAt)
	}); err != nil {
		return nil, err
	}

	if out.Push, err = exportRows(ctx, tx, `
		SELECT created_at, updated_at, failures FROM push_endpoints WHERE user_id = $1::uuid ORDER BY created_at;
	`, userID, func(rows pgx.Rows, p *models.ExportPush) error {
		return rows.Scan(&p.CreatedAt, &p.UpdatedAt, &p.Failures)
	}); err != nil {
		return nil, err
	}

	// Only the person's own choices: who blocked them, or is waiting on a
	// request they sent, is the other person's business.
	if out.Blocked, err = exportRows(ctx, tx, `
		SELECT blocked_user_id::text, created_at FROM blocked_users WHERE user_id = $1::uuid ORDER BY created_at;
	`, userID, func(rows pgx.Rows, b *models.ExportBlock) error {
		return rows.Scan(&b.UserID, &b.BlockedAt)
	}); err != nil {
		return nil, err
	}

	if out.Verifications, err = exportRows(ctx, tx, `
		SELECT verified_user_id::text, is_verified, updated_at
		FROM user_verifications WHERE user_id = $1::uuid ORDER BY updated_at;
	`, userID, func(rows pgx.Rows, v *models.ExportVerification) error {
		return rows.Scan(&v.UserID, &v.IsVerified, &v.UpdatedAt)
	}); err != nil {
		return nil, err
	}

	if out.Requests, err = exportRows(ctx, tx, `
		SELECT sender_id::text, created_at FROM message_requests WHERE recipient_id = $1::uuid ORDER BY created_at;
	`, userID, func(rows pgx.Rows, q *models.ExportRequest) error {
		return rows.Scan(&q.SenderID, &q.CreatedAt)
	}); err != nil {
		return nil, err
	}

	if out.Groups, err = exportRows(ctx, tx, `
		SELECT g.id::text, g.name, g.description, g.admins_only, g.created_by::text, g.created_at,
		       gm.role, gm.joined_at, gm.last_read_at
		FROM group_members gm JOIN groups g ON g.id = gm.group_id
		WHERE gm.user_id = $1::uuid ORDER BY gm.joined_at;
	`, userID, func(rows pgx.Rows, g *models.ExportGroup) error {
		return rows.Scan(&g.ID, &g.Name, &g.Description, &g.AdminsOnly, &g.CreatedBy, &g.CreatedAt,
			&g.Role, &g.JoinedAt, &g.LastReadAt)
	}); err != nil {
		return nil, err
	}

	if out.JoinRequests, err = exportRows(ctx, tx, `
		SELECT group_id::text, requested_at FROM group_join_requests WHERE user_id = $1::uuid ORDER BY requested_at;
	`, userID, func(rows pgx.Rows, j *models.ExportJoinRequest) error {
		return rows.Scan(&j.GroupID, &j.RequestedAt)
	}); err != nil {
		return nil, err
	}

	// Messages are the one part that grows without end, so only the first
	// page is here. Which ones the person deleted for themselves is on each
	// message, so that grows with the page too.
	if out.Messages, out.MessagesNext, err = exportMessages(ctx, tx, userID, messages); err != nil {
		return nil, err
	}
	out.MessagesTruncated = out.MessagesNext != nil

	// At most one row per chat, however many messages it has.
	if out.Cleared, err = exportRows(ctx, tx, `
		SELECT peer_id::text, group_id::text, cleared_at FROM conversation_clears WHERE user_id = $1::uuid ORDER BY cleared_at;
	`, userID, func(rows pgx.Rows, c *models.ExportCleared) error {
		return rows.Scan(&c.PeerID, &c.GroupID, &c.ClearedAt)
	}); err != nil {
		return nil, err
	}

	// Who has seen a status is left out: a viewer who turned read receipts
	// off isn't shown to the author anywhere else either.
	if out.Statuses, err = exportRows(ctx, tx, `
		SELECT s.id::text, s.created_at, s.expires_at,
		       (SELECT count(*) FROM status_copies c WHERE c.status_id = s.id)
		FROM statuses s WHERE s.author_id = $1::uuid ORDER BY s.created_at;
	`, userID, func(rows pgx.Rows, s *models.ExportStatus) error {
		return rows.Scan(&s.ID, &s.CreatedAt, &s.ExpiresAt, &s.Recipients)
	}); err != nil {
		return nil, err
	}

	// The same statuses the person can see in the app: one that ran out is
	// gone for them, and one from someone either of them blocked would give
	// the block away.
	if out.ReceivedStatuses, err = exportRows(ctx, tx, `
		SELECT s.id::text, s.author_id::text, c.content, s.created_at, s.expires_at, c.viewed_at
		FROM status_copies c JOIN statuses s ON s.id = c.status_id
		WHERE `+statusVisibleTo+`
		ORDER BY s.created_at;
	`, userID, func(rows pgx.Rows, s *models.ExportReceivedStatus) error {
		return rows.Scan(&s.ID, &s.AuthorID, &s.Content, &s.CreatedAt, &s.ExpiresAt, &s.ViewedAt)
	}); err != nil {
		return nil, err
	}

	// Reports the person sent. Reports about them would say who reported
	// them, so they stay with the admin.
	if out.Reports, err = exportRows(ctx, tx, `
		SELECT id, reported_user_id::text, reason, note, messages, created_at
		FROM reports WHERE reporter_id = $1::uuid ORDER BY created_at;
	`, userID, func(rows pgx.Rows, p *models.ExportReport) error {
		return rows.Scan(&p.ID, &p.ReportedUserID, &p.Reason, &p.Note, &p.Messages, &p.CreatedAt)
	}); err != nil {
		return nil, err
	}

	return out, nil
}

// ExportMessages returns one page of userID's messages, for the pages after
// the first one in Export.
func (r *ExportRepository) ExportMessages(ctx context.Context, userID string, q models.ExportMessageQuery) (*models.ExportMessagePage, error) {
	page := &models.ExportMessagePage{}
	var err error
	if page.Messages, page.Next, err = exportMessages(ctx, config.DB, userID, q); err != nil {
		return nil, err
	}
	return page, nil
}

// querier is what exportMessages needs, so it runs in Export's snapshot or
// on its own.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// exportMessages returns up to q.Limit of userID's messages after q.After,
// oldest first, and the cursor for the next page (nil if there is none).
// What the person said in groups is always in it: other people's group
// messages are theirs. Direct messages, both ways, only with
// q.DirectMessages. A message that has run out is already gone for everyone
// and only waits for the cleanup job. Whether a sent message was read
// follows the recipient's read receipts setting, as in the chat history.
//
// The page goes on from the last (created_at, id) instead of skipping rows,
// so each one costs the same however deep it is and none is skipped or
// repeated when messages come or go in between.
func exportMessages(ctx context.Context, db querier, userID string, q models.ExportMessageQuery) ([]models.ExportMessage, *string, error) {
	whose := `m.group_id IS NOT NULL AND m.sender_id = $1::uuid`
	if q.DirectMessages {
		whose = `(m.sender_id = $1::uuid OR m.receiver_id = $1::uuid)`
	}
	// One more than the page, to know whether there is a next one.
	args := []any{userID, q.Limit + 1}
	after := ``
	if q.After != nil {
		after = `AND (m.created_at, m.id) > ($3::timestamptz, $4::uuid)`
		args = append(args, q.After.CreatedAt, q.After.ID)
	}

	rows, err := db.Query(ctx, `
		SELECT m.id::text, m.sender_id::text, m.receiver_id::text, m.group_id::text, m.content, m.created_at,
		       (m.is_read AND (m.sender_id <> $1::uuid OR m.receiver_id IS NULL OR
		        COALESCE((SELECT us.read_receipts FROM user_settings us WHERE us.user_id = m.receiver_id), TRUE))),
		       m.delivered_at, m.edited_at, m.deleted_at, m.expires_at, m.reply_to_message_id::text, m.silent,
		       EXISTS (SELECT 1 FROM message_hides h WHERE h.message_id = m.id AND h.user_id = $1::uuid)
		FROM messages m
		WHERE `+whose+`
		  AND (m.expires_at IS NULL OR m.expires_at > NOW())
		  `+after+`
		ORDER BY m.created_at, m.id
		LIMIT $2;
	`, args...)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	out := []models.ExportMessage{}
	for rows.Next() {
		var m models.ExportMessage
		if err := rows.Scan(&m.ID, &m.SenderID, &m.ReceiverID, &m.GroupID, &m.Content, &m.CreatedAt,
			&m.IsRead, &m.DeliveredAt, &m.EditedAt, &m.DeletedAt, &m.ExpiresAt, &m.ReplyToMessageID, &m.Silent,
			&m.Hidden); err != nil {
			return nil, nil, err
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	if len(out) <= q.Limit {
		return out, nil, nil
	}
	out = out[:q.Limit]
	last := out[len(out)-1]
	next := models.ExportCursor{CreatedAt: last.CreatedAt, ID: last.ID}.String()
	return out, &next, nil
}

// exportRows runs query with userID and scans each row with scan. It returns
// an empty list, not nil, when there are no rows, so the JSON has [] for it.
func exportRows[T any](ctx context.Context, tx pgx.Tx, query, userID string, scan func(pgx.Rows, *T) error) ([]T, error) {
	rows, err := tx.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []T{}
	for rows.Next() {
		var v T
		if err := scan(rows, &v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}
