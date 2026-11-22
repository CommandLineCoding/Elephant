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

	"github.com/commandlinecoding/elephant/server/repository"
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
	// A clock that only moves when the test says so: on a slow machine,
	// real time could expire the cache in the middle of the test.
	start := time.Now()
	var elapsed atomic.Int64
	old := contactClock
	contactClock = func() time.Time { return start.Add(time.Duration(elapsed.Load())) }
	t.Cleanup(func() { contactClock = old })

	var loads int32
	setContactLoader(t, func(_ context.Context, userID string) ([]string, error) {
		if userID == "cache-bob" {
			atomic.AddInt32(&loads, 1)
		}
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
	// Another user's presence change (e.g. a previous test's client closing)
	// also loads contacts through the hub; only bob's loads count here.
	Hub.broadcastStatus("someone-from-another-test", false)
	ask()
	ask()
	if n := atomic.LoadInt32(&loads) - base; n != 1 {
		t.Errorf("three status requests loaded contacts %d times, want 1", n)
	}

	elapsed.Store(int64(contactCacheTTL + time.Second))
	ask()
	if n := atomic.LoadInt32(&loads) - base; n != 2 {
		t.Errorf("after the cache expired it should reload, loads=%d want 2", n)
	}
}

// Signing a device out closes the connection that device opened, and only
// that one: the person's other device keeps its own.
func TestDisconnectSessionClosesOnlyThatDevicesConnection(t *testing.T) {
	closed := func(c *WSClient) bool {
		select {
		case <-c.done:
			return true
		default:
			return false
		}
	}
	put := func(c *WSClient) {
		Hub.mu.Lock()
		Hub.clients[strings.ToLower(c.UserID)] = c
		Hub.mu.Unlock()
	}
	drop := func(id string) {
		Hub.mu.Lock()
		delete(Hub.clients, id)
		Hub.mu.Unlock()
	}

	phone := NewWSClient("sess-user", nil)
	phone.SessionID = "phone-session"
	put(phone)
	defer drop("sess-user")

	Hub.DisconnectSession("sess-user", "tablet-session")
	if closed(phone) {
		t.Fatal("signing out another device closed this one's connection")
	}
	Hub.DisconnectSession("someone-else", "phone-session")
	if closed(phone) {
		t.Fatal("a session ID from another user closed the connection")
	}
	Hub.DisconnectSession("sess-user", "")
	if closed(phone) {
		t.Fatal("an empty session closed a connection")
	}
	Hub.DisconnectSession("sess-user", "phone-session")
	if !closed(phone) {
		t.Error("signing the device out did not close its connection")
	}
}

// setSettings installs privacy settings for one test. Anyone not listed has
// the defaults.
func setSettings(t *testing.T, byUser map[string]repository.UserSettings) {
	t.Helper()
	Hub.mu.Lock()
	old := Hub.settings
	Hub.settings = func(_ context.Context, id string) (repository.UserSettings, error) {
		if s, ok := byUser[id]; ok {
			return s, nil
		}
		return repository.DefaultUserSettings(), nil
	}
	Hub.mu.Unlock()
	t.Cleanup(func() {
		Hub.mu.Lock()
		Hub.settings = old
		Hub.mu.Unlock()
	})
}

func online(status string) repository.UserSettings {
	s := repository.DefaultUserSettings()
	s.OnlineStatus = status
	return s
}

// Someone who hides their status isn't announced, even to contacts, and a
// status request is answered "offline" even though they are connected.
func TestNobodyHidesOnlineStatusFromEveryone(t *testing.T) {
	setContacts(t, map[string][]string{
		"hide-alice": {"hide-bob"},
		"hide-bob":   {"hide-alice"},
	})
	setSettings(t, map[string]repository.UserSettings{"hide-alice": online(repository.AudienceNobody)})
	bob := connect(t, "hide-bob")
	alice := connect(t, "hide-alice")

	if _, got := bob.statusFor("hide-alice", 400*time.Millisecond); got {
		t.Error("alice came online and a contact was told, although she hides it")
	}
	bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "hide-alice"})
	if on, got := bob.statusFor("hide-alice", 3*time.Second); !got || on {
		t.Errorf("a contact must be told alice is offline (got=%v online=%v)", got, on)
	}

	_ = alice.phone.Close()
	if _, got := bob.statusFor("hide-alice", 400*time.Millisecond); got {
		t.Error("alice went offline and a contact was told, although she hides it")
	}
}

