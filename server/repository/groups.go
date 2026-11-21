package repository

import (
	"context"
	"errors"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/jackc/pgx/v5"
)

type GroupRepository struct{}

func NewGroupRepository() *GroupRepository {
	return &GroupRepository{}
}

func (r *GroupRepository) Create(ctx context.Context, name, creatorID string) (*models.Group, error) {
	tx, err := config.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	var g models.Group
	query := `INSERT INTO groups (name, created_by) VALUES ($1, $2) RETURNING id, name, created_by, created_at, description, admins_only;`
	err = tx.QueryRow(ctx, query, name, creatorID).Scan(&g.ID, &g.Name, &g.CreatedBy, &g.CreatedAt, &g.Description, &g.AdminsOnly)
	if err != nil {
		return nil, err
	}

	memberQuery := `INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'admin');`
	_, err = tx.Exec(ctx, memberQuery, g.ID, creatorID)
	if err != nil {
		return nil, err
	}

	return &g, tx.Commit(ctx)
}

func (r *GroupRepository) ListByUser(ctx context.Context, userID string) ([]models.Group, error) {
	query := `
		SELECT g.id, g.name, g.created_by, g.created_at, g.description, g.admins_only
		FROM groups g
		JOIN group_members gm ON g.id = gm.group_id
		WHERE gm.user_id = $1
		ORDER BY g.created_at DESC;
	`
	rows, err := config.DB.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	groups := []models.Group{}
	for rows.Next() {
		var g models.Group
		if err := rows.Scan(&g.ID, &g.Name, &g.CreatedBy, &g.CreatedAt, &g.Description, &g.AdminsOnly); err != nil {
			return nil, err
		}
		groups = append(groups, g)
	}
	return groups, nil
}

func (r *GroupRepository) GetRole(ctx context.Context, groupID, userID string) (string, error) {
	query := `SELECT role FROM group_members WHERE group_id = $1 AND user_id = $2;`
	var role string
	err := config.DB.QueryRow(ctx, query, groupID, userID).Scan(&role)
	if err != nil {
		return "", err
	}
	return role, nil
}

func (r *GroupRepository) AddMember(ctx context.Context, groupID, userID string) error {
	query := `INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT DO NOTHING;`
	_, err := config.DB.Exec(ctx, query, groupID, userID)
	return err
}

func (r *GroupRepository) RemoveMember(ctx context.Context, groupID, userID string) error {
	query := `DELETE FROM group_members WHERE group_id = $1 AND user_id = $2;`
	_, err := config.DB.Exec(ctx, query, groupID, userID)
	return err
}

