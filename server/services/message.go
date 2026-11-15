package services

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

// ErrDroppedForBlock is returned with a message that looks sent but was not
// stored or delivered, because the receiver blocked the sender. The caller
// should answer as if it was sent and must not send a push ping.
var ErrDroppedForBlock = errors.New("dropped: the receiver blocked the sender")

type MessageService struct {
	repo *repository.MessageRepository
}

func NewMessageService() *MessageService {
	return &MessageService{repo: repository.NewMessageRepository()}
}

func (s *MessageService) SendMessage(ctx context.Context, senderID, receiverID, content, replyToMessageID string) (*models.Message, error) {
	content = strings.TrimSpace(content)
	if content == "" {
		return nil, errors.New("message content cannot be empty")
	}
	if senderID == receiverID {
		return nil, errors.New("cannot send a message to yourself")
	}
	if IsBlockedBy(ctx, receiverID, senderID) {
		return &models.Message{
			ID:         newUUID(),
			SenderID:   senderID,
			ReceiverID: receiverID,
			Content:    content,
			CreatedAt:  time.Now(),
		}, ErrDroppedForBlock
	}
	return s.repo.CreateMessage(ctx, senderID, receiverID, content, replyToMessageID)
}

// newUUID returns a random (version 4) UUID.
func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
