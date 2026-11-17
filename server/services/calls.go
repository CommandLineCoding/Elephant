package services

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
)

// Call signalling. The hub relays the messages that set up a 1:1 call and
// keeps just enough state to enforce who may call whom, one call per person,
// and timeouts. The SDP and ICE candidates in `content` are encrypted by the
// app with the Signal session, so the server never reads them.

// Limits on the size of a WebSocket message. SDP needs more room than chat.
const (
	maxSignalSize  = 64 << 10
	maxMessageSize = 4096
)

// How long a call may ring, and how long a dropped connection gets to come
// back before its call ends. Variables so tests can shorten them.
var (
	callRingTimeout = 60 * time.Second
	callDropGrace   = 30 * time.Second
)

// Reasons a call ended, sent in call_hangup.
const (
	reasonEnded        = "ended"
	reasonDeclined     = "declined"
	reasonTimeout      = "timeout"
	reasonUnavailable  = "unavailable"
	reasonDisconnected = "disconnected"
)

type call struct {
	id     string
	caller string
	callee string

	answered bool
	// silent calls ring only for the caller: the callee has blocked them and
	// is never told. They end with a timeout like an unanswered call.
	silent bool

	ringTimer *time.Timer
	dropTimer *time.Timer
}

// other returns the person on the other end of the call from userID.
func (cl *call) other(userID string) string {
	if strings.EqualFold(userID, cl.caller) {
		return cl.callee
	}
	return cl.caller
}

func (cl *call) has(userID string) bool {
	return strings.EqualFold(userID, cl.caller) || strings.EqualFold(userID, cl.callee)
}

type callTable struct {
	mu     sync.Mutex
	byID   map[string]*call
	byUser map[string]*call // lowercased user ID
}

var calls = &callTable{
	byID:   make(map[string]*call),
	byUser: make(map[string]*call),
}

func (t *callTable) forUser(userID string) *call {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.byUser[strings.ToLower(userID)]
}

// start records a new call, unless either person is already in one.
func (t *callTable) start(cl *call) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.byID[cl.id]; ok {
		return false
	}
	if t.byUser[strings.ToLower(cl.caller)] != nil {
		return false
	}
	// A silent call doesn't involve the callee, so it doesn't make them busy.
	if !cl.silent && t.byUser[strings.ToLower(cl.callee)] != nil {
		return false
	}
	t.byID[cl.id] = cl
	t.byUser[strings.ToLower(cl.caller)] = cl
	if !cl.silent {
		t.byUser[strings.ToLower(cl.callee)] = cl
	}
	cl.ringTimer = time.AfterFunc(callRingTimeout, func() { t.ringTimedOut(cl) })
	return true
}

// lookup returns the call with this ID if userID is in it.
func (t *callTable) lookup(callID, userID string) *call {
	t.mu.Lock()
	defer t.mu.Unlock()
	cl := t.byID[callID]
	if cl == nil || !cl.has(userID) {
		return nil
	}
	return cl
}

// end removes the call and reports whether it was still going, so only one
// of several racing endings (hang up, timeout, drop) tells anyone.
func (t *callTable) end(cl *call) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.byID[cl.id] != cl {
		return false
	}
	delete(t.byID, cl.id)
	for _, id := range []string{cl.caller, cl.callee} {
		if t.byUser[strings.ToLower(id)] == cl {
			delete(t.byUser, strings.ToLower(id))
		}
	}
	cl.ringTimer.Stop()
	if cl.dropTimer != nil {
		cl.dropTimer.Stop()
	}
	return true
}

// answer marks the call as answered by the callee. It reports false if the
// call is already answered, or if userID isn't the callee.
func (t *callTable) answer(cl *call, userID string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if cl.answered || cl.silent || !strings.EqualFold(userID, cl.callee) || t.byID[cl.id] != cl {
		return false
	}
	cl.answered = true
	cl.ringTimer.Stop()
	return true
}

func (t *callTable) ringTimedOut(cl *call) {
	t.mu.Lock()
	answered := cl.answered
	t.mu.Unlock()
	if answered || !t.end(cl) {
		return
	}
	sendCallEvent(cl.caller, "call_hangup", cl.id, "", "", reasonTimeout)
	if !cl.silent {
		sendCallEvent(cl.callee, "call_hangup", cl.id, "", "", reasonTimeout)
	}
}

