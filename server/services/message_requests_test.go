package services

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/repository"
)

// useRealRequests installs the database lookups for message requests, which
// the hub tests replace with "nobody has a request".
func useRealRequests(t *testing.T) {
	t.Helper()
	oldOpen, oldPending, oldAccept := requestOpen, requestPending, requestAccept
	reqs := repository.NewRequestRepository()
	requestOpen, requestPending, requestAccept = reqs.Open, reqs.Pending, reqs.Accept
	t.Cleanup(func() { requestOpen, requestPending, requestAccept = oldOpen, oldPending, oldAccept })
}

func recordPings(t *testing.T) func() [][]string {
	t.Helper()
	var mu sync.Mutex
	var pinged [][]string
	old := pushPing
	pushPing = func(ids []string) {
		mu.Lock()
		defer mu.Unlock()
		pinged = append(pinged, ids)
	}
	t.Cleanup(func() { pushPing = old })
	return func() [][]string {
		mu.Lock()
		defer mu.Unlock()
		return append([][]string(nil), pinged...)
	}
}

func chatFrame(to, id string, extra map[string]interface{}) map[string]interface{} {
	f := map[string]interface{}{
		"type": "chat", "receiver_id": to, "message_id": id,
		"content": `{"type":0,"ciphertext":"hi"}`,
	}
	for k, v := range extra {
		f[k] = v
	}
	return f
}

func TestAMessageFromAStrangerIsFlaggedAsARequest(t *testing.T) {
	useRealRequests(t)
	aliceID, bobID, carolID := newTestUser(t), newTestUser(t), newTestUser(t)
	alice, bob := connect(t, aliceID), connect(t, bobID)

	alice.send(t, chatFrame(bobID, "00000000-0000-0000-0000-0000000000c1", nil))
	got := bob.read(t, "chat")
	if got["request"] != true {
		t.Errorf("the first message from a stranger wasn't flagged: %v", got)
	}

	// A message from someone bob already chats with is an ordinary one.
	carol := connect(t, carolID)
	bob.send(t, chatFrame(carolID, "00000000-0000-0000-0000-0000000000c2", nil))
	carol.read(t, "chat")
	carol.send(t, chatFrame(bobID, "00000000-0000-0000-0000-0000000000c3", nil))
	if got := bob.read(t, "chat"); got["request"] == true {
		t.Errorf("a message from someone bob wrote first was flagged: %v", got)
	}
}

func TestOnlyTheServerSaysARequest(t *testing.T) {
	useRealRequests(t)
	aliceID, bobID := newTestUser(t), newTestUser(t)
	alice, bob := connect(t, aliceID), connect(t, bobID)
	// bob writes first, so alice's reply is not a request, whatever she claims.
	bob.send(t, chatFrame(aliceID, "00000000-0000-0000-0000-0000000000d1", nil))
	alice.read(t, "chat")
	alice.send(t, chatFrame(bobID, "00000000-0000-0000-0000-0000000000d2", map[string]interface{}{"request": true}))
	if got := bob.read(t, "chat"); got["request"] == true {
		t.Errorf("a sender made their own message a request: %v", got)
	}
}

func TestARequestWakesNobodyButARepliedChatDoes(t *testing.T) {
	useRealRequests(t)
	pings := recordPings(t)
	aliceID, bobID := newTestUser(t), newTestUser(t)
	alice := connect(t, aliceID) // bob is offline

	alice.send(t, chatFrame(bobID, "00000000-0000-0000-0000-0000000000e1", nil))
	waitFor(t, "the request to be recorded", func() bool {
		p, _ := requestPending(context.Background(), bobID, aliceID)
		return p
	})
	time.Sleep(300 * time.Millisecond)
	if got := pings(); len(got) != 0 {
		t.Fatalf("a message request pinged %v", got)
	}

	// Once accepted, an offline recipient is pinged again.
	if _, err := requestAccept(context.Background(), bobID, aliceID); err != nil {
		t.Fatal(err)
	}
	alice.send(t, chatFrame(bobID, "00000000-0000-0000-0000-0000000000e2", nil))
	waitFor(t, "a push ping", func() bool { return len(pings()) == 1 })
	if got := pings(); got[0][0] != bobID {
		t.Errorf("pinged %v, want %s", got, bobID)
	}
}

