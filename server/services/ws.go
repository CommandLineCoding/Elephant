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

type WSClient struct {
	UserID string
	Conn   *websocket.Conn
	Send   chan []byte
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

func (h *WSHub) broadcastStatus(userID string, online bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	msg := map[string]interface{}{
		"type":    "user_status",
		"user_id": userID,
		"online":  online,
	}
	bytes, _ := json.Marshal(msg)

	for _, client := range h.clients {
		if !strings.EqualFold(client.UserID, userID) {
			select {
			case client.Send <- bytes:
			default:
			}
		}
	}
}

func (h *WSHub) Run() {
	for {
		select {
		case client := <-h.Register:
			h.mu.Lock()
			h.clients[strings.ToLower(client.UserID)] = client
			h.mu.Unlock()
			go h.broadcastStatus(client.UserID, true)

		case client := <-h.Unregister:
			h.mu.Lock()
			lowerUID := strings.ToLower(client.UserID)
			if _, exists := h.clients[lowerUID]; exists {
				delete(h.clients, lowerUID)
				close(client.Send)
				go h.broadcastStatus(client.UserID, false)
			}
			h.mu.Unlock()
		}
	}
}

// Disconnect closes the user's live WebSocket, if any. ReadPump then
// unregisters the client as usual.
func (h *WSHub) Disconnect(userID string) {
	h.mu.RLock()
	client, ok := h.clients[strings.ToLower(userID)]
	h.mu.RUnlock()
	if ok {
		_ = client.Conn.Close()
	}
}

func (c *WSClient) ReadPump() {
	defer func() {
		Hub.Unregister <- c
		c.Conn.Close()
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
			Hub.mu.RLock()
			_, online := Hub.clients[strings.ToLower(incoming.ReceiverID)]
			Hub.mu.RUnlock()

			resp := map[string]interface{}{
				"type":    "user_status",
				"user_id": incoming.ReceiverID,
				"online":  online,
			}
			respBytes, _ := json.Marshal(resp)
			select {
			case c.Send <- respBytes:
			default:
			}

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

				Hub.mu.RLock()
				for _, memberID := range members {
					if memberID == c.UserID {
						continue
					}
					if targetClient, online := Hub.clients[strings.ToLower(memberID)]; online {
						select {
						case targetClient.Send <- outboundBytes:
						default:
							Hub.Unregister <- targetClient
							targetClient.Conn.Close()
						}
					}
				}
				Hub.mu.RUnlock()

			} else {
				Hub.mu.RLock()
				targetClient, online := Hub.clients[strings.ToLower(incoming.ReceiverID)]
				Hub.mu.RUnlock()

				if online {
					select {
					case targetClient.Send <- outboundBytes:
					default:
						Hub.Unregister <- targetClient
						targetClient.Conn.Close()
					}
				}
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
					Hub.mu.RLock()
					for _, memberID := range members {
						if memberID == c.UserID {
							continue
						}
						if targetClient, online := Hub.clients[strings.ToLower(memberID)]; online {
							select {
							case targetClient.Send <- outboundBytes:
							default:
								Hub.Unregister <- targetClient
								targetClient.Conn.Close()
							}
						}
					}
					Hub.mu.RUnlock()
				}
			} else {
				go func(receiverID, senderID string) {
					err := msgRepo.MarkAsRead(context.Background(), receiverID, senderID)
					if err != nil {
						log.Printf("Failed to update read state flags over WS link: %v", err)
					}
				}(c.UserID, incoming.ReceiverID)

				Hub.mu.RLock()
				targetClient, online := Hub.clients[strings.ToLower(incoming.ReceiverID)]
				Hub.mu.RUnlock()

				if online {
					select {
					case targetClient.Send <- outboundBytes:
					default:
						Hub.Unregister <- targetClient
						targetClient.Conn.Close()
					}
				}
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

				Hub.mu.RLock()
				for _, memberID := range members {
					if memberID == c.UserID {
						continue
					}
					if targetClient, online := Hub.clients[strings.ToLower(memberID)]; online {
						select {
						case targetClient.Send <- outboundBytes:
						default:
							Hub.Unregister <- targetClient
							targetClient.Conn.Close()
						}
					}
				}
				Hub.mu.RUnlock()
			} else {
				Hub.mu.RLock()
				targetClient, online := Hub.clients[strings.ToLower(incoming.ReceiverID)]
				Hub.mu.RUnlock()

				if online {
					select {
					case targetClient.Send <- outboundBytes:
					default:
						Hub.Unregister <- targetClient
						targetClient.Conn.Close()
					}
				}
			}
		}
	}
}

func (c *WSClient) WritePump() {
	ticker := time.NewTicker(54 * time.Second)
	defer func() {
		ticker.Stop()
		c.Conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.Send:
			_ = c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				_ = c.Conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

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
