package controllers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

var editHubOnce sync.Once

func editTestUser(t *testing.T, name string) string {
	t.Helper()
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash) VALUES ($1, $2, 'x') RETURNING id::text`,
		fmt.Sprintf("ed.%s.%d", name, time.Now().UnixNano()%1_000_000_000), name).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

// connectToHub registers a client with the real hub and returns it. What the
// hub sends to the user arrives on client.Send.
func connectToHub(t *testing.T, userID string) *services.WSClient {
	t.Helper()
	editHubOnce.Do(func() { go services.Hub.Run() })
	c := services.NewWSClient(userID, nil)
	services.Hub.Register <- c
	t.Cleanup(func() { services.Hub.Unregister <- c })
	for i := 0; !services.Hub.IsOnline(userID); i++ {
		if i > 300 {
			t.Fatal("client never came online")
		}
		time.Sleep(10 * time.Millisecond)
	}
	return c
}

// nextEvent returns the next event of the given type sent to the client.
func nextEvent(c *services.WSClient, eventType string, wait time.Duration) (map[string]interface{}, bool) {
	timeout := time.After(wait)
	for {
		select {
		case b := <-c.Send:
			var m map[string]interface{}
			if json.Unmarshal(b, &m) == nil && m["type"] == eventType {
				return m, true
			}
		case <-timeout:
			return nil, false
		}
	}
}

func editMessageAs(userID, messageID, content string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"content": content})
	req := httptest.NewRequest("PUT", "/api/messages/"+messageID, bytes.NewReader(body))
	route := chi.NewRouteContext()
	route.URLParams.Add("id", messageID)
	ctx := context.WithValue(req.Context(), chi.RouteCtxKey, route)
	req = req.WithContext(context.WithValue(ctx, middlewares.UserIDKey, userID))

	w := httptest.NewRecorder()
	HandleEditMessage(w, req)
	return w
}

func TestEditingAMessageTellsTheOtherPerson(t *testing.T) {
	alice, bob := editTestUser(t, "alice"), editTestUser(t, "bob")
	msg, err := repository.NewMessageRepository().CreateMessage(context.Background(), alice, bob, "original", "")
	if err != nil {
		t.Fatal(err)
	}
	bobsApp := connectToHub(t, bob)

	if w := editMessageAs(alice, msg.ID, "corrected"); w.Code != http.StatusOK {
		t.Fatalf("the edit should succeed, got %d: %s", w.Code, w.Body.String())
	}

	event, ok := nextEvent(bobsApp, "message_edited", 3*time.Second)
	if !ok {
		t.Fatal("bob was never told about the edit")
	}
	if event["message_id"] != msg.ID || event["content"] != "corrected" || event["sender_id"] != alice || event["receiver_id"] != bob {
		t.Errorf("unexpected event: %v", event)
	}
	if event["edited_at"] == nil {
		t.Error("the event should say when it was edited")
	}
}

func TestARejectedEditTellsNobody(t *testing.T) {
	alice, bob, eve := editTestUser(t, "alice"), editTestUser(t, "bob"), editTestUser(t, "eve")
	msg, err := repository.NewMessageRepository().CreateMessage(context.Background(), alice, bob, "original", "")
	if err != nil {
		t.Fatal(err)
	}
	bobsApp := connectToHub(t, bob)

	if w := editMessageAs(eve, msg.ID, "forged"); w.Code != http.StatusForbidden {
		t.Fatalf("editing someone else's message should be 403, got %d", w.Code)
	}
	if w := editMessageAs(alice, msg.ID, "   "); w.Code != http.StatusBadRequest {
		t.Fatalf("an empty edit should be 400, got %d", w.Code)
	}

	if _, got := nextEvent(bobsApp, "message_edited", 400*time.Millisecond); got {
		t.Error("bob was told about an edit that was refused")
	}
}
