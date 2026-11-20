package controllers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/go-chi/chi/v5"
)

var deleteTestSeq int64

func deleteTestUser(t *testing.T, name string) string {
	t.Helper()
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash) VALUES ($1, $2, 'x') RETURNING id::text`,
		fmt.Sprintf("dm.%s.%d.%d", name, time.Now().UnixNano()%1_000_000, atomic.AddInt64(&deleteTestSeq, 1)), name).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

// deleteMessage calls DELETE /api/messages/{id}?query as the given user,
// through a router so the {id} parameter is read the way it is in the app.
func deleteMessage(t *testing.T, as, id, query string) (int, models.JSONResponse) {
	t.Helper()
	router := chi.NewRouter()
	router.Delete("/api/messages/{id}", HandleDeleteMessage)
	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+id+query, nil)
	req = req.WithContext(context.WithValue(req.Context(), middlewares.UserIDKey, as))
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	var resp models.JSONResponse
	_ = json.NewDecoder(w.Body).Decode(&resp)
	return w.Code, resp
}

func storeMessage(t *testing.T, from, to, content string) string {
	t.Helper()
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO messages (sender_id, receiver_id, content) VALUES ($1::uuid, $2::uuid, $3) RETURNING id::text`,
		from, to, content).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestDeleteMessageForEveryone(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	id := storeMessage(t, alice, bob, "oops")

	code, resp := deleteMessage(t, alice, id, "?for=everyone")
	if code != http.StatusOK || !resp.Success {
		t.Fatalf("status %d: %+v", code, resp)
	}
	var content string
	var deleted bool
	if err := config.DB.QueryRow(context.Background(),
		`SELECT content, deleted_at IS NOT NULL FROM messages WHERE id = $1::uuid`, id).Scan(&content, &deleted); err != nil {
		t.Fatal(err)
	}
	if content != "" || !deleted {
		t.Errorf("content %q, deleted %v", content, deleted)
	}
}

func TestDeleteMessageForEveryoneIsForTheSenderOnly(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	id := storeMessage(t, alice, bob, "mine")

	if code, _ := deleteMessage(t, bob, id, "?for=everyone"); code != http.StatusForbidden {
		t.Errorf("the receiver got %d, want 403", code)
	}
	var content string
	_ = config.DB.QueryRow(context.Background(), `SELECT content FROM messages WHERE id = $1::uuid`, id).Scan(&content)
	if content != "mine" {
		t.Errorf("the message was changed: %q", content)
	}

	if code, _ := deleteMessage(t, alice, id, "?for=everyone"); code != http.StatusOK {
		t.Fatalf("the sender got %d", code)
	}
	if code, _ := deleteMessage(t, alice, id, "?for=everyone"); code != http.StatusNotFound {
		t.Errorf("deleting twice got %d, want 404", code)
	}
}

func TestDeleteMessageForMeIsTheDefault(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	id := storeMessage(t, alice, bob, "hi")

	for _, query := range []string{"", "?for=me"} {
		if code, resp := deleteMessage(t, bob, id, query); code != http.StatusOK || !resp.Success {
			t.Errorf("%q: status %d: %+v", query, code, resp)
		}
	}
	var content string
	var deleted bool
	_ = config.DB.QueryRow(context.Background(),
		`SELECT content, deleted_at IS NOT NULL FROM messages WHERE id = $1::uuid`, id).Scan(&content, &deleted)
	if content != "hi" || deleted {
		t.Errorf("hiding must not change the message: %q, deleted %v", content, deleted)
	}
}

func TestDeleteMessageRejectsBadRequests(t *testing.T) {
	alice, bob, eve := deleteTestUser(t, "alice"), deleteTestUser(t, "bob"), deleteTestUser(t, "eve")
	id := storeMessage(t, alice, bob, "hi")

	cases := []struct {
		name, as, id, query string
		want                int
	}{
		{"not a uuid", alice, "nope", "", http.StatusBadRequest},
		{"bad scope", alice, id, "?for=all", http.StatusBadRequest},
		{"unknown message", alice, "00000000-0000-4000-8000-000000000000", "?for=everyone", http.StatusNotFound},
		{"unknown message for me", alice, "00000000-0000-4000-8000-000000000000", "", http.StatusNotFound},
		{"a stranger hiding it", eve, id, "", http.StatusNotFound},
	}
	for _, c := range cases {
		if code, _ := deleteMessage(t, c.as, c.id, c.query); code != c.want {
			t.Errorf("%s: got %d, want %d", c.name, code, c.want)
		}
	}
}

func TestADeletedMessageCanNotBeEdited(t *testing.T) {
	alice, bob := deleteTestUser(t, "alice"), deleteTestUser(t, "bob")
	id := storeMessage(t, alice, bob, "old")
	if code, _ := deleteMessage(t, alice, id, "?for=everyone"); code != http.StatusOK {
		t.Fatalf("delete got %d", code)
	}

	router := chi.NewRouter()
	router.Put("/api/messages/{id}", HandleEditMessage)
	req := httptest.NewRequest(http.MethodPut, "/api/messages/"+id, stringsReader(`{"content":"new words"}`))
	req = req.WithContext(context.WithValue(req.Context(), middlewares.UserIDKey, alice))
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Errorf("editing a deleted message got %d, want 404", w.Code)
	}
	var content string
	_ = config.DB.QueryRow(context.Background(), `SELECT content FROM messages WHERE id = $1::uuid`, id).Scan(&content)
	if content != "" {
		t.Errorf("the tombstone was given content again: %q", content)
	}
}

func stringsReader(s string) *strings.Reader { return strings.NewReader(s) }
