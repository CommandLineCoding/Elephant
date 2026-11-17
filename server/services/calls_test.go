package services

import (
	"strings"
	"testing"
	"time"
)

// setCallTimes shortens the ring timeout and the reconnect grace for one test.
func setCallTimes(t *testing.T, ring, grace time.Duration) {
	t.Helper()
	oldRing, oldGrace := callRingTimeout, callDropGrace
	callRingTimeout, callDropGrace = ring, grace
	t.Cleanup(func() { callRingTimeout, callDropGrace = oldRing, oldGrace })
}

// friends makes every listed user a contact of every other.
func friends(t *testing.T, ids ...string) {
	book := map[string][]string{}
	for _, a := range ids {
		for _, b := range ids {
			if a != b {
				book[a] = append(book[a], b)
			}
		}
	}
	setContacts(t, book)
}

// endCall makes sure a test's call doesn't outlive it and make someone busy.
func endCall(t *testing.T, id string) {
	t.Cleanup(func() {
		if cl := calls.lookupAny(id); cl != nil {
			calls.end(cl)
		}
	})
}

func (t *callTable) lookupAny(id string) *call {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.byID[id]
}

// got waits up to wait for a message of the given type, without failing.
func (tc *testClient) got(msgType string, wait time.Duration) (map[string]interface{}, bool) {
	timeout := time.After(wait)
	for {
		select {
		case m, ok := <-tc.inbox:
			if !ok {
				return nil, false
			}
			if m["type"] == msgType {
				return m, true
			}
		case <-timeout:
			return nil, false
		}
	}
}

// gotAny waits up to wait for a message of any of the given types.
func (tc *testClient) gotAny(types []string, wait time.Duration) (map[string]interface{}, bool) {
	timeout := time.After(wait)
	for {
		select {
		case m, ok := <-tc.inbox:
			if !ok {
				return nil, false
			}
			for _, typ := range types {
				if m["type"] == typ {
					return m, true
				}
			}
		case <-timeout:
			return nil, false
		}
	}
}

func offer(tc *testClient, t *testing.T, callID, to, content string) {
	endCall(t, callID)
	tc.send(t, map[string]interface{}{"type": "call_offer", "call_id": callID, "receiver_id": to, "content": content})
}

func TestACallIsRelayedBetweenThePeopleInIt(t *testing.T) {
	friends(t, "call-alice", "call-bob")
	alice := connect(t, "call-alice")
	bob := connect(t, "call-bob")

	offer(alice, t, "c1", "call-bob", "sealed-offer")
	got := bob.read(t, "call_offer")
	if got["call_id"] != "c1" || got["sender_id"] != "call-alice" || got["content"] != "sealed-offer" {
		t.Fatalf("offer arrived as %v", got)
	}

	bob.send(t, map[string]interface{}{"type": "call_ring", "call_id": "c1"})
	if got := alice.read(t, "call_ring"); got["sender_id"] != "call-bob" {
		t.Errorf("ring arrived as %v", got)
	}

	alice.send(t, map[string]interface{}{"type": "call_ice", "call_id": "c1", "content": "alice-candidate"})
	if got := bob.read(t, "call_ice"); got["content"] != "alice-candidate" {
		t.Errorf("caller's candidate arrived as %v", got)
	}

	bob.send(t, map[string]interface{}{"type": "call_answer", "call_id": "c1", "content": "sealed-answer"})
	if got := alice.read(t, "call_answer"); got["content"] != "sealed-answer" {
		t.Errorf("answer arrived as %v", got)
	}

	bob.send(t, map[string]interface{}{"type": "call_ice", "call_id": "c1", "content": "bob-candidate"})
	if got := alice.read(t, "call_ice"); got["content"] != "bob-candidate" {
		t.Errorf("callee's candidate arrived as %v", got)
	}

	bob.send(t, map[string]interface{}{"type": "call_hangup", "call_id": "c1", "reason": "ended"})
	if got := alice.read(t, "call_hangup"); got["reason"] != "ended" {
		t.Errorf("hang up arrived as %v", got)
	}
	if calls.forUser("call-alice") != nil || calls.forUser("call-bob") != nil {
		t.Error("the call was still recorded after hanging up")
	}
}

