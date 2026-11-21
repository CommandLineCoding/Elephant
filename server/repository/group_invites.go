package repository

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5"
)

// InviteCodeLength is how many characters an invite code has: 32 characters of
// base64url, which is 192 bits of randomness.
const InviteCodeLength = 32

// newInviteCode makes a long random code. It is the only secret in a link.
func newInviteCode() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// Invite is a group's invite link.
type Invite struct {
	Code            string `json:"code"`
	RequireApproval bool   `json:"require_approval"`
}

// InvitePreview is what someone sees about a group before joining: its name and
// how many people are in it, and nothing about who they are.
type InvitePreview struct {
	GroupID          string `json:"group_id"`
	Name             string `json:"name"`
	MemberCount      int    `json:"member_count"`
	RequireApproval  bool   `json:"require_approval"`
	AlreadyMember    bool   `json:"already_member"`
	AlreadyRequested bool   `json:"already_requested"`
}

// JoinRequest is someone waiting to be let into a group.
type JoinRequest struct {
	UserID      string    `json:"user_id"`
	Username    string    `json:"username"`
	DisplayName string    `json:"display_name"`
	RequestedAt time.Time `json:"requested_at"`
}

// ErrNoInvite means the code isn't one (or was reset or turned off).
var ErrNoInvite = errors.New("no such invite")

type GroupInviteRepository struct{}

func NewGroupInviteRepository() *GroupInviteRepository { return &GroupInviteRepository{} }

// Get returns the group's invite, or nil if it has none.
func (r *GroupInviteRepository) Get(ctx context.Context, groupID string) (*Invite, error) {
	var inv Invite
	err := config.DB.QueryRow(ctx,
		`SELECT code, require_approval FROM group_invites WHERE group_id = $1::uuid;`, groupID).
		Scan(&inv.Code, &inv.RequireApproval)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &inv, nil
}

// Set creates the group's invite, or changes it. A new code is made if there
// is none or if reset is true; the old code stops working at once.
// requireApproval, if not nil, changes whether joining needs an admin.
func (r *GroupInviteRepository) Set(ctx context.Context, groupID, adminID string, requireApproval *bool, reset bool) (*Invite, error) {
	code, err := newInviteCode()
	if err != nil {
		return nil, err
	}
	var inv Invite
	err = config.DB.QueryRow(ctx, `
		INSERT INTO group_invites (group_id, code, require_approval, created_by)
		VALUES ($1::uuid, $2, COALESCE($3::boolean, FALSE), $4::uuid)
		ON CONFLICT (group_id) DO UPDATE SET
			code = CASE WHEN $5::boolean THEN EXCLUDED.code ELSE group_invites.code END,
			require_approval = COALESCE($3::boolean, group_invites.require_approval)
		RETURNING code, require_approval;
	`, groupID, code, requireApproval, adminID, reset).Scan(&inv.Code, &inv.RequireApproval)
	if err != nil {
		return nil, err
	}
	return &inv, nil
}

// Delete turns the group's invite off, and drops anyone waiting to be let in.
func (r *GroupInviteRepository) Delete(ctx context.Context, groupID string) error {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `DELETE FROM group_invites WHERE group_id = $1::uuid;`, groupID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM group_join_requests WHERE group_id = $1::uuid;`, groupID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Preview looks up a code and says what the person may see about the group.
func (r *GroupInviteRepository) Preview(ctx context.Context, code, userID string) (*InvitePreview, error) {
	var p InvitePreview
	err := config.DB.QueryRow(ctx, `
		SELECT g.id::text, g.name, i.require_approval,
		       (SELECT count(*) FROM group_members m WHERE m.group_id = g.id),
		       EXISTS (SELECT 1 FROM group_members m WHERE m.group_id = g.id AND m.user_id = $2::uuid),
		       EXISTS (SELECT 1 FROM group_join_requests q WHERE q.group_id = g.id AND q.user_id = $2::uuid)
		FROM group_invites i JOIN groups g ON g.id = i.group_id
		WHERE i.code = $1;
	`, code, userID).Scan(&p.GroupID, &p.Name, &p.RequireApproval, &p.MemberCount, &p.AlreadyMember, &p.AlreadyRequested)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNoInvite
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// Join uses a code. Without approval the person becomes a member; with it
// they are added to the waiting list. It returns "joined", "requested" or
// "already_member", and the group's ID.
func (r *GroupInviteRepository) Join(ctx context.Context, code, userID string) (status, groupID string, err error) {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return "", "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var approval bool
	err = tx.QueryRow(ctx, `SELECT group_id::text, require_approval FROM group_invites WHERE code = $1;`, code).Scan(&groupID, &approval)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", ErrNoInvite
	}
	if err != nil {
		return "", "", err
	}

	var member bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM group_members WHERE group_id = $1::uuid AND user_id = $2::uuid);`,
		groupID, userID).Scan(&member); err != nil {
		return "", "", err
	}
	if member {
		return "already_member", groupID, nil
	}

	if approval {
		if _, err := tx.Exec(ctx, `
			INSERT INTO group_join_requests (group_id, user_id) VALUES ($1::uuid, $2::uuid)
			ON CONFLICT DO NOTHING;`, groupID, userID); err != nil {
			return "", "", err
		}
		status = "requested"
	} else {
		if _, err := tx.Exec(ctx, `
			INSERT INTO group_members (group_id, user_id, role) VALUES ($1::uuid, $2::uuid, 'member')
			ON CONFLICT DO NOTHING;`, groupID, userID); err != nil {
			return "", "", err
		}
		status = "joined"
	}
	return status, groupID, tx.Commit(ctx)
}

// Requests lists who is waiting to be let into the group, oldest first.
func (r *GroupInviteRepository) Requests(ctx context.Context, groupID string) ([]JoinRequest, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT u.id::text, u.username, u.display_name, q.requested_at
		FROM group_join_requests q JOIN users u ON u.id = q.user_id
		WHERE q.group_id = $1::uuid
		ORDER BY q.requested_at;
	`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []JoinRequest{}
	for rows.Next() {
		var jr JoinRequest
		if err := rows.Scan(&jr.UserID, &jr.Username, &jr.DisplayName, &jr.RequestedAt); err != nil {
			return nil, err
		}
		out = append(out, jr)
	}
	return out, rows.Err()
}

// Decide settles a request: approve makes the person a member, otherwise the
// request is dropped. It reports whether there was a request.
func (r *GroupInviteRepository) Decide(ctx context.Context, groupID, userID string, approve bool) (bool, error) {
	tx, err := config.DB.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	tag, err := tx.Exec(ctx,
		`DELETE FROM group_join_requests WHERE group_id = $1::uuid AND user_id = $2::uuid;`, groupID, userID)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		return false, nil
	}
	if approve {
		if _, err := tx.Exec(ctx, `
			INSERT INTO group_members (group_id, user_id, role) VALUES ($1::uuid, $2::uuid, 'member')
			ON CONFLICT DO NOTHING;`, groupID, userID); err != nil {
			return false, err
		}
	}
	return true, tx.Commit(ctx)
}