func (r *GroupRepository) GetGroupMembers(ctx context.Context, groupID string) ([]string, error) {
	query := `SELECT user_id FROM group_members WHERE group_id = $1;`
	rows, err := config.DB.Query(ctx, query, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var members []string
	for rows.Next() {
		var uid string
		if err := rows.Scan(&uid); err != nil {
			return nil, err
		}
		members = append(members, uid)
	}
	return members, nil
}

// GetGroupMessages returns a page of a group's messages, skipping any the
// reader cleared for themselves.
func (r *GroupRepository) GetGroupMessages(ctx context.Context, groupID, readerID string, before time.Time, limit int) ([]models.Message, error) {
	query := `
		SELECT 
			m.id, m.sender_id, m.content, m.created_at, m.edited_at, m.reply_to_message_id, m.deleted_at,
			q.sender_id AS quoted_sender_id, q.content AS quoted_content
		FROM messages m
		LEFT JOIN messages q ON m.reply_to_message_id = q.id
		WHERE m.group_id = $1::uuid AND m.created_at < $2
		  AND NOT EXISTS (SELECT 1 FROM message_hides h WHERE h.message_id = m.id AND h.user_id = $4::uuid)
		  AND m.created_at > COALESCE(
			(SELECT cleared_at FROM conversation_clears
			 WHERE user_id = $4::uuid AND group_id = $1::uuid),
			'-infinity')
		ORDER BY m.created_at DESC
		LIMIT $3;
	`
	rows, err := config.DB.Query(ctx, query, groupID, before, limit, readerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var history []models.Message = []models.Message{}
	for rows.Next() {
		var m models.Message
		var qSender, qContent *string

		err := rows.Scan(&m.ID, &m.SenderID, &m.Content, &m.CreatedAt, &m.EditedAt, &m.ReplyToMessageID, &m.DeletedAt, &qSender, &qContent)
		if err != nil {
			return nil, err
		}

		m.GroupID = groupID
		if m.ReplyToMessageID != nil && qSender != nil && qContent != nil {
			m.QuotedMessage = &models.QuotedMessage{
				ID:       *m.ReplyToMessageID,
				SenderID: *qSender,
				Content:  *qContent,
			}
		}
		history = append(history, m)
	}
	return history, nil
}

func (r *GroupRepository) GetMembersDetails(ctx context.Context, groupID string) ([]models.GroupMemberDetail, error) {
	query := `
		SELECT gm.user_id, u.username, COALESCE(u.display_name, '') AS display_name, gm.role, gm.joined_at
		FROM group_members gm
		JOIN users u ON gm.user_id = u.id
		WHERE gm.group_id = $1
		ORDER BY CASE WHEN gm.role = 'admin' THEN 1 ELSE 2 END, gm.joined_at ASC;
	`
	rows, err := config.DB.Query(ctx, query, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var members []models.GroupMemberDetail = []models.GroupMemberDetail{}
	for rows.Next() {
		var m models.GroupMemberDetail
		err := rows.Scan(&m.UserID, &m.Username, &m.DisplayName, &m.Role, &m.JoinedAt)
		if err != nil {
			return nil, err
		}
		members = append(members, m)
	}
	return members, nil
}

func (r *GroupRepository) GetByID(ctx context.Context, groupID string) (*models.Group, error) {
	query := `SELECT id, name, created_by, created_at, description, admins_only FROM groups WHERE id = $1;`
	var g models.Group
	err := config.DB.QueryRow(ctx, query, groupID).Scan(&g.ID, &g.Name, &g.CreatedBy, &g.CreatedAt, &g.Description, &g.AdminsOnly)
	if err != nil {
		return nil, err
	}
	return &g, nil
}

func (r *GroupRepository) UpdateName(ctx context.Context, groupID, newName string) error {
	query := `UPDATE groups SET name = $1 WHERE id = $2;`
	_, err := config.DB.Exec(ctx, query, newName, groupID)
	return err
}

// GroupChanges is a change to a group. Nil fields stay as they are.
type GroupChanges struct {
	Name        *string
	Description *string
	AdminsOnly  *bool
}

// Update applies changes to a group and returns it. The caller has checked
// the values.
func (r *GroupRepository) Update(ctx context.Context, groupID string, c GroupChanges) (*models.Group, error) {
	var g models.Group
	err := config.DB.QueryRow(ctx, `
		UPDATE groups SET
			name        = COALESCE($2::text, name),
			description = COALESCE($3::text, description),
			admins_only = COALESCE($4::boolean, admins_only)
		WHERE id = $1::uuid
		RETURNING id, name, created_by, created_at, description, admins_only;
	`, groupID, c.Name, c.Description, c.AdminsOnly).Scan(
		&g.ID, &g.Name, &g.CreatedBy, &g.CreatedAt, &g.Description, &g.AdminsOnly)
	if err != nil {
		return nil, err
	}
	return &g, nil
}

// MayPost says whether userID may send an ordinary message to the group:
// they must be a member, and if the group is admins-only, an admin.
// isMember is false for someone who isn't in the group at all.
func (r *GroupRepository) MayPost(ctx context.Context, groupID, userID string) (mayPost, isMember bool, err error) {
	var role string
	var adminsOnly bool
	err = config.DB.QueryRow(ctx, `
		SELECT gm.role, g.admins_only
		FROM group_members gm
		JOIN groups g ON g.id = gm.group_id
		WHERE gm.group_id = $1::uuid AND gm.user_id = $2::uuid;
	`, groupID, userID).Scan(&role, &adminsOnly)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	return !adminsOnly || role == "admin", true, nil
}
