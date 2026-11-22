package services

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/repository"
)

func TestStatusPostedGoesToConnectedRecipientsWithoutContent(t *testing.T) {
	author := hubClient(t, "st-author")
	friend := hubClient(t, "st-friend")
	away := "st-away" // not connected: nothing to send, and no push ping
	pings := recordPings(t)

	posted := repository.PostedStatus{ID: "s1", CreatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Hour)}
	Hub.PublishStatusPosted("st-author", posted, []string{"st-friend", away, "st-author"})

	got, ok := received(friend, "status_posted", 2*time.Second)
	if !ok {
		t.Fatal("the connected recipient wasn't told")
	}
	if got["status_id"] != "s1" || got["author_id"] != "st-author" || got["expires_at"] == nil {
		t.Errorf("event: %v", got)
	}
	for k := range got {
		if k == "content" {
			t.Error("a status's content went over the event")
		}
	}
	if _, ok := received(author, "status_posted", 300*time.Millisecond); ok {
		t.Error("the author was told about their own status")
	}
	if p := pings(); len(p) != 0 {
		t.Errorf("a status woke someone with a push ping: %v", p)
	}
}

func TestStatusViewedGoesToTheAuthorUnlessReceiptsAreOff(t *testing.T) {
	off := repository.DefaultUserSettings()
	off.ReadReceipts = false
	setSettings(t, map[string]repository.UserSettings{"sv-quiet": off})
	author := hubClient(t, "sv-author")

	Hub.PublishStatusViewed(context.Background(), "s1", "sv-author", "sv-chatty", time.Now())
	got, ok := received(author, "status_viewed", 2*time.Second)
	if !ok {
		t.Fatal("the author wasn't told")
	}
	if got["status_id"] != "s1" || got["viewer_id"] != "sv-chatty" {
		t.Errorf("event: %v", got)
	}

	Hub.PublishStatusViewed(context.Background(), "s2", "sv-author", "sv-quiet", time.Now())
	if m, ok := received(author, "status_viewed", 300*time.Millisecond); ok {
		t.Errorf("a viewer with receipts off was reported: %v", m)
	}
}

func TestStatusViewedFailsClosedWhenSettingsCantBeLoaded(t *testing.T) {
	old := Hub.settings
	Hub.settings = func(context.Context, string) (repository.UserSettings, error) {
		return repository.UserSettings{}, errors.New("db down")
	}
	t.Cleanup(func() { Hub.settings = old })
	author := hubClient(t, "sf-author")
	Hub.PublishStatusViewed(context.Background(), "s1", "sf-author", "sf-viewer", time.Now())
	if _, ok := received(author, "status_viewed", 300*time.Millisecond); ok {
		t.Error("a view was shared though the viewer's setting couldn't be read")
	}
}