// Everyone lets a stranger ask whether the person is online. Contacts is
// the default and keeps it to people who share a chat or a group.
func TestEveryoneLetsAStrangerAskButContactsDoesNot(t *testing.T) {
	setContacts(t, map[string][]string{"open-stranger": nil, "closed-stranger": nil})
	setSettings(t, map[string]repository.UserSettings{
		"open-alice": online(repository.AudienceEveryone),
	})
	_ = connect(t, "open-alice")
	_ = connect(t, "closed-alice")
	stranger := connect(t, "open-stranger")

	stranger.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "open-alice"})
	if on, got := stranger.statusFor("open-alice", 3*time.Second); !got || !on {
		t.Errorf("a stranger may see someone who shows their status to everyone (got=%v online=%v)", got, on)
	}
	stranger.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "closed-alice"})
	if on, got := stranger.statusFor("closed-alice", 3*time.Second); !got || on {
		t.Errorf("a stranger must not see a contacts-only person (got=%v online=%v)", got, on)
	}
}

func TestEveryoneStillRespectsBlocks(t *testing.T) {
	setSettings(t, map[string]repository.UserSettings{"blk-alice": online(repository.AudienceEveryone)})
	_ = connect(t, "blk-alice")
	bob := connect(t, "blk-bob")

	setBlocks(t, [2]string{"blk-alice", "blk-bob"})
	bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "blk-alice"})
	if on, got := bob.statusFor("blk-alice", 3*time.Second); !got || on {
		t.Errorf("someone alice blocked must not see her status (got=%v online=%v)", got, on)
	}
}

// If the settings can't be loaded, nothing is shared.
func TestPresenceFailsClosedWhenSettingsCantBeLoaded(t *testing.T) {
	setContacts(t, map[string][]string{"sf-alice": {"sf-bob"}, "sf-bob": {"sf-alice"}})
	Hub.mu.Lock()
	old := Hub.settings
	Hub.settings = func(context.Context, string) (repository.UserSettings, error) {
		return repository.UserSettings{}, errors.New("database is down")
	}
	Hub.mu.Unlock()
	t.Cleanup(func() { Hub.mu.Lock(); Hub.settings = old; Hub.mu.Unlock() })

	bob := connect(t, "sf-bob")
	_ = connect(t, "sf-alice")
	if _, got := bob.statusFor("sf-alice", 400*time.Millisecond); got {
		t.Error("a presence update went out although settings couldn't be loaded")
	}
	bob.send(t, map[string]interface{}{"type": "request_status", "receiver_id": "sf-alice"})
	if on, got := bob.statusFor("sf-alice", 3*time.Second); !got || on {
		t.Errorf("a status request must be answered offline (got=%v online=%v)", got, on)
	}
}

// With read receipts off the other person is not told, and with them on they are.
func TestReadReceiptsAreSentOnlyIfThePersonAllowsThem(t *testing.T) {
	pushTestDB(t)
	off := repository.DefaultUserSettings()
	off.ReadReceipts = false
	setSettings(t, map[string]repository.UserSettings{"rr-quiet": off})
	setContacts(t, map[string][]string{})
	sender := connect(t, "rr-sender")
	quiet := connect(t, "rr-quiet")
	chatty := connect(t, "rr-chatty")

	quiet.send(t, map[string]interface{}{"type": "read_receipt", "receiver_id": "rr-sender"})
	chatty.send(t, map[string]interface{}{"type": "read_receipt", "receiver_id": "rr-sender"})

	got := sender.read(t, "read_receipt")
	if got["sender_id"] != "rr-chatty" {
		t.Fatalf("the first read receipt came from %v, want rr-chatty (the quiet one must send none)", got["sender_id"])
	}
	select {
	case m, ok := <-sender.inbox:
		if ok && m["type"] == "read_receipt" {
			t.Errorf("a second read receipt arrived: %v", m)
		}
	case <-time.After(400 * time.Millisecond):
	}
}

