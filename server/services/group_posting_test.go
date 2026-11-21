package services

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

// envelope wraps text as a group message's content, the way the app does.
func envelope(text string) string {
	b, _ := json.Marshal(map[string]interface{}{"type": 0, "ciphertext": text})
	return string(b)
}

func actionLine(kind string) string {
	raw, _ := json.Marshal(map[string]interface{}{"kind": kind, "target": "m1"})
	return actionMarker + base64.RawURLEncoding.EncodeToString(raw) + ")"
}

func TestWhatCountsAsAnAction(t *testing.T) {
	good := map[string]string{
		"a reaction":            envelope("👍 Reacted to a message\n\n" + actionLine("reaction")),
		"a vote":                envelope("🗳️ Voted\n\n" + actionLine("vote")),
		"a pin":                 envelope(actionLine("pin")),
		"with a trailing space": envelope("x\n\n" + actionLine("reaction") + "  \n"),
	}
	for name, content := range good {
		if !isActionContent(content) {
			t.Errorf("%s should be an action", name)
		}
	}

	notActions := map[string]string{
		"plain text":                 envelope("hello"),
		"a poll, which is a message": envelope("📊 Poll\n\n" + actionLine("poll")),
		"an unknown kind":            envelope("x\n\n" + actionLine("announcement")),
		"the marker inside a line":   envelope("look: " + actionLine("reaction")),
		"text after the line":        envelope(actionLine("reaction") + "\nand more"),
		"not base64":                 envelope("x\n\n" + actionMarker + "***)"),
		"not JSON":                   envelope("x\n\n" + actionMarker + base64.RawURLEncoding.EncodeToString([]byte("nope")) + ")"),
		"JSON that is not an object": envelope("x\n\n" + actionMarker + base64.RawURLEncoding.EncodeToString([]byte("[1]")) + ")"),
		"an empty payload":           envelope("x\n\n" + actionMarker + ")"),
		"an oversized payload":       envelope("x\n\n" + actionMarker + strings.Repeat("A", 17*1024) + ")"),
		"no closing bracket":         envelope("x\n\n" + strings.TrimSuffix(actionLine("reaction"), ")")),
		"not an envelope":            "just text",
		"an encrypted envelope":      `{"type":3,"ciphertext":"` + strings.ReplaceAll(actionLine("reaction"), `"`, `\"`) + `"}`,
		"nothing":                    "",
	}
	for name, content := range notActions {
		if isActionContent(content) {
			t.Errorf("%s must not count as an action", name)
		}
	}
}

func stubGroupPosting(t *testing.T, mayPost, isMember bool, err error) {
	t.Helper()
	old := groupPosting
	groupPosting = func(context.Context, string, string) (bool, bool, error) { return mayPost, isMember, err }
	t.Cleanup(func() { groupPosting = old })
}

func TestTheRuleForPostingToAGroup(t *testing.T) {
	text := models.WSMessage{GroupID: "g", SenderID: "u", Content: envelope("hello")}
	react := models.WSMessage{GroupID: "g", SenderID: "u", Content: envelope("👍\n\n" + actionLine("reaction")), Silent: true}

	cases := []struct {
		name            string
		mayPost, member bool
		err             error
		msg             models.WSMessage
		want            bool
	}{
		{"a member of an ordinary group", true, true, nil, text, true},
		{"someone who is not in the group", false, false, nil, text, false},
		{"someone not in the group, even reacting", false, false, nil, react, false},
		{"a member of an admins-only group sending text", false, true, nil, text, false},
		{"a member of an admins-only group reacting", false, true, nil, react, true},
		{"text pretending to be silent", false, true, nil, models.WSMessage{GroupID: "g", SenderID: "u", Content: envelope("hello"), Silent: true}, false},
		{"when it can't be checked", true, true, errors.New("database is down"), text, false},
	}
	for _, c := range cases {
		stubGroupPosting(t, c.mayPost, c.member, c.err)
		if got := mayPostToGroup(context.Background(), c.msg); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

// With a real group, an admins-only group delivers an admin's message and a
// member's reaction, and drops a member's message.
func TestAdminsOnlyGroupOverTheWire(t *testing.T) {
	db := pushTestDB(t)
	old := groupPosting
	groupPosting = func(ctx context.Context, g, u string) (bool, bool, error) {
		return repository.NewGroupRepository().MayPost(ctx, g, u)
	}
	t.Cleanup(func() { groupPosting = old })

	adminID, memberID, outsiderID := newTestUser(t), newTestUser(t), newTestUser(t)
	group, err := repository.NewGroupRepository().Create(context.Background(), "Announcements", adminID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(context.Background(), "DELETE FROM groups WHERE id = $1::uuid", group.ID) })
	if err := repository.NewGroupRepository().AddMember(context.Background(), group.ID, memberID); err != nil {
		t.Fatal(err)
	}
	adminsOnly := true
	if _, err := repository.NewGroupRepository().Update(context.Background(), group.ID, repository.GroupChanges{AdminsOnly: &adminsOnly}); err != nil {
		t.Fatal(err)
	}

	admin, member, outsider := connect(t, adminID), connect(t, memberID), connect(t, outsiderID)
	send := func(from *testClient, id, content string, silent bool) {
		from.send(t, map[string]interface{}{
			"type": "chat", "group_id": group.ID, "message_id": id, "content": content, "silent": silent,
		})
	}
	got := func(c *testClient, id string) bool {
		timeout := time.After(700 * time.Millisecond)
		for {
			select {
			case m, ok := <-c.inbox:
				if !ok {
					return false
				}
				if m["type"] == "chat" && m["message_id"] == id {
					return true
				}
			case <-timeout:
				return false
			}
		}
	}

	send(member, "00000000-0000-0000-0000-0000000000a1", envelope("can I post?"), false)
	if got(admin, "00000000-0000-0000-0000-0000000000a1") {
		t.Error("a member's message reached the admin of an admins-only group")
	}
	send(outsider, "00000000-0000-0000-0000-0000000000a2", envelope("let me in"), false)
	if got(admin, "00000000-0000-0000-0000-0000000000a2") {
		t.Error("a message from someone outside the group was delivered")
	}
	send(member, "00000000-0000-0000-0000-0000000000a3", envelope("👍\n\n"+actionLine("reaction")), true)
	if !got(admin, "00000000-0000-0000-0000-0000000000a3") {
		t.Error("a member's reaction was not delivered")
	}
	send(admin, "00000000-0000-0000-0000-0000000000a4", envelope("Meeting at 5"), false)
	if !got(member, "00000000-0000-0000-0000-0000000000a4") {
		t.Error("an admin's message did not reach the member")
	}

	// Changing the group tells its members to load the new details, and only them.
	Hub.GroupUpdated(group.ID)
	for name, c := range map[string]*testClient{"the admin": admin, "the member": member} {
		if m := c.read(t, "group_updated"); m["group_id"] != group.ID {
			t.Errorf("%s was told about group %v", name, m["group_id"])
		}
	}
	select {
	case m := <-outsider.inbox:
		if m["type"] == "group_updated" {
			t.Error("someone outside the group was told it changed")
		}
	case <-time.After(300 * time.Millisecond):
	}

	// Turned off, members post again.
	off := false
	if _, err := repository.NewGroupRepository().Update(context.Background(), group.ID, repository.GroupChanges{AdminsOnly: &off}); err != nil {
		t.Fatal(err)
	}
	send(member, "00000000-0000-0000-0000-0000000000a5", envelope("thanks"), false)
	if !got(admin, "00000000-0000-0000-0000-0000000000a5") {
		t.Error("a member could not post after admins-only was turned off")
	}
}
