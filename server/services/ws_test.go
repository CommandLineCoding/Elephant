package services

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

var (
	hubOnce  sync.Once
	upgrader = websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
)

func startHub() { hubOnce.Do(func() { go Hub.Run() }) }

// By default nobody is anybody's contact, and the hub never touches a database.
func noContacts(context.Context, string) ([]string, error) { return nil, nil }

func init() { Hub.contacts = noContacts }

// setContacts installs a contact book for one test. Each entry lists the
// people that user shares a conversation or group with.
func setContacts(t *testing.T, book map[string][]string) {
	setContactLoader(t, func(_ context.Context, id string) ([]string, error) { return book[id], nil })
}

func setContactLoader(t *testing.T, load contactLoader) {
	t.Helper()
	Hub.mu.Lock()
	old := Hub.contacts
	Hub.contacts = load
	Hub.mu.Unlock()
	t.Cleanup(func() {
		Hub.mu.Lock()
		Hub.contacts = old
		Hub.mu.Unlock()
	})
}

// testClient is a registered server-side client plus the "phone" end of its socket.
type testClient struct {
	srv      *WSClient
	phone    *websocket.Conn
	readDone chan struct{}               // closed once ReadPump has returned (and unregistered)
	inbox    chan map[string]interface{} // everything the server sent, in order
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
		inbox:    make(chan map[string]interface{}, 256),
	}
	// A gorilla connection is unusable after a read times out, so tests wait on
	// this channel with timers instead of setting read deadlines.
	go func() {
		defer close(tc.inbox)
		for {
			_, b, err := phone.ReadMessage()
			if err != nil {
				return
			}
			var m map[string]interface{}
			if json.Unmarshal(b, &m) == nil {
				select {
				case tc.inbox <- m:
				default:
				}
			}
		}
	}()
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
	timeout := time.After(3 * time.Second)
	for {
		select {
		case m, ok := <-tc.inbox:
			if !ok {
				t.Fatalf("connection closed while waiting for %q", msgType)
			}
			if m["type"] == msgType {
				return m
			}
		case <-timeout:
			t.Fatalf("timed out waiting for a %q message", msgType)
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
	setContacts(t, map[string][]string{
		"offline-alice": {"offline-bob"},
		"offline-bob":   {"offline-alice"},
	})
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
	setContacts(t, map[string][]string{
		"flash-alice": {"flash-bob"},
		"flash-bob":   {"flash-alice"},
	})
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

// Chat messages for people who weren't reached live need a push ping instead.
func TestSendReportsWhoWasNotReachedLive(t *testing.T) {
	online := connect(t, "reach-online")
	_ = online

	if !Hub.sendToUser("reach-online", []byte("hi")) {
		t.Error("an online user should be reported as reached")
	}
	if Hub.sendToUser("reach-nobody", []byte("hi")) {
		t.Error("an offline user must not be reported as reached")
	}
	if !Hub.IsOnline("reach-online") || Hub.IsOnline("reach-nobody") {
		t.Error("IsOnline disagrees with who is connected")
	}

	missed := Hub.sendToUsers([]string{"reach-online", "reach-nobody", "reach-sender"}, "reach-sender", []byte("hi"))
	if len(missed) != 1 || missed[0] != "reach-nobody" {
		t.Errorf("only the offline member should be reported, got %v", missed)
	}

	// A client that can't keep up is dropped, so it is reported as missed too.
	slow := NewWSClient("reach-slow", nil)
	Hub.Register <- slow
	flushHub()
	for len(slow.Send) < cap(slow.Send) {
		slow.Send <- []byte("full")
	}
	if got := Hub.sendToUsers([]string{"reach-slow"}, "", []byte("hi")); len(got) != 1 {
		t.Errorf("a client with a full buffer should be reported as missed, got %v", got)
	}
}

// --- presence is only shared with contacts ---

// statusFor waits up to wait for a user_status about userID, returning its
// online flag, or reports that none arrived.
func (tc *testClient) statusFor(userID string, wait time.Duration) (online, got bool) {
	timeout := time.After(wait)
	for {
		select {
		case m, ok := <-tc.inbox:
			if !ok {
				return false, false
			}
			if m["type"] == "user_status" && m["user_id"] == userID {
				on, _ := m["online"].(bool)
				return on, true
			}
		case <-timeout:
			return false, false
		}
	}
}

func TestPresenceOnlyGoesToContacts(t *testing.T) {
	setContacts(t, map[string][]string{
		"pres-alice": {"pres-bob"},
		"pres-bob":   {"pres-alice"},
	})
	bob := connect(t, "pres-bob")
	stranger := connect(t, "pres-stranger")

	alice := connect(t, "pres-alice")

	if online, got := bob.statusFor("pres-alice", 3*time.Second); !got || !online {
		t.Errorf("a contact should be told alice came online (got=%v online=%v)", got, online)
	}
	if _, got := stranger.statusFor("pres-alice", 400*time.Millisecond); got {
		t.Error("a stranger was told alice came online")
	}

	_ = alice.phone.Close()
	if online, got := bob.statusFor("pres-alice", 3*time.Second); !got || online {
		t.Errorf("a contact should be told alice went offline (got=%v online=%v)", got, online)
	}
	if _, got := stranger.statusFor("pres-alice", 400*time.Millisecond); got {
		t.Error("a stranger was told alice went offline")
	}
}

func TestStatusRequestsAreAnsweredOnlyForContacts(t *testing.T) {
	setContacts(t, map[string][]string{
		"ask-bob":      {"ask-alice"},
		"ask-alice":    {"ask-bob"},
		"ask-stranger": nil,
	})
	_ = connect(t, "ask-alice") // online
	bob := connect(t, "ask-bob")
	stranger := connect(t, "ask-stranger")

	bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "ask-alice"})
	if online, got := bob.statusFor("ask-alice", 3*time.Second); !got || !online {
		t.Errorf("a contact should be told alice is online (got=%v online=%v)", got, online)
	}

	// The stranger gets an answer, but it is the same as for someone offline.
	stranger.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "ask-alice"})
	if online, got := stranger.statusFor("ask-alice", 3*time.Second); !got || online {
		t.Errorf("a stranger must be told alice is offline (got=%v online=%v)", got, online)
	}
	stranger.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "ask-nobody"})
	if online, got := stranger.statusFor("ask-nobody", 3*time.Second); !got || online {
		t.Errorf("an unknown user is simply offline (got=%v online=%v)", got, online)
	}
}