func TestExpiryIsClampedAndOnlyForDisappearingMessages(t *testing.T) {
	sent := time.Date(2026, 11, 22, 12, 0, 0, 0, time.UTC)
	if expiryFor(0, sent) != nil || expiryFor(-5, sent) != nil {
		t.Error("a message with no life got an expiry")
	}
	at := func(secs int) time.Duration {
		e := expiryFor(secs, sent)
		if e == nil {
			t.Fatalf("no expiry for %d", secs)
		}
		return e.Sub(sent)
	}
	if at(3600) != time.Hour || at(86400) != 24*time.Hour || at(28*24*3600) != 28*24*time.Hour {
		t.Error("the choices don't add up")
	}
	if at(5) != time.Minute {
		t.Errorf("5 seconds became %v, want a minute", at(5))
	}
	if at(10*365*24*3600) != 28*24*time.Hour {
		t.Errorf("ten years became %v, want four weeks", at(10*365*24*3600))
	}
}

// A disappearing message is stored with its time, and recipients are told the
// time (not the sender's number of seconds).
func TestADisappearingMessageIsStoredAndRelayedWithItsTime(t *testing.T) {
	db := pushTestDB(t)
	aliceID, bobID := newTestUser(t), newTestUser(t)
	alice, bob := connect(t, aliceID), connect(t, bobID)

	send := func(id string, extra map[string]interface{}) map[string]interface{} {
		frame := map[string]interface{}{
			"type": "chat", "receiver_id": bobID, "message_id": id,
			"content": `{"type":0,"ciphertext":"hi"}`,
		}
		for k, v := range extra {
			frame[k] = v
		}
		alice.send(t, frame)
		return bob.read(t, "chat")
	}
	stored := func(id string) *time.Time {
		var at *time.Time
		waitFor(t, "the message to be stored", func() bool {
			var n int
			_ = db.QueryRow(context.Background(), `SELECT count(*) FROM messages WHERE id = $1::uuid`, id).Scan(&n)
			return n == 1
		})
		_ = db.QueryRow(context.Background(), `SELECT expires_at FROM messages WHERE id = $1::uuid`, id).Scan(&at)
		return at
	}

	id1 := "00000000-0000-0000-0000-0000000000b1"
	got := send(id1, map[string]interface{}{"expires_in": 3600})
	if _, leaked := got["expires_in"]; leaked {
		t.Error("the sender's number of seconds was passed on")
	}
	exp, _ := got["expires_at"].(string)
	parsed, err := time.Parse(time.RFC3339Nano, exp)
	if err != nil || time.Until(parsed) < 59*time.Minute || time.Until(parsed) > 61*time.Minute {
		t.Errorf("the recipient was told %q", exp)
	}
	if at := stored(id1); at == nil || at.Sub(parsed).Abs() > time.Second {
		t.Errorf("stored %v, relayed %v", at, parsed)
	}

	// Too short is raised to a minute.
	id2 := "00000000-0000-0000-0000-0000000000b2"
	got = send(id2, map[string]interface{}{"expires_in": 2})
	short, _ := time.Parse(time.RFC3339Nano, got["expires_at"].(string))
	if d := time.Until(short); d < 55*time.Second || d > 65*time.Second {
		t.Errorf("a 2 second life lasts %v", d)
	}

	// An ordinary message has none.
	id3 := "00000000-0000-0000-0000-0000000000b3"
	got = send(id3, nil)
	if _, has := got["expires_at"]; has {
		t.Errorf("an ordinary message was told it expires: %v", got["expires_at"])
	}
	if at := stored(id3); at != nil {
		t.Errorf("an ordinary message is stored with an expiry %v", at)
	}

	// A reply (relayed through another path) carries it too.
	id4 := "00000000-0000-0000-0000-0000000000b4"
	got = send(id4, map[string]interface{}{"expires_in": 3600, "reply_to_message_id": id3})
	if got["expires_at"] == nil {
		t.Error("a reply to a message lost the expiry")
	}
}
