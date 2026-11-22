package services

import (
	"context"
	"log"

	"github.com/commandlinecoding/elephant/server/repository"
)

// The lookups behind message requests, as variables so tests can run the hub
// without a database.
var (
	requestOpen = func(ctx context.Context, recipientID, senderID string) (bool, error) {
		return repository.NewRequestRepository().Open(ctx, recipientID, senderID)
	}
	requestPending = func(ctx context.Context, recipientID, senderID string) (bool, error) {
		return repository.NewRequestRepository().Pending(ctx, recipientID, senderID)
	}
	requestAccept = func(ctx context.Context, recipientID, senderID string) (bool, error) {
		return repository.NewRequestRepository().Accept(ctx, recipientID, senderID)
	}
)

// noteDirectMessage is called for a direct message before it is stored. A
// message from someone new starts a request for the recipient; answering a
// request accepts it. It reports whether the message is a request for the
// recipient. If that can't be told, the message is delivered as an ordinary
// one: nobody should lose a message over a failed lookup.
func noteDirectMessage(ctx context.Context, senderID, receiverID string) bool {
	answered, err := requestAccept(ctx, senderID, receiverID)
	if err != nil {
		log.Printf("Couldn't accept a request by replying: %v", err)
	}
	if answered {
		// A reply is part of a conversation that now exists, even if the
		// message that started it isn't stored yet.
		return false
	}
	isRequest, err := requestOpen(ctx, receiverID, senderID)
	if err != nil {
		log.Printf("Couldn't check for a message request, delivering anyway: %v", err)
		return false
	}
	return isRequest
}

// pendingRequestFrom reports whether sender's messages to recipient are a
// request the recipient hasn't accepted: nothing about the recipient
// (reading, typing, delivery) is shown to the sender until they accept. If it
// can't be checked, it says yes, so nothing leaks.
func pendingRequestFrom(ctx context.Context, recipientID, senderID string) bool {
	pending, err := requestPending(ctx, recipientID, senderID)
	if err != nil {
		log.Printf("Couldn't check for a message request, keeping receipts back: %v", err)
		return true
	}
	return pending
}

// PendingRequestFrom is pendingRequestFrom for the controllers.
func PendingRequestFrom(ctx context.Context, recipientID, senderID string) bool {
	return pendingRequestFrom(ctx, recipientID, senderID)
}

// maxAcceptedAcks is how many held-back messages are acknowledged as delivered
// when a request is accepted: the newest ones, which is all a chat shows ticks
// for.
const maxAcceptedAcks = 100

// AcceptRequest accepts the request from senderID to recipientID. The sender
// is then told the messages reached the recipient, which was held back until
// now.
func AcceptRequest(ctx context.Context, recipientID, senderID string) (bool, error) {
	accepted, err := requestAccept(ctx, recipientID, senderID)
	if err != nil || !accepted {
		return accepted, err
	}
	go acknowledgeAccepted(context.Background(), recipientID, senderID)
	return true, nil
}

func acknowledgeAccepted(ctx context.Context, recipientID, senderID string) {
	ids, err := repository.NewMessageRepository().UndeliveredFrom(ctx, recipientID, senderID, maxAcceptedAcks)
	if err != nil {
		log.Printf("Couldn't list the messages of an accepted request: %v", err)
		return
	}
	ackDelivered(ctx, recipientID, ids)
}
