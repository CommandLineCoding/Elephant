package services

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

var (
	hubOnce  sync.Once
	upgrader = websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
)

func startHub() { hubOnce.Do(func() { go Hub.Run() }) }

// testClient is a registered server-side client plus the "phone" end of its socket.
type testClient struct {
	srv      *WSClient
	phone    *websocket.Conn
	readDone chan struct{} // closed once ReadPump has returned (and unregistered)
}

// connect opens a real WebSocket pair and registers the server side with the
// hub, running the same pumps the upgrade handler runs.
func connect(t *testing.T, userID string) *testClient {
	t.Helper()
	startHub()

	accepted := make(chan *websocket.Conn, 1)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		accepted <- c
	}))
	t.Cleanup(ts.Close)

	phone, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(ts.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = phone.Close() })

	tc := &testClient{
		srv:      NewWSClient(userID, <-accepted),
		phone:    phone,
		readDone: make(chan struct{}),
	}
	Hub.Register <- tc.srv
	flushHub() // Run handles one event at a time, so Register is done once this returns
	go tc.srv.WritePump()
	go func() {
		tc.srv.ReadPump()
		close(tc.readDone)
	}()
	return tc
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// read returns the next message of the given type, skipping presence noise
// from other tests' clients.
func (tc *testClient) read(t *testing.T, msgType string) map[string]interface{} {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		_ = tc.phone.SetReadDeadline(deadline)
		_, b, err := tc.phone.ReadMessage()
		if err != nil {
			t.Fatalf("waiting for %q message: %v", msgType, err)
		}
		var m map[string]interface{}
		if json.Unmarshal(b, &m) == nil && m["type"] == msgType {
			return m
		}
	}
}

func (tc *testClient) send(t *testing.T, v map[string]interface{}) {
	t.Helper()
	if err := tc.phone.WriteJSON(v); err != nil {
		t.Fatal(err)
	}
}

// flushHub waits until the hub has processed every unregister sent so far.
func flushHub() {
	Hub.Unregister <- NewWSClient("flush-marker", nil)
}

// This is the reconnect bug: the old connection's cleanup used to delete the
// user's *new* connection from the hub, so they silently stopped receiving.
func TestReconnectKeepsNewConnection(t *testing.T) {
	alice1 := connect(t, "reconnect-alice")
	bob := connect(t, "reconnect-bob")

	// The phone reconnects before the old socket has noticed it's dead.
	alice2 := connect(t, "reconnect-alice")

	// The old connection is closed by the hub, and its ReadPump unregisters it.
	select {
	case <-alice1.readDone:
	case <-time.After(3 * time.Second):
		t.Fatal("old connection was not closed after a newer one registered")
	}
	flushHub()

	if Hub.clientFor("reconnect-alice") != alice2.srv {
		t.Fatal("old connection's cleanup removed the new connection from the hub")
	}

	bob.send(t, map[string]interface{}{"type": "typing", "receiver_id": "reconnect-alice"})
	got := alice2.read(t, "typing")
	if got["sender_id"] != "reconnect-bob" {
		t.Errorf("unexpected typing message: %v", got)
	}
}

func TestClosingCurrentConnectionMarksUserOffline(t *testing.T) {
	alice := connect(t, "offline-alice")
	bob := connect(t, "offline-bob")

	_ = alice.phone.Close()

	for {
		m := bob.read(t, "user_status")
		if m["user_id"] == "offline-alice" && m["online"] == false {
			break
		}
	}
	if Hub.clientFor("offline-alice") != nil {
		t.Error("closed client is still registered")
	}
}

func TestReplacingAConnectionDoesNotFlashOffline(t *testing.T) {
	alice1 := connect(t, "flash-alice")
	bob := connect(t, "flash-bob")
	_ = connect(t, "flash-alice")

	<-alice1.readDone
	flushHub()

	// Bob must not be told alice went offline; then a later real offline arrives.
	bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "flash-alice"})
	m := bob.read(t, "user_status")
	for m["user_id"] != "flash-alice" {
		m = bob.read(t, "user_status")
	}
	if m["online"] != true {
		t.Errorf("expected flash-alice to stay online, got %v", m)
	}
}

func TestSlowClientIsDroppedWithoutBlocking(t *testing.T) {
	c := NewWSClient("slow", nil)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < cap(c.Send)+10; i++ {
			c.enqueue([]byte("x"))
		}
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("enqueue blocked on a client whose buffer is full")
	}
	select {
	case <-c.done:
	default:
		t.Error("a client that can't keep up should be disconnected")
	}
}

func TestSendRacingWithCloseDoesNotPanic(t *testing.T) {
	for i := 0; i < 50; i++ {
		c := NewWSClient("racer", nil)
		var wg sync.WaitGroup
		for j := 0; j < 8; j++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for k := 0; k < 100; k++ {
					c.enqueue([]byte("x"))
					c.trySend([]byte("y"))
				}
			}()
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.Close()
			c.Close() // idempotent
		}()
		wg.Wait()
	}
}

// The old code sent on Hub.Unregister while holding the hub's read lock, which
// deadlocked once Run needed the write lock. Dropping several slow members
// during one broadcast must not wedge the hub.
func TestBroadcastDroppingSlowClientsDoesNotDeadlock(t *testing.T) {
	startHub()

	const members = 30
	ids := make([]string, members)
	clients := make([]*WSClient, members)
	for i := range ids {
		ids[i] = fmt.Sprintf("slow-member-%d", i)
		clients[i] = NewWSClient(ids[i], nil)
		Hub.Register <- clients[i]
		for len(clients[i].Send) < cap(clients[i].Send) {
			clients[i].Send <- []byte("full")
		}
	}
	waitFor(t, "members to register", func() bool { return Hub.clientFor(ids[members-1]) == clients[members-1] })

	done := make(chan struct{})
	go func() {
		defer close(done)
		var wg sync.WaitGroup
		for i := 0; i < 5; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				Hub.sendToUsers(ids, "", []byte("hello group"))
			}()
		}
		// Meanwhile the dropped clients unregister, as their ReadPumps would.
		for _, c := range clients {
			Hub.Unregister <- c
		}
		wg.Wait()
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("hub deadlocked while dropping slow clients during a broadcast")
	}
	for _, id := range ids {
		waitFor(t, id+" to be removed", func() bool { return Hub.clientFor(id) == nil })
	}
}