// If the contact list can't be loaded, sharing nothing is the safe answer.
func TestPresenceFailsClosedWhenContactsCantBeLoaded(t *testing.T) {
	setContactLoader(t, func(context.Context, string) ([]string, error) { return nil, errors.New("database is down") })
	bob := connect(t, "closed-bob")
	_ = connect(t, "closed-alice")

	if _, got := bob.statusFor("closed-alice", 400*time.Millisecond); got {
		t.Error("a presence update went out although contacts couldn't be loaded")
	}
	bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "closed-alice"})
	if online, got := bob.statusFor("closed-alice", 3*time.Second); !got || online {
		t.Errorf("a status request must be answered 'offline' (got=%v online=%v)", got, online)
	}
}

func TestContactListIsCachedBriefly(t *testing.T) {
	old := contactCacheTTL
	contactCacheTTL = 80 * time.Millisecond
	t.Cleanup(func() { contactCacheTTL = old })

	var loads int32
	setContactLoader(t, func(context.Context, string) ([]string, error) {
		atomic.AddInt32(&loads, 1)
		return []string{"cache-alice"}, nil
	})
	bob := connect(t, "cache-bob")
	// Connecting loads bob's contacts once, asynchronously, to announce him.
	waitFor(t, "the connect-time announcement", func() bool { return atomic.LoadInt32(&loads) >= 1 })
	base := atomic.LoadInt32(&loads)

	ask := func() {
		bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "cache-alice"})
		bob.statusFor("cache-alice", 2*time.Second)
	}
	ask()
	ask()
	ask()
	if n := atomic.LoadInt32(&loads) - base; n != 1 {
		t.Errorf("three status requests loaded contacts %d times, want 1", n)
	}

	time.Sleep(120 * time.Millisecond)
	ask()
	if n := atomic.LoadInt32(&loads) - base; n != 2 {
		t.Errorf("after the cache expired it should reload, loads=%d want 2", n)
	}
}
