package controllers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

func acceptRequest(t *testing.T, as, from string) (int, models.JSONResponse) {
	t.Helper()
	router := chi.NewRouter()
	router.Post("/api/messages/requests/{userId}/accept", HandleAcceptRequest)
	req := httptest.NewRequest(http.MethodPost, "/api/messages/requests/"+from+"/accept", nil)
	req = req.WithContext(context.WithValue(req.Context(), middlewares.UserIDKey, as))
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	var resp models.JSONResponse
	_ = json.NewDecoder(w.Body).Decode(&resp)
	return w.Code, resp
}

func isPending(t *testing.T, recipient, sender string) bool {
	t.Helper()
	var pending bool
	if err := config.DB.QueryRow(context.Background(),
		`SELECT EXISTS (SELECT 1 FROM message_requests WHERE recipient_id = $1::uuid AND sender_id = $2::uuid)`,
		recipient, sender).Scan(&pending); err != nil {
		t.Fatal(err)
	}
	return pending
}

func TestAcceptingARequest(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	svc := services.NewMessageService()
	_, isReq, err := svc.SendMessage(context.Background(), alice, bob, "hello", "")
	if err != nil || !isReq {
		t.Fatalf("SendMessage = %v, %v; want a request", isReq, err)
	}
	if !isPending(t, bob, alice) {
		t.Fatal("no pending request")
	}

	// Only the recipient can accept, and only a request that exists.
	if code, _ := acceptRequest(t, alice, bob); code != http.StatusNotFound {
		t.Errorf("the sender accepting got %d, want 404", code)
	}
	if !isPending(t, bob, alice) {
		t.Fatal("the sender's attempt ended the request")
	}
	if code, resp := acceptRequest(t, bob, alice); code != http.StatusOK || !resp.Success {
		t.Fatalf("accepting got %d: %+v", code, resp)
	}
	if isPending(t, bob, alice) {
		t.Error("still pending after accepting")
	}
	if code, _ := acceptRequest(t, bob, alice); code != http.StatusNotFound {
		t.Errorf("accepting twice got %d, want 404", code)
	}
	if code, _ := acceptRequest(t, bob, "not-a-uuid"); code != http.StatusBadRequest {
		t.Errorf("a bad id got %d, want 400", code)
	}
}

func TestAnsweringARequestAcceptsIt(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	svc := services.NewMessageService()
	if _, isReq, err := svc.SendMessage(context.Background(), alice, bob, "hello", ""); err != nil || !isReq {
		t.Fatalf("first message = %v, %v", isReq, err)
	}
	// bob replies without pressing Accept.
	if _, isReq, err := svc.SendMessage(context.Background(), bob, alice, "hi!", ""); err != nil || isReq {
		t.Fatalf("the reply = %v, %v; want an ordinary message", isReq, err)
	}
	if isPending(t, bob, alice) {
		t.Error("replying didn't accept the request")
	}
	// And alice's next message is an ordinary one.
	if _, isReq, err := svc.SendMessage(context.Background(), alice, bob, "great", ""); err != nil || isReq {
		t.Errorf("a later message = %v, %v; want ordinary", isReq, err)
	}
}

func TestReadingARequestDoesNotMarkItRead(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	svc := services.NewMessageService()
	if _, isReq, err := svc.SendMessage(context.Background(), alice, bob, "hello", ""); err != nil || !isReq {
		t.Fatalf("first message = %v, %v", isReq, err)
	}

	markRead := func() {
		t.Helper()
		body, _ := json.Marshal(map[string]string{"sender_id": alice})
		req := httptest.NewRequest(http.MethodPost, "/api/messages/read", bytes.NewReader(body))
		req = req.WithContext(context.WithValue(req.Context(), middlewares.UserIDKey, bob))
		w := httptest.NewRecorder()
		HandleMarkRead(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("mark read got %d", w.Code)
		}
	}
	read := func() bool {
		var r bool
		if err := config.DB.QueryRow(context.Background(),
			`SELECT is_read FROM messages WHERE sender_id = $1::uuid AND receiver_id = $2::uuid`, alice, bob).Scan(&r); err != nil {
			t.Fatal(err)
		}
		return r
	}

	markRead()
	if read() {
		t.Error("a request was marked read, so alice would see it as read")
	}
	if code, _ := acceptRequest(t, bob, alice); code != http.StatusOK {
		t.Fatalf("accept got %d", code)
	}
	markRead()
	if !read() {
		t.Error("after accepting, reading did not mark it read")
	}
}
