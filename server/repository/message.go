package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/jackc/pgx/v5"
)

type MessageRepository struct{}

func NewMessageRepository() *MessageRepository {
	return &MessageRepository{}
}

func (r *MessageRepository) CreateMessage(ctx context.Context, senderID, receiverID, content, replyToID string) (*models.Message, error) {
	query := `
		INSERT INTO messages (sender_id, receiver_id, content, reply_to_message_id)
		VALUES ($1, $2, $3, NULLIF($4, '')::uuid)
		RETURNING id, sender_id, receiver_id, content, reply_to_message_id, created_at;
	`
	var msg models.Message
	err := config.DB.QueryRow(ctx, query, senderID, receiverID, content, replyToID).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.Content,
		&msg.ReplyToMessageID,
		&msg.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &msg, nil
}

func (r *MessageRepository) GetChatHistory(ctx context.Context, userA, userB string, before time.Time, limit int) ([]models.Message, error) {
	query := `
		SELECT 
			m.id, m.sender_id, m.receiver_id, m.content, m.created_at, m.is_read, m.edited_at, m.reply_to_message_id,
			q.sender_id AS quoted_sender_id, q.content AS quoted_content
		FROM messages m
		LEFT JOIN messages q ON m.reply_to_message_id = q.id
		WHERE ((m.sender_id = $1 AND m.receiver_id = $2) OR (m.sender_id = $2 AND m.receiver_id = $1))
		  AND m.group_id IS NULL AND m.created_at < $3
		  AND m.created_at > COALESCE(
			(SELECT cleared_at FROM conversation_clears WHERE user_id = $1 AND peer_id = $2),
			'-infinity')
		ORDER BY m.created_at DESC
		LIMIT $4;
	`
	rows, err := config.DB.Query(ctx, query, userA, userB, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var history []models.Message = []models.Message{}
	for rows.Next() {
		var m models.Message
		var qSender, qContent *string

		err := rows.Scan(&m.ID, &m.SenderID, &m.ReceiverID, &m.Content, &m.CreatedAt, &m.IsRead, &m.EditedAt, &m.ReplyToMessageID, &qSender, &qContent)
		if err != nil {
			return nil, err
		}

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

func (r *MessageRepository) GetMessagePreview(ctx context.Context, messageID string) (*models.QuotedMessage, error) {
	query := `SELECT id, sender_id, content FROM messages WHERE id = $1::uuid;`
	var q models.QuotedMessage
	err := config.DB.QueryRow(ctx, query, messageID).Scan(&q.ID, &q.SenderID, &q.Content)
	if err != nil {
		return nil, err
	}
	return &q, nil
}

func (r *MessageRepository) GetConversations(ctx context.Context, userID string) ([]models.Conversation, error) {
	query := `
		WITH raw_conversations AS (
			(SELECT DISTINCT ON (CASE WHEN sender_id = $1::uuid THEN receiver_id ELSE sender_id END)
				CASE WHEN sender_id = $1::uuid THEN receiver_id ELSE sender_id END AS chat_user_id,
				'direct' AS type,
				content,
				sender_id,
				created_at,
				is_read,
				NULL::UUID AS group_id
			FROM messages
			WHERE (sender_id = $1::uuid OR receiver_id = $1::uuid) AND group_id IS NULL
			  AND NOT silent
			  AND created_at > COALESCE(
				(SELECT cleared_at FROM conversation_clears cc
				 WHERE cc.user_id = $1::uuid
				   AND cc.peer_id = CASE WHEN sender_id = $1::uuid THEN receiver_id ELSE sender_id END),
				'-infinity')
			ORDER BY CASE WHEN sender_id = $1::uuid THEN receiver_id ELSE sender_id END, created_at DESC)

			UNION ALL

			(SELECT DISTINCT ON (m.group_id)
				NULL::UUID AS chat_user_id,
				'group' AS type,
				m.content,
				m.sender_id,
				m.created_at,
				FALSE AS is_read,
				m.group_id
			FROM messages m
			JOIN group_members gm ON m.group_id = gm.group_id
			WHERE gm.user_id = $1::uuid
			  AND NOT m.silent
			  AND m.created_at > COALESCE(
				(SELECT cleared_at FROM conversation_clears cc
				 WHERE cc.user_id = $1::uuid AND cc.group_id = m.group_id),
				'-infinity')
			ORDER BY m.group_id, m.created_at DESC)
		),
		dm_unread AS (
			SELECT sender_id, COUNT(*) AS count
			FROM messages
			WHERE receiver_id = $1::uuid AND is_read = FALSE AND group_id IS NULL
			  AND NOT silent
			  AND created_at > COALESCE(
				(SELECT cleared_at FROM conversation_clears cc
				 WHERE cc.user_id = $1::uuid AND cc.peer_id = sender_id),
				'-infinity')
			GROUP BY sender_id
		),
		group_unread AS (
			SELECT m.group_id, COUNT(*) AS count
			FROM messages m
			JOIN group_members gm ON m.group_id = gm.group_id
			WHERE gm.user_id = $1::uuid AND m.created_at > gm.last_read_at AND m.sender_id != $1::uuid
			  AND NOT m.silent
			  AND m.created_at > COALESCE(
				(SELECT cleared_at FROM conversation_clears cc
				 WHERE cc.user_id = $1::uuid AND cc.group_id = m.group_id),
				'-infinity')
			GROUP BY m.group_id
		)
		SELECT 
			COALESCE(rc.chat_user_id::TEXT, rc.group_id::TEXT, '') AS id,
			COALESCE(rc.type, 'direct') AS type,
			COALESCE(u.username, g.name, 'Unknown Channel') AS name,
			COALESCE(u.display_name, '') AS display_name,
			COALESCE(rc.content, '') AS last_message,
			COALESCE(rc.created_at, NOW()) AS last_message_time,
			COALESCE(rc.sender_id::TEXT, '') AS sender_id,
			COALESCE(
				CASE 
					WHEN rc.type = 'direct' THEN rc.is_read
					ELSE (rc.created_at <= gm2.last_read_at)
				END, 
				FALSE
			) AS is_read,
			CASE 
				WHEN rc.type = 'direct' THEN COALESCE(du.count, 0)::INT
				ELSE COALESCE(gu.count, 0)::INT
			END AS unread_count
		FROM raw_conversations rc
		LEFT JOIN users u ON rc.chat_user_id = u.id
		LEFT JOIN groups g ON rc.group_id = g.id
		LEFT JOIN dm_unread du ON rc.chat_user_id = du.sender_id
		LEFT JOIN group_unread gu ON rc.group_id = gu.group_id
		LEFT JOIN group_members gm2 ON gm2.group_id = rc.group_id AND gm2.user_id = $1::uuid
		ORDER BY last_message_time DESC;
	`

	rows, err := config.DB.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []models.Conversation = []models.Conversation{}
	for rows.Next() {
		var c models.Conversation
		err := rows.Scan(
			&c.ID,
			&c.Type,
			&c.Name,
			&c.DisplayName,
			&c.LastMessage,
			&c.LastMessageTime,
			&c.SenderID,
			&c.IsRead,
			&c.UnreadCount,
		)
		if err != nil {
			return nil, err
		}
		list = append(list, c)
	}
	return list, nil
}

func (r *MessageRepository) MarkAsRead(ctx context.Context, receiverID, senderID string) error {
	query := `
		UPDATE messages
		SET is_read = TRUE
		WHERE receiver_id = $1 AND sender_id = $2 AND is_read = FALSE;
	`
	_, err := config.DB.Exec(ctx, query, receiverID, senderID)
	return err
}

func (r *MessageRepository) UpdateGroupLastRead(ctx context.Context, groupID, userID string) error {
	query := `
		UPDATE group_members 
		SET last_read_at = CURRENT_TIMESTAMP 
		WHERE group_id = $1 AND user_id = $2;
	`
	_, err := config.DB.Exec(ctx, query, groupID, userID)
	return err
}

func (r *MessageRepository) GetMessageByID(ctx context.Context, id string) (*models.Message, error) {
	query := `
		SELECT id, sender_id, COALESCE(receiver_id::text, '') as receiver_id, COALESCE(group_id::text, '') as group_id, 
		       content, created_at, edited_at, reply_to_message_id
		FROM messages 
		WHERE id = $1::uuid;
	`
	var msg models.Message
	err := config.DB.QueryRow(ctx, query, id).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.GroupID,
		&msg.Content,
		&msg.CreatedAt,
		&msg.EditedAt,
		&msg.ReplyToMessageID,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		return nil, fmt.Errorf("db error: %w", err)
	}
	return &msg, nil
}

func (r *MessageRepository) UpdateMessage(ctx context.Context, id, content string) (*models.Message, error) {
	query := `
		UPDATE messages 
		SET content = $1, edited_at = NOW() 
		WHERE id = $2::uuid 
		RETURNING id, sender_id, COALESCE(receiver_id::text, '') as receiver_id, COALESCE(group_id::text, '') as group_id, 
		          content, created_at, edited_at, reply_to_message_id;
	`
	var msg models.Message
	err := config.DB.QueryRow(ctx, query, content, id).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.GroupID,
		&msg.Content,
		&msg.CreatedAt,
		&msg.EditedAt,
		&msg.ReplyToMessageID,
	)
	if err != nil {
		return nil, err
	}
	return &msg, nil
}
