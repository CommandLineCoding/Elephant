package repository

import (
	"context"
	"testing"
	"time"
)

func setSettings(t *testing.T, user string, p UserSettingsPatch) UserSettings {
	t.Helper()
	s, err := NewUserSettingsRepository().Update(context.Background(), user, p)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSettingsStartAtTheDefaults(t *testing.T) {
	alice := contactTestUser(t, "alice")
	got, err := NewUserSettingsRepository().Get(context.Background(), alice)
	if err != nil {
		t.Fatal(err)
	}
	if got != DefaultUserSettings() {
		t.Errorf("a new person has %+v, want the defaults %+v", got, DefaultUserSettings())
	}
}

func TestSettingsPatchChangesOnlyWhatIsSent(t *testing.T) {
	alice := contactTestUser(t, "alice")
	nobody, off := AudienceNobody, false

	got := setSettings(t, alice, UserSettingsPatch{OnlineStatus: &nobody})
	want := DefaultUserSettings()
	want.OnlineStatus = AudienceNobody
	if got != want {
		t.Fatalf("after hiding status: %+v, want %+v", got, want)
	}

	got = setSettings(t, alice, UserSettingsPatch{ReadReceipts: &off})
	want.ReadReceipts = false
	if got != want {
		t.Fatalf("after turning receipts off: %+v, want %+v (status must stay hidden)", got, want)
	}

	again, _ := NewUserSettingsRepository().Get(context.Background(), alice)
	if again != want {
		t.Errorf("saved %+v, want %+v", again, want)
	}
}

func TestSettingsRejectValuesTheDatabaseDoesNotKnow(t *testing.T) {
	alice := contactTestUser(t, "alice")
	bad := "friends-of-friends"
	if _, err := NewUserSettingsRepository().Update(context.Background(), alice, UserSettingsPatch{GroupAdds: &bad}); err == nil {
		t.Error("an unknown audience was stored")
	}
}

func TestOnePersonsSettingsDoNotChangeAnothers(t *testing.T) {
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	nobody := AudienceNobody
	setSettings(t, alice, UserSettingsPatch{GroupAdds: &nobody})
	got, _ := NewUserSettingsRepository().Get(context.Background(), bob)
	if got != DefaultUserSettings() {
		t.Errorf("bob has %+v", got)
	}
}

// A sender must not learn that a message was read if the reader turned read
// receipts off, in the history or in the chat list. The reader still sees
// their own state.
func TestReadStateIsHiddenFromTheSenderWhenReceiptsAreOff(t *testing.T) {
	ctx := context.Background()
	repo := NewMessageRepository()
	alice, bob := contactTestUser(t, "alice"), contactTestUser(t, "bob")
	past := time.Now().Add(-time.Minute)
	id := sendMsg(t, alice, bob, "did you see this?", past)
	if err := repo.MarkAsRead(ctx, bob, alice); err != nil {
		t.Fatal(err)
	}

	readByAlice := func() (history, chatList bool) {
		msgs, err := repo.GetChatHistory(ctx, alice, bob, time.Now().Add(time.Hour), 10)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range msgs {
			if m.ID == id {
				history = m.IsRead
			}
		}
		convs, err := repo.GetConversations(ctx, alice)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range convs {
			if c.ID == bob {
				chatList = c.IsRead
			}
		}
		return
	}
	readByBob := func() bool {
		msgs, err := repo.GetChatHistory(ctx, bob, alice, time.Now().Add(time.Hour), 10)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range msgs {
			if m.ID == id {
				return m.IsRead
			}
		}
		t.Fatal("message missing from bob's history")
		return false
	}

	if h, c := readByAlice(); !h || !c {
		t.Fatalf("with receipts on alice should see it read (history=%v list=%v)", h, c)
	}

	off := false
	setSettings(t, bob, UserSettingsPatch{ReadReceipts: &off})
	if h, c := readByAlice(); h || c {
		t.Errorf("with receipts off alice must not see it read (history=%v list=%v)", h, c)
	}
	if !readByBob() {
		t.Error("bob's own view of what he read must not change")
	}

	on := true
	setSettings(t, bob, UserSettingsPatch{ReadReceipts: &on})
	if h, c := readByAlice(); !h || !c {
		t.Errorf("turning receipts back on shows them again (history=%v list=%v)", h, c)
	}
}
