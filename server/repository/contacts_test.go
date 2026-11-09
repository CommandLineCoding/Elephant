package repository

import (
	"context"
	"fmt"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

var contactSeq int64

func contactTestUser(t *testing.T, name string) string {
	t.Helper()
	var id string
	// usernames are limited to 30 characters
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash) VALUES ($1, $2, 'x') RETURNING id::text`,
		fmt.Sprintf("ct.%s.%d.%d", name, time.Now().UnixNano()%1_000_000, atomic.AddInt64(&contactSeq, 1)), name).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

func contactsOf(t *testing.T, id string) []string {
	t.Helper()
	got, err := NewContactRepository().GetContactIDs(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(got)
	return got
}

func sorted(ids ...string) []string {
	sort.Strings(ids)
	return ids
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestContactsAreDirectMessagePartnersAndGroupMates(t *testing.T) {
	ctx := context.Background()
	messages, groups := NewMessageRepository(), NewGroupRepository()

	alice, bob, carol := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "carol")
	dave, erin, frank := contactTestUser(t, "dave"), contactTestUser(t, "erin"), contactTestUser(t, "frank")

	// alice -> bob, and carol -> alice: contacts in either direction.
	if _, err := messages.CreateMessage(ctx, alice, bob, "hi", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := messages.CreateMessage(ctx, carol, alice, "hello", ""); err != nil {
		t.Fatal(err)
	}

	// alice and erin share a group; dave is alone in another one.
	shared, err := groups.Create(ctx, "shared", alice)
	if err != nil {
		t.Fatal(err)
	}
	if err := groups.AddMember(ctx, shared.ID, erin); err != nil {
		t.Fatal(err)
	}
	if _, err := groups.Create(ctx, "solo", dave); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name string
		user string
		want []string
	}{
		{"alice: bob (sent to), carol (received from), erin (group)", alice, sorted(bob, carol, erin)},
		{"bob: alice, who messaged them", bob, sorted(alice)},
		{"carol: alice, whom they messaged", carol, sorted(alice)},
		{"erin: alice, from the group", erin, sorted(alice)},
		{"dave: nobody, a group of one is not a contact", dave, nil},
		{"frank: a stranger to everyone", frank, nil},
	}
	for _, c := range cases {
		if got := contactsOf(t, c.user); !equal(got, c.want) {
			t.Errorf("%s:\n  got  %v\n  want %v", c.name, got, c.want)
		}
	}
}

// Posting in a group doesn't make you a direct contact of its members; being
// in the group already does.
func TestGroupMessagesDoNotCreateDirectContacts(t *testing.T) {
	ctx := context.Background()
	alice, bob, outsider := contactTestUser(t, "alice"), contactTestUser(t, "bob"), contactTestUser(t, "outsider")

	group, err := NewGroupRepository().Create(ctx, "club", alice)
	if err != nil {
		t.Fatal(err)
	}
	if err := NewGroupRepository().AddMember(ctx, group.ID, bob); err != nil {
		t.Fatal(err)
	}
	if _, err := config.DB.Exec(ctx,
		`INSERT INTO messages (sender_id, group_id, content) VALUES ($1::uuid, $2::uuid, 'to the group')`, alice, group.ID); err != nil {
		t.Fatal(err)
	}

	if got := contactsOf(t, alice); !equal(got, sorted(bob)) {
		t.Errorf("alice should know only bob, got %v", got)
	}
	if got := contactsOf(t, outsider); len(got) != 0 {
		t.Errorf("someone outside the group must not be a contact, got %v", got)
	}
}
