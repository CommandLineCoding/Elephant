package services

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/gorilla/websocket"
)

// WSClient is one live WebSocket connection. Create it with NewWSClient.
//
// Send is never closed. A client is shut down by Close, which closes done and
// the connection, so a send that races with shutdown can't panic.
type WSClient struct {
	UserID string
	Conn   *websocket.Conn
	Send   chan []byte

	done      chan struct{}
	closeOnce sync.Once
}

func NewWSClient(userID string, conn *websocket.Conn) *WSClient {
	return &WSClient{
		UserID: userID,
		Conn:   conn,
		Send:   make(chan []byte, 256),
		done:   make(chan struct{}),
	}
}

// Close shuts the client down. It is safe to call more than once and from any
// goroutine. ReadPump notices the closed connection and unregisters the client.
func (c *WSClient) Close() {
	c.closeOnce.Do(func() {
		close(c.done)
		if c.Conn != nil {
			_ = c.Conn.Close()
		}
	})
}

// trySend queues a message without blocking, and drops it if the client is
// closed or its buffer is full.
func (c *WSClient) trySend(b []byte) {
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.Send <- b:
	default:
	}
}

// enqueue queues a message without blocking. A client whose buffer is full is
// too slow to keep up, so it is disconnected and will reconnect and resync.
func (c *WSClient) enqueue(b []byte) {
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.Send <- b:
	default:
		c.Close()
	}
}

type WSHub struct {
	clients    map[string]*WSClient
	Register   chan *WSClient
	Unregister chan *WSClient
	mu         sync.RWMutex
}

var Hub = &WSHub{
	clients:    make(map[string]*WSClient),
	Register:   make(chan *WSClient),
	Unregister: make(chan *WSClient),
}

// clientFor returns the user's current connection, or nil if they're offline.
func (h *WSHub) clientFor(userID string) *WSClient {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.clients[strings.ToLower(userID)]
}

// sendToUser queues b for one user. It never blocks.
func (h *WSHub) sendToUser(userID string, b []byte) {
	if c := h.clientFor(userID); c != nil {
		c.enqueue(b)
	}
}

// sendToUsers queues b for every listed user except one. The recipients are
// collected under the lock and sent to after releasing it, and sending never
// blocks, so a slow client can't stall the hub.
func (h *WSHub) sendToUsers(userIDs []string, except string, b []byte) {
	h.mu.RLock()
	targets := make([]*WSClient, 0, len(userIDs))
	for _, id := range userIDs {
		if id == except {
			continue
		}
		if c, ok := h.clients[strings.ToLower(id)]; ok {
			targets = append(targets, c)
		}
	}
	h.mu.RUnlock()

	for _, c := range targets {
		c.enqueue(b)
	}
}

func (h *WSHub) broadcastStatus(userID string, online bool) {
	msg := map[string]interface{}{
		"type":    "user_status",
		"user_id": userID,
		"online":  online,
	}
	bytes, _ := json.Marshal(msg)

	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, client := range h.clients {
		if !strings.EqualFold(client.UserID, userID) {
			client.trySend(bytes)
		}
	}
}

func (h *WSHub) Run() {
	for {
		select {
		case client := <-h.Register:
			uid := strings.ToLower(client.UserID)

			h.mu.Lock()
			old := h.clients[uid]
			h.clients[uid] = client
			h.mu.Unlock()

			// A reconnect (e.g. a phone switching networks) can arrive before
			// the old connection has noticed it's dead. The new one wins.
			if old != nil && old != client {
				old.Close()
			} else {
				go h.broadcastStatus(client.UserID, true)
			}

		case client := <-h.Unregister:
			uid := strings.ToLower(client.UserID)

			// Only remove the entry if it still belongs to this connection.
			// Otherwise the cleanup of an old connection would remove the
			// user's newer one and they would stop receiving messages.
			h.mu.Lock()
			current := h.clients[uid] == client
			if current {
				delete(h.clients, uid)
			}
			h.mu.Unlock()

			client.Close()
			if current {
				go h.broadcastStatus(client.UserID, false)
			}
		}
	}
}

// Disconnect closes the user's live WebSocket, if any. ReadPump then
// unregisters the client as usual.
func (h *WSHub) Disconnect(userID string) {
	if c := h.clientFor(userID); c != nil {
		c.Close()
	}
}

