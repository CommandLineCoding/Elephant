package services

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"strings"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

// groupPosting says whether a user may post to a group. A variable so tests
// can run the hub without a database.
var groupPosting = func(ctx context.Context, groupID, userID string) (mayPost, isMember bool, err error) {
	return repository.NewGroupRepository().MayPost(ctx, groupID, userID)
}

// mayPostToGroup decides whether a chat event for a group is accepted. The
// sender must be a member. In an admins-only group a member's message is
// accepted only if it is an action (a reaction, a vote or a pin), which is not
// something anyone reads as a message. If it can't be checked, it is refused.
func mayPostToGroup(ctx context.Context, msg models.WSMessage) bool {
	mayPost, isMember, err := groupPosting(ctx, msg.GroupID, msg.SenderID)
	if err != nil {
		log.Printf("Group post refused, couldn't check membership: %v", err)
		return false
	}
	if !isMember {
		return false
	}
	return mayPost || isActionContent(msg.Content)
}

// actionMarker begins the hidden line a structured action message ends with
// (see "Structured messages" in docs/API_CONTRACTS.md).
const actionMarker = "[//]: # (elephant:v1:act:"

// actionKinds are the payloads that change a chat without being a message.
var actionKinds = map[string]bool{"reaction": true, "vote": true, "pin": true}

// isActionContent reports whether a group message's content is a valid action
// payload: the plaintext envelope's text ends with the hidden line, holding a
// JSON object whose kind is an action. It is as strict as the app, so a
// message that only looks like one is not let through.
func isActionContent(content string) bool {
	var env struct {
		Type       int    `json:"type"`
		Ciphertext string `json:"ciphertext"`
	}
	if err := json.Unmarshal([]byte(content), &env); err != nil || env.Type != 0 {
		return false
	}
	text := env.Ciphertext
	at := strings.LastIndex(text, actionMarker)
	if at == -1 || (at != 0 && text[at-1] != '\n') {
		return false
	}
	line := strings.TrimRight(text[at:], " \t\r\n")
	if !strings.HasSuffix(line, ")") || strings.Contains(line, "\n") {
		return false
	}
	blob := line[len(actionMarker) : len(line)-1]
	if blob == "" || len(blob) > 16*1024 {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(blob, "="))
	if err != nil {
		return false
	}
	var payload map[string]interface{}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return false
	}
	kind, _ := payload["kind"].(string)
	return actionKinds[kind]
}
