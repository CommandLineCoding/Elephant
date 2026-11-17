package services

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// The hub tests have no database: by default nobody can be woken by a push.
func init() {
	hasPushEndpoint = func(context.Context, string) bool { return false }
	notifyCall = func(string) {}
}

func setPushHooks(has func(context.Context, string) bool, notify func(string)) {
	pushHooksLock.Lock()
	defer pushHooksLock.Unlock()
	hasPushEndpoint, notifyCall = has, notify
}

// withPush lets the listed users be woken by a push. It returns the call
// pings sent so far.
func withPush(t *testing.T, users ...string) func() []string {
	t.Helper()
	var mu sync.Mutex
	pinged := []string{}
	oldHas, oldNotify := pushHooks()
	setPushHooks(func(_ context.Context, id string) bool {
		for _, u := range users {
			if u == id {
				return true
			}
		}
		return false
	}, func(id string) {
		mu.Lock()
		defer mu.Unlock()
		pinged = append(pinged, id)
	})
	t.Cleanup(func() { setPushHooks(oldHas, oldNotify) })
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), pinged...)
	}
}

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

func TestACallToAClosedAppRingsWhenItConnects(t *testing.T) {
	friends(t, "wake-alice", "wake-bob")
	pinged := withPush(t, "wake-bob")
	alice := connect(t, "wake-alice")

	offer(alice, t, "w1", "wake-bob", "sealed-offer")
	if m, ok := alice.got("call_hangup", 300*time.Millisecond); ok {
		t.Fatalf("the call ended although bob can be woken: %v", m)
	}
	if got := pinged(); len(got) != 1 || got[0] != "wake-bob" {
		t.Fatalf("pings sent: %v", got)
	}
	if id, from, ok := PendingCall("wake-bob"); !ok || id != "w1" || from != "wake-alice" {
		t.Errorf("pending call = %q %q %v", id, from, ok)
	}

	// The caller's candidates wait with the offer.
	for _, c := range []string{"cand-1", "cand-2"} {
		alice.send(t, map[string]interface{}{"type": "call_ice", "call_id": "w1", "content": c})
	}
	time.Sleep(50 * time.Millisecond)

	bob := connect(t, "wake-bob")
	if got := bob.read(t, "call_offer"); got["content"] != "sealed-offer" || got["sender_id"] != "wake-alice" {
		t.Fatalf("offer arrived as %v", got)
	}
	for _, want := range []string{"cand-1", "cand-2"} {
		if got := bob.read(t, "call_ice"); got["content"] != want {
			t.Errorf("candidate arrived as %v, want %s", got, want)
		}
	}

	// From here it's an ordinary call.
	bob.send(t, map[string]interface{}{"type": "call_ring", "call_id": "w1"})
	alice.read(t, "call_ring")
	alice.send(t, map[string]interface{}{"type": "call_ice", "call_id": "w1", "content": "cand-3"})
	if got := bob.read(t, "call_ice"); got["content"] != "cand-3" {
		t.Errorf("a later candidate arrived as %v", got)
	}
}

func TestAWaitingOfferIsDeliveredOnce(t *testing.T) {
	friends(t, "once-alice", "once-bob")
	withPush(t, "once-bob")
	alice := connect(t, "once-alice")
	offer(alice, t, "o1", "once-bob", "x")
	time.Sleep(50 * time.Millisecond)

	connect(t, "once-bob").read(t, "call_offer")
	again := connect(t, "once-bob") // the phone reconnects
	if m, ok := again.got("call_offer", 300*time.Millisecond); ok {
		t.Errorf("the offer was delivered twice: %v", m)
	}
}

func TestACallThatRangOutWhileTheAppWasClosedIsMissed(t *testing.T) {
	setCallTimes(t, 200*time.Millisecond, time.Second)
	friends(t, "miss-alice", "miss-bob")
	withPush(t, "miss-bob")
	alice := connect(t, "miss-alice")

	offer(alice, t, "m1", "miss-bob", "x")
	if got := alice.read(t, "call_hangup"); got["reason"] != "timeout" {
		t.Fatalf("caller was told %v", got)
	}
	if _, _, ok := PendingCall("miss-bob"); ok {
		t.Error("the call was still pending after it rang out")
	}

	bob := connect(t, "miss-bob")
	got := bob.read(t, "call_missed")
	if got["call_id"] != "m1" || got["sender_id"] != "miss-alice" || got["at"] == "" {
		t.Errorf("missed call arrived as %v", got)
	}
	if m, ok := bob.got("call_offer", 200*time.Millisecond); ok {
		t.Errorf("a missed call's offer was delivered: %v", m)
	}
	if m, ok := connect(t, "miss-bob").got("call_missed", 300*time.Millisecond); ok {
		t.Errorf("the missed call was reported twice: %v", m)
	}
}

func TestACallerGivingUpBeforeTheAppConnectsIsAMissedCall(t *testing.T) {
	friends(t, "gu-alice", "gu-bob")
	withPush(t, "gu-bob")
	alice := connect(t, "gu-alice")

	offer(alice, t, "g1", "gu-bob", "x")
	time.Sleep(50 * time.Millisecond)
	alice.send(t, map[string]interface{}{"type": "call_hangup", "call_id": "g1", "reason": "ended"})
	time.Sleep(50 * time.Millisecond)

	bob := connect(t, "gu-bob")
	if got := bob.read(t, "call_missed"); got["call_id"] != "g1" {
		t.Errorf("missed call arrived as %v", got)
	}
}

func TestSomeoneWithACallWaitingIsBusy(t *testing.T) {
	friends(t, "wb-alice", "wb-bob", "wb-carol")
	withPush(t, "wb-bob")
	alice := connect(t, "wb-alice")
	carol := connect(t, "wb-carol")

	offer(alice, t, "wb1", "wb-bob", "x")
	time.Sleep(50 * time.Millisecond)
	offer(carol, t, "wb2", "wb-bob", "x")
	carol.read(t, "call_busy")
}

func TestOnlyTheCalleeSeesAPendingCall(t *testing.T) {
	setCallTimes(t, time.Minute, time.Second)
	friends(t, "pc-alice", "pc-bob")
	setBlocks(t, [2]string{"pc-carol", "pc-alice"})
	alice := connect(t, "pc-alice")
	bob := connect(t, "pc-bob")

	offer(alice, t, "p1", "pc-bob", "x")
	bob.read(t, "call_offer")
	if _, _, ok := PendingCall("pc-alice"); ok {
		t.Error("the caller sees their own call as pending")
	}
	bob.send(t, map[string]interface{}{"type": "call_answer", "call_id": "p1", "content": "y"})
	alice.read(t, "call_answer")
	if _, _, ok := PendingCall("pc-bob"); ok {
		t.Error("an answered call is still pending")
	}
}