func (c *WSClient) ReadPump() {
	defer func() {
		Hub.Unregister <- c
		c.Close()
	}()

	c.Conn.SetReadLimit(4096)
	_ = c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.Conn.SetPongHandler(func(string) error {
		_ = c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	msgRepo := repository.NewMessageRepository()

	for {
		_, bytes, err := c.Conn.ReadMessage()
		if err != nil {
			break
		}

		var incoming models.WSMessage
		if err := json.Unmarshal(bytes, &incoming); err != nil {
			continue
		}

		switch incoming.Type {
		case "request_status":
			online := Hub.clientFor(incoming.ReceiverID) != nil

			resp := map[string]interface{}{
				"type":    "user_status",
				"user_id": incoming.ReceiverID,
				"online":  online,
			}
			respBytes, _ := json.Marshal(resp)
			c.trySend(respBytes)

		case "typing":
			incoming.SenderID = c.UserID
			outboundBytes, _ := json.Marshal(incoming)

			if incoming.GroupID != "" {
				groupRepo := repository.NewGroupRepository()
				members, err := groupRepo.GetGroupMembers(context.Background(), incoming.GroupID)
				if err != nil {
					log.Printf("Failed to resolve group membership for typing indicator: %v", err)
					continue
				}
				Hub.sendToUsers(members, c.UserID, outboundBytes)
			} else {
				Hub.sendToUser(incoming.ReceiverID, outboundBytes)
			}

		case "read_receipt":
			incoming.SenderID = c.UserID
			incoming.Timestamp = time.Now()
			outboundBytes, _ := json.Marshal(incoming)

			if incoming.GroupID != "" {
				go func(groupID, userID string) {
					err := msgRepo.UpdateGroupLastRead(context.Background(), groupID, userID)
					if err != nil {
						log.Printf("Async group timestamp update failed over WebSocket: %v", err)
					}
				}(incoming.GroupID, c.UserID)

				groupRepo := repository.NewGroupRepository()
				members, err := groupRepo.GetGroupMembers(context.Background(), incoming.GroupID)
				if err == nil {
					Hub.sendToUsers(members, c.UserID, outboundBytes)
				}
			} else {
				go func(receiverID, senderID string) {
					err := msgRepo.MarkAsRead(context.Background(), receiverID, senderID)
					if err != nil {
						log.Printf("Failed to update read state flags over WS link: %v", err)
					}
				}(c.UserID, incoming.ReceiverID)

				Hub.sendToUser(incoming.ReceiverID, outboundBytes)
			}

		case "chat":
			incoming.SenderID = c.UserID
			incoming.Timestamp = time.Now()

			go func(msg models.WSMessage) {
				query := `
					INSERT INTO messages (sender_id, receiver_id, group_id, content, id, reply_to_message_id)
					VALUES (
						$1::uuid,
						NULLIF($2, '')::uuid,
						NULLIF($3, '')::uuid,
						$4,
						COALESCE(NULLIF($5, '')::uuid, gen_random_uuid()),
						NULLIF($6, '')::uuid
					);
				`
				_, err := config.DB.Exec(context.Background(), query, msg.SenderID, msg.ReceiverID, msg.GroupID, msg.Content, msg.MessageID, msg.ReplyToMessageID)
				if err != nil {
					log.Printf("Async group/direct write failure: %v", err)
				}
			}(incoming)

			var outboundBytes []byte
			if incoming.ReplyToMessageID != "" {
				if q, err := msgRepo.GetMessagePreview(context.Background(), incoming.ReplyToMessageID); err == nil {
					enriched := map[string]interface{}{
						"type":                incoming.Type,
						"sender_id":           incoming.SenderID,
						"receiver_id":         incoming.ReceiverID,
						"group_id":            incoming.GroupID,
						"content":             incoming.Content,
						"message_id":          incoming.MessageID,
						"reply_to_message_id": incoming.ReplyToMessageID,
						"timestamp":           incoming.Timestamp,
						"quoted_message":      q,
					}
					outboundBytes, _ = json.Marshal(enriched)
				} else {
					outboundBytes, _ = json.Marshal(incoming)
				}
			} else {
				outboundBytes, _ = json.Marshal(incoming)
			}

			if incoming.GroupID != "" {
				groupRepo := repository.NewGroupRepository()
				members, err := groupRepo.GetGroupMembers(context.Background(), incoming.GroupID)
				if err != nil {
					log.Printf("Failed to resolve channel membership routing: %v", err)
					continue
				}
				Hub.sendToUsers(members, c.UserID, outboundBytes)
			} else {
				Hub.sendToUser(incoming.ReceiverID, outboundBytes)
			}
		}
	}
}

func (c *WSClient) WritePump() {
	ticker := time.NewTicker(54 * time.Second)
	defer func() {
		ticker.Stop()
		c.Close()
	}()

	for {
		select {
		case <-c.done:
			return

		case message := <-c.Send:
			_ = c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))

			w, err := c.Conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			_, _ = w.Write(message)

			if err := w.Close(); err != nil {
				return
			}

		case <-ticker.C:
			_ = c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