func TestSDPLargerThanAChatMessageGetsThrough(t *testing.T) {
	friends(t, "big-alice", "big-bob")
	alice := connect(t, "big-alice")
	bob := connect(t, "big-bob")

	sdp := strings.Repeat("a", 20<<10)
	offer(alice, t, "big1", "big-bob", sdp)
	if got := bob.read(t, "call_offer"); got["content"] != sdp {
		t.Fatal("a 20 KB offer didn't arrive intact")
	}

	// Anything else over 4 KB is dropped, and the connection stays up.
	alice.send(t, map[string]interface{}{"type": "typing", "receiver_id": "big-bob", "content": sdp})
	if _, ok := bob.got("typing", 300*time.Millisecond); ok {
		t.Error("a typing message over 4 KB was relayed")
	}
	alice.send(t, map[string]interface{}{"type": "typing", "receiver_id": "big-bob"})
	if _, ok := bob.got("typing", 3*time.Second); !ok {
		t.Error("the connection stopped working after an oversized message")
	}
}

func TestStrangersCantCall(t *testing.T) {
	friends(t) // nobody knows anybody
	eve := connect(t, "stranger-eve")
	bob := connect(t, "stranger-bob")

	offer(eve, t, "s1", "stranger-bob", "x")
	if got := eve.read(t, "call_hangup"); got["reason"] != "unavailable" {
		t.Errorf("stranger was told %v", got)
	}
	if _, ok := bob.got("call_offer", 300*time.Millisecond); ok {
		t.Error("a stranger's call reached bob")
	}
}

func TestCallingSomeoneOfflineEndsAtOnce(t *testing.T) {
	friends(t, "away-alice", "away-bob")
	alice := connect(t, "away-alice")

	offer(alice, t, "o1", "away-bob", "x")
	if got := alice.read(t, "call_hangup"); got["reason"] != "unavailable" {
		t.Errorf("caller was told %v", got)
	}
	if calls.forUser("away-alice") != nil {
		t.Error("the caller was left in a call")
	}
}

func TestCallingSomeoneInACallIsBusy(t *testing.T) {
	friends(t, "busy-alice", "busy-bob", "busy-carol")
	alice := connect(t, "busy-alice")
	bob := connect(t, "busy-bob")
	carol := connect(t, "busy-carol")

	offer(alice, t, "b1", "busy-bob", "x")
	bob.read(t, "call_offer")

	offer(carol, t, "b2", "busy-bob", "x")
	if got := carol.read(t, "call_busy"); got["call_id"] != "b2" {
		t.Errorf("busy arrived as %v", got)
	}
	if _, ok := bob.got("call_offer", 300*time.Millisecond); ok {
		t.Error("a second call reached someone already in a call")
	}

	// Calling someone else while you're in a call is refused too.
	offer(alice, t, "b3", "busy-carol", "x")
	if got := alice.read(t, "call_hangup"); got["call_id"] != "b3" || got["reason"] != "unavailable" {
		t.Errorf("second outgoing call got %v", got)
	}
}

func TestBlockedCallerJustHearsRinging(t *testing.T) {
	setCallTimes(t, 300*time.Millisecond, time.Second)
	friends(t, "bc-alice", "bc-bob", "bc-carol")
	setBlocks(t, [2]string{"bc-bob", "bc-alice"}) // bob blocked alice
	alice := connect(t, "bc-alice")
	bob := connect(t, "bc-bob")
	carol := connect(t, "bc-carol")

	offer(alice, t, "bl1", "bc-bob", "x")
	if _, ok := bob.got("call_offer", 200*time.Millisecond); ok {
		t.Fatal("a call from someone bob blocked reached him")
	}

	// Bob isn't made busy by a call he never heard about.
	offer(carol, t, "bl2", "bc-bob", "x")
	bob.read(t, "call_offer")

	// Alice's call ends like any unanswered call.
	if got := alice.read(t, "call_hangup"); got["call_id"] != "bl1" || got["reason"] != "timeout" {
		t.Errorf("blocked caller was told %v", got)
	}
}

func TestYouCantCallSomeoneYouBlocked(t *testing.T) {
	friends(t, "yb-alice", "yb-bob")
	setBlocks(t, [2]string{"yb-alice", "yb-bob"}) // alice blocked bob
	alice := connect(t, "yb-alice")
	bob := connect(t, "yb-bob")

	offer(alice, t, "yb1", "yb-bob", "x")
	if got := alice.read(t, "call_hangup"); got["reason"] != "unavailable" {
		t.Errorf("caller was told %v", got)
	}
	if _, ok := bob.got("call_offer", 300*time.Millisecond); ok {
		t.Error("a call to someone alice blocked went through")
	}
}

