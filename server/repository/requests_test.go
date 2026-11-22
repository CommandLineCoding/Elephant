package repository

import (
	"context"
	"testing"
)

func pending(t *testing.T, recipient, sender string) bool {
	t.Helper()
	got, err := NewRequestRepository().Pending(context.Background(), recipient, sender)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestAFirstMessageFromAStrangerIsARequest(t *testing.T) {
	ctx := context.Background()
	reqs := NewRequestRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")

	isReq, err := reqs.Open(ctx, bob, alice)
	if err != nil || !isReq {
		t.Fatalf("Open = %v, %v; want a request", isReq, err)
	}
	if !pending(t, bob, alice) {
		t.Error("no pending request for bob from alice")
	}
	if pending(t, alice, bob) {
		t.Error("alice has a request from bob, who never wrote")
	}

	// More messages before it is accepted stay part of it, even once the
	// first has been stored.
	if _, err := NewMessageRepository().CreateMessage(ctx, alice, bob, "hi", ""); err != nil {
		t.Fatal(err)
	}
	if isReq, err := reqs.Open(ctx, bob, alice); err != nil || !isReq {
		t.Errorf("a second message: Open = %v, %v; want still a request", isReq, err)
	}
}

func TestNoRequestWhenTheyHaveChattedOrShareAGroup(t *testing.T) {
	ctx := context.Background()
	reqs, messages, groups := NewRequestRepository(), NewMessageRepository(), NewGroupRepository()
	alice, bob, carol, dave, erin := contactTestUser(t, "alice"), contactTestUser(t, "bob"),
		contactTestUser(t, "carol"), contactTestUser(t, "dave"), contactTestUser(t, "erin")

	// bob once wrote to alice: that is an existing conversation, either way round.
	if _, err := messages.CreateMessage(ctx, bob, alice, "old", ""); err != nil {
		t.Fatal(err)
	}
	for _, c := range [][2]string{{alice, bob}, {bob, alice}} {
		if isReq, err := reqs.Open(ctx, c[0], c[1]); err != nil || isReq {
			t.Errorf("Open(%s, %s) = %v, %v; want an ordinary message", c[0], c[1], isReq, err)
		}
	}

	// carol and dave are in a group together.
	g, err := groups.Create(ctx, "club", carol)
	if err != nil {
		t.Fatal(err)
	}
	if err := groups.AddMember(ctx, g.ID, dave); err != nil {
		t.Fatal(err)
	}
	if isReq, err := reqs.Open(ctx, carol, dave); err != nil || isReq {
		t.Errorf("group mates: Open = %v, %v; want an ordinary message", isReq, err)
	}

	// erin has nothing in common with alice.
	if isReq, err := reqs.Open(ctx, alice, erin); err != nil || !isReq {
		t.Errorf("strangers: Open = %v, %v; want a request", isReq, err)
	}
}

func TestAcceptingEndsTheRequestAndOnlyThatOne(t *testing.T) {
	ctx := context.Background()
	reqs := NewRequestRepository()
	alice, bob, carol := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "carol")
	_, _ = reqs.Open(ctx, carol, alice)
	_, _ = reqs.Open(ctx, carol, bob)

	if ok, err := reqs.Accept(ctx, carol, alice); err != nil || !ok {
		t.Fatalf("Accept = %v, %v", ok, err)
	}
	if pending(t, carol, alice) || !pending(t, carol, bob) {
		t.Error("accepting alice's request must leave bob's")
	}
	if ok, _ := reqs.Accept(ctx, carol, alice); ok {
		t.Error("accepting twice reported a request")
	}
	// Someone else can't accept it for them: it is carol's to accept.
	if ok, _ := reqs.Accept(ctx, alice, carol); ok {
		t.Error("the sender accepted their own request")
	}
	// Once accepted and the message is stored, later ones are ordinary.
	if _, err := NewMessageRepository().CreateMessage(ctx, alice, carol, "hi", ""); err != nil {
		t.Fatal(err)
	}
	if isReq, err := reqs.Open(ctx, carol, alice); err != nil || isReq {
		t.Errorf("after accepting: Open = %v, %v; want an ordinary message", isReq, err)
	}
}