func TestARequestGetsNoTypingOrReadReceiptFromTheRecipient(t *testing.T) {
	useRealRequests(t)
	aliceID, bobID := newTestUser(t), newTestUser(t)
	alice, bob := connect(t, aliceID), connect(t, bobID)

	alice.send(t, chatFrame(bobID, "00000000-0000-0000-0000-0000000000f1", nil))
	bob.read(t, "chat")

	nothingFor := func(what string) {
		t.Helper()
		select {
		case m := <-alice.inbox:
			if m["type"] == what {
				t.Errorf("alice got a %s while bob hadn't accepted: %v", what, m)
			}
		case <-time.After(400 * time.Millisecond):
		}
	}

	bob.send(t, map[string]interface{}{"type": "typing", "receiver_id": aliceID})
	nothingFor("typing")
	bob.send(t, map[string]interface{}{"type": "read_receipt", "receiver_id": aliceID})
	nothingFor("read_receipt")
	bob.send(t, map[string]interface{}{"type": "delivered", "message_ids": []string{"00000000-0000-0000-0000-0000000000f1"}})
	nothingFor("message_delivered")

	// alice's own typing still reaches bob.
	alice.send(t, map[string]interface{}{"type": "typing", "receiver_id": bobID})
	bob.read(t, "typing")

	// After accepting, all of it flows.
	if _, err := requestAccept(context.Background(), bobID, aliceID); err != nil {
		t.Fatal(err)
	}
	bob.send(t, map[string]interface{}{"type": "typing", "receiver_id": aliceID})
	alice.read(t, "typing")
	bob.send(t, map[string]interface{}{"type": "read_receipt", "receiver_id": aliceID})
	alice.read(t, "read_receipt")
}

func TestARequestFailsClosedForReceiptsWhenItCantBeChecked(t *testing.T) {
	old := requestPending
	requestPending = func(context.Context, string, string) (bool, error) { return false, context.DeadlineExceeded }
	t.Cleanup(func() { requestPending = old })
	if !pendingRequestFrom(context.Background(), "a", "b") {
		t.Error("with the lookup failing, receipts should be held back")
	}
}

func TestAFailedRequestLookupStillDeliversTheMessage(t *testing.T) {
	oldOpen, oldAccept := requestOpen, requestAccept
	requestOpen = func(context.Context, string, string) (bool, error) { return false, context.DeadlineExceeded }
	requestAccept = func(context.Context, string, string) (bool, error) { return false, nil }
	t.Cleanup(func() { requestOpen, requestAccept = oldOpen, oldAccept })
	if noteDirectMessage(context.Background(), "a", "b") {
		t.Error("a failed lookup made the message a request")
	}
}

func TestAcceptingARequestTellsTheSenderItWasDelivered(t *testing.T) {
	db := pushTestDB(t)
	useRealRequests(t)
	aliceID, bobID := newTestUser(t), newTestUser(t)
	alice, bob := connect(t, aliceID), connect(t, bobID)

	id := "00000000-0000-0000-0000-0000000000a1"
	alice.send(t, chatFrame(bobID, id, nil))
	bob.read(t, "chat")
	waitFor(t, "the message to be stored", func() bool {
		var n int
		_ = db.QueryRow(context.Background(), `SELECT count(*) FROM messages WHERE id = $1::uuid`, id).Scan(&n)
		return n == 1
	})
	// The phone says it has it; while it is a request nobody is told.
	bob.send(t, map[string]interface{}{"type": "delivered", "message_ids": []string{id}})
	select {
	case m := <-alice.inbox:
		if m["type"] == "message_delivered" {
			t.Fatalf("alice was told about delivery of a request: %v", m)
		}
	case <-time.After(400 * time.Millisecond):
	}

	if ok, err := AcceptRequest(context.Background(), bobID, aliceID); err != nil || !ok {
		t.Fatalf("AcceptRequest = %v, %v", ok, err)
	}
	got := alice.read(t, "message_delivered")
	ids, _ := got["message_ids"].([]interface{})
	if len(ids) != 1 || ids[0] != id {
		t.Errorf("alice was told %v, want %s", got, id)
	}
}