func TestUnansweredCallTimesOut(t *testing.T) {
	setCallTimes(t, 200*time.Millisecond, time.Second)
	friends(t, "to-alice", "to-bob")
	alice := connect(t, "to-alice")
	bob := connect(t, "to-bob")

	offer(alice, t, "t1", "to-bob", "x")
	bob.read(t, "call_offer")
	for _, tc := range []*testClient{alice, bob} {
		if got := tc.read(t, "call_hangup"); got["reason"] != "timeout" {
			t.Errorf("%s was told %v", tc.srv.UserID, got)
		}
	}
}

func TestAnsweredCallDoesNotTimeOut(t *testing.T) {
	setCallTimes(t, 200*time.Millisecond, time.Second)
	friends(t, "ans-alice", "ans-bob")
	alice := connect(t, "ans-alice")
	bob := connect(t, "ans-bob")

	offer(alice, t, "a1", "ans-bob", "x")
	bob.read(t, "call_offer")
	bob.send(t, map[string]interface{}{"type": "call_answer", "call_id": "a1", "content": "y"})
	alice.read(t, "call_answer")

	if m, ok := alice.got("call_hangup", 500*time.Millisecond); ok {
		t.Errorf("an answered call ended: %v", m)
	}
}

func TestDecliningTellsTheCaller(t *testing.T) {
	friends(t, "dec-alice", "dec-bob")
	alice := connect(t, "dec-alice")
	bob := connect(t, "dec-bob")

	offer(alice, t, "d1", "dec-bob", "x")
	bob.read(t, "call_offer")
	bob.send(t, map[string]interface{}{"type": "call_hangup", "call_id": "d1", "reason": "declined"})
	if got := alice.read(t, "call_hangup"); got["reason"] != "declined" {
		t.Errorf("caller was told %v", got)
	}
}

func TestOutsidersCantJoinACall(t *testing.T) {
	friends(t, "out-alice", "out-bob", "out-eve")
	alice := connect(t, "out-alice")
	bob := connect(t, "out-bob")
	eve := connect(t, "out-eve")

	offer(alice, t, "x1", "out-bob", "x")
	bob.read(t, "call_offer")

	for _, msg := range []string{"call_answer", "call_ice", "call_hangup"} {
		eve.send(t, map[string]interface{}{"type": msg, "call_id": "x1", "content": "evil"})
	}
	for _, tc := range []*testClient{alice, bob} {
		if m, ok := tc.gotAny([]string{"call_answer", "call_ice", "call_hangup"}, 300*time.Millisecond); ok {
			t.Errorf("%s got a message from an outsider: %v", tc.srv.UserID, m)
		}
	}
	if calls.forUser("out-alice") == nil {
		t.Error("an outsider ended the call")
	}

	// The caller can't answer their own call either.
	alice.send(t, map[string]interface{}{"type": "call_answer", "call_id": "x1", "content": "self"})
	if _, ok := alice.got("call_answer", 200*time.Millisecond); ok {
		t.Error("the caller answered their own call")
	}
}

func TestADroppedConnectionEndsTheCallUnlessItComesBack(t *testing.T) {
	setCallTimes(t, time.Minute, 300*time.Millisecond)
	friends(t, "drop-alice", "drop-bob")
	alice := connect(t, "drop-alice")
	bob := connect(t, "drop-bob")

	offer(alice, t, "dr1", "drop-bob", "x")
	bob.read(t, "call_offer")
	bob.send(t, map[string]interface{}{"type": "call_answer", "call_id": "dr1", "content": "y"})
	alice.read(t, "call_answer")

	// Bob's phone switches networks and reconnects in time: the call goes on.
	_ = bob.phone.Close()
	<-bob.readDone
	bob2 := connect(t, "drop-bob")
	if m, ok := alice.got("call_hangup", 600*time.Millisecond); ok {
		t.Fatalf("the call ended although bob came back: %v", m)
	}

	// Alice drops and doesn't come back.
	_ = alice.phone.Close()
	if got := bob2.read(t, "call_hangup"); got["reason"] != "disconnected" {
		t.Errorf("bob was told %v", got)
	}
	if calls.forUser("drop-bob") != nil {
		t.Error("the call was still recorded")
	}
}

func TestARingingCallEndsWhenTheCallerDrops(t *testing.T) {
	friends(t, "rd-alice", "rd-bob")
	alice := connect(t, "rd-alice")
	bob := connect(t, "rd-bob")

	offer(alice, t, "rd1", "rd-bob", "x")
	bob.read(t, "call_offer")
	_ = alice.phone.Close()
	if got := bob.read(t, "call_hangup"); got["reason"] != "disconnected" {
		t.Errorf("callee was told %v", got)
	}
}