func TestTheConversationListFlagsRequests(t *testing.T) {
	ctx := context.Background()
	reqs, messages := NewRequestRepository(), NewMessageRepository()
	alice, bob, carol := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "carol")

	// alice (a stranger) writes to bob; carol and bob are old friends.
	if _, err := reqs.Open(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}
	if _, err := messages.CreateMessage(ctx, alice, bob, "hey", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := messages.CreateMessage(ctx, carol, bob, "hi", ""); err != nil {
		t.Fatal(err)
	}

	flags := func(user string) map[string]bool {
		list, err := messages.GetConversations(ctx, user)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, c := range list {
			out[c.ID] = c.IsRequest
		}
		return out
	}
	got := flags(bob)
	if !got[alice] || got[carol] {
		t.Errorf("bob's list: %v; want alice a request and carol not", got)
	}
	// It is the recipient's view only: alice's own list has an ordinary chat.
	if flags(alice)[bob] {
		t.Error("alice sees her own message as a request")
	}

	if _, err := reqs.Accept(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}
	if flags(bob)[alice] {
		t.Error("an accepted request is still flagged")
	}
}

func TestAPendingRequestIsNotAContactButAcceptedOnesAre(t *testing.T) {
	ctx := context.Background()
	reqs, messages, groups := NewRequestRepository(), NewMessageRepository(), NewGroupRepository()
	alice, bob, carol := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "carol")

	if _, err := reqs.Open(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}
	if _, err := messages.CreateMessage(ctx, alice, bob, "hey", ""); err != nil {
		t.Fatal(err)
	}
	// Neither can see the other's status while it is pending.
	if got := contactsOf(t, alice); len(got) != 0 {
		t.Errorf("alice's contacts %v; the person she wrote to hasn't accepted", got)
	}
	if got := contactsOf(t, bob); len(got) != 0 {
		t.Errorf("bob's contacts %v; he hasn't accepted alice", got)
	}

	// Sharing a group makes them contacts regardless.
	g, err := groups.Create(ctx, "club", alice)
	if err != nil {
		t.Fatal(err)
	}
	if err := groups.AddMember(ctx, g.ID, bob); err != nil {
		t.Fatal(err)
	}
	if got := contactsOf(t, bob); !equal(got, sorted(alice)) {
		t.Errorf("group mates: %v", got)
	}
	_ = carol
}

func TestAcceptedRequestBecomesAContact(t *testing.T) {
	ctx := context.Background()
	reqs, messages := NewRequestRepository(), NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	_, _ = reqs.Open(ctx, bob, alice)
	if _, err := messages.CreateMessage(ctx, alice, bob, "hey", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := reqs.Accept(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}
	if got := contactsOf(t, bob); !equal(got, sorted(alice)) {
		t.Errorf("bob's contacts after accepting: %v", got)
	}
	if got := contactsOf(t, alice); !equal(got, sorted(bob)) {
		t.Errorf("alice's contacts after being accepted: %v", got)
	}
}

func TestARequestIsNotAcknowledgedAsDelivered(t *testing.T) {
	ctx := context.Background()
	reqs, messages := NewRequestRepository(), NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	_, _ = reqs.Open(ctx, bob, alice)
	m, err := messages.CreateMessage(ctx, alice, bob, "hey", "")
	if err != nil {
		t.Fatal(err)
	}
	bySender, _, err := messages.MarkDelivered(ctx, bob, []string{m.ID})
	if err != nil || len(bySender) != 0 {
		t.Fatalf("MarkDelivered = %v, %v; want nothing while it is a request", bySender, err)
	}
	if _, err := reqs.Accept(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}
	bySender, _, err = messages.MarkDelivered(ctx, bob, []string{m.ID})
	if err != nil || len(bySender[alice]) != 1 {
		t.Fatalf("after accepting: %v, %v; want it delivered", bySender, err)
	}
}