// dropped is called when a user's last connection closes. An unanswered call
// ends at once. An answered one is given callDropGrace to reconnect, since
// a phone switching networks drops its WebSocket while the call's audio,
// which doesn't go through the server, may carry on.
func (t *callTable) dropped(userID string) {
	cl := t.forUser(userID)
	if cl == nil {
		return
	}
	if cl.silent {
		// The callee doesn't know about this call, and the caller mustn't
		// learn anything about the callee from it.
		if strings.EqualFold(userID, cl.caller) {
			t.end(cl)
		}
		return
	}

	t.mu.Lock()
	answered := cl.answered
	if answered {
		if cl.dropTimer != nil {
			cl.dropTimer.Stop()
		}
		cl.dropTimer = time.AfterFunc(callDropGrace, func() {
			if Hub.IsOnline(userID) || !t.end(cl) {
				return
			}
			sendCallEvent(cl.other(userID), "call_hangup", cl.id, "", "", reasonDisconnected)
		})
	}
	t.mu.Unlock()

	if !answered && t.end(cl) {
		sendCallEvent(cl.other(userID), "call_hangup", cl.id, "", "", reasonDisconnected)
	}
}

func sendCallEvent(to, msgType, callID, from, content, reason string) bool {
	msg := map[string]string{"type": msgType, "call_id": callID}
	if from != "" {
		msg["sender_id"] = from
	}
	if content != "" {
		msg["content"] = content
	}
	if reason != "" {
		msg["reason"] = reason
	}
	b, _ := json.Marshal(msg)
	return Hub.sendToUser(to, b)
}

// isCallSignal reports whether a message type may use the larger size limit.
func isCallSignal(msgType string) bool {
	switch msgType {
	case "call_offer", "call_answer", "call_ice":
		return true
	}
	return false
}

// handleCallMessage relays one call message from c. It reports false if the
// message isn't about calls.
func handleCallMessage(c *WSClient, in models.WSMessage) bool {
	switch in.Type {
	case "call_offer":
		startCall(c, in)
	case "call_ring":
		if cl := calls.lookup(in.CallID, c.UserID); cl != nil && !cl.silent && !cl.answered && strings.EqualFold(c.UserID, cl.callee) {
			sendCallEvent(cl.caller, "call_ring", cl.id, c.UserID, "", "")
		}
	case "call_answer":
		if cl := calls.lookup(in.CallID, c.UserID); cl != nil && calls.answer(cl, c.UserID) {
			sendCallEvent(cl.caller, "call_answer", cl.id, c.UserID, in.Content, "")
		}
	case "call_ice":
		if cl := calls.lookup(in.CallID, c.UserID); cl != nil && !cl.silent {
			sendCallEvent(cl.other(c.UserID), "call_ice", cl.id, c.UserID, in.Content, "")
		}
	case "call_hangup":
		cl := calls.lookup(in.CallID, c.UserID)
		if cl == nil || !calls.end(cl) {
			return true
		}
		reason := reasonEnded
		if in.Reason == reasonDeclined && !cl.answered && strings.EqualFold(c.UserID, cl.callee) {
			reason = reasonDeclined
		}
		if !cl.silent {
			sendCallEvent(cl.other(c.UserID), "call_hangup", cl.id, c.UserID, "", reason)
		}
	default:
		return false
	}
	return true
}

func startCall(c *WSClient, in models.WSMessage) {
	callee := in.ReceiverID
	unavailable := func() { sendCallEvent(c.UserID, "call_hangup", in.CallID, "", "", reasonUnavailable) }

	if in.CallID == "" || len(in.CallID) > 64 || callee == "" || strings.EqualFold(callee, c.UserID) {
		unavailable()
		return
	}
	// Only people who share a chat or a group, and not someone you've blocked.
	ctx := context.Background()
	if !Hub.canSeeStatus(c, callee) || blockedBy(ctx, c.UserID, callee) {
		unavailable()
		return
	}
	if calls.forUser(c.UserID) != nil {
		unavailable()
		return
	}

	cl := &call{id: in.CallID, caller: c.UserID, callee: callee}

	// If the callee has blocked the caller, it rings for the caller only and
	// times out, so they can't tell they were blocked.
	if blockedBy(ctx, callee, c.UserID) {
		cl.silent = true
		if !calls.start(cl) {
			unavailable()
		}
		return
	}
	if calls.forUser(callee) != nil {
		sendCallEvent(c.UserID, "call_busy", in.CallID, callee, "", "")
		return
	}
	if !Hub.IsOnline(callee) || !calls.start(cl) {
		unavailable()
		return
	}
	if !sendCallEvent(callee, "call_offer", cl.id, c.UserID, in.Content, "") {
		calls.end(cl)
		unavailable()
	}
}
