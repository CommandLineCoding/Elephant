package services

import (
	"context"
	"fmt"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
)

// A chat event is saved as a message, and the silent flag with it. (This was
// once a column short, and no message was stored at all.)
func TestStoreChatSavesTheMessageAndItsSilentFlag(t *testing.T) {
	db := pushTestDB(t)
	alice, bob := newTestUser(t), newTestUser(t)

	for _, silent := range []bool{false, true} {
		id := ""
		err := db.QueryRow(context.Background(), `SELECT gen_random_uuid()::text`).Scan(&id)
		if err != nil {
			t.Fatal(err)
		}
		msg := models.WSMessage{
			SenderID: alice, ReceiverID: bob, MessageID: id,
			Content: fmt.Sprintf("hello, silent=%v", silent), Silent: silent,
		}
		if err := storeChat(context.Background(), msg); err != nil {
			t.Fatalf("storing a message (silent=%v): %v", silent, err)
		}

		var content string
		var gotSilent bool
		err = config.DB.QueryRow(context.Background(),
			`SELECT content, silent FROM messages WHERE id = $1::uuid`, id).Scan(&content, &gotSilent)
		if err != nil {
			t.Fatalf("the message was not stored (silent=%v): %v", silent, err)
		}
		if content != msg.Content || gotSilent != silent {
			t.Errorf("stored %q silent=%v, want %q silent=%v", content, gotSilent, msg.Content, silent)
		}
	}
}

func TestStoreChatWithoutAnIDMakesOne(t *testing.T) {
	db := pushTestDB(t)
	alice, bob := newTestUser(t), newTestUser(t)
	if err := storeChat(context.Background(), models.WSMessage{SenderID: alice, ReceiverID: bob, Content: "no id"}); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := db.QueryRow(context.Background(),
		`SELECT count(*) FROM messages WHERE sender_id = $1::uuid AND content = 'no id'`, alice).Scan(&n); err != nil || n != 1 {
		t.Fatalf("stored %d messages (err %v), want 1", n, err)
	}
}
