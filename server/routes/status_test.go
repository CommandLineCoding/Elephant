package routes

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
)

// befriend makes a and b contacts, as chatting does.
func befriend(t *testing.T, a, b string) {
	t.Helper()
	if _, err := repository.NewMessageRepository().CreateMessage(context.Background(), a, b, "hi", ""); err != nil {
		t.Fatal(err)
	}
}

func postStatus(t *testing.T, token string, copies ...map[string]string) (int, map[string]interface{}, string) {
	t.Helper()
	list := make([]interface{}, len(copies))
	for i, c := range copies {
		list[i] = c
	}
	code, resp := callJSON(t, "POST", "/api/status", token, map[string]interface{}{"copies": list})
	out, _ := resp.Data.(map[string]interface{})
	return code, out, resp.Error
}

func copyFor(id, content string) map[string]string {
	return map[string]string{"recipient_id": id, "content": content}
}

type receivedStatus struct {
	ID       string `json:"id"`
	AuthorID string `json:"author_id"`
	Content  string `json:"content"`
	Viewed   bool   `json:"viewed"`
}

func statusesFor(t *testing.T, token string) []receivedStatus {
	t.Helper()
	code, resp := callJSON(t, "GET", "/api/status", token, nil)
	if code != http.StatusOK {
		t.Fatalf("list: %d %s", code, resp.Error)
	}
	var out []receivedStatus
	decode(t, resp.Data, &out)
	return out
}

type ownStatus struct {
	ID         string `json:"id"`
	Recipients int    `json:"recipients"`
	Viewers    []struct {
		UserID string `json:"user_id"`
	} `json:"viewers"`
}

func ownStatuses(t *testing.T, token string) []ownStatus {
	t.Helper()
	code, resp := callJSON(t, "GET", "/api/status/mine", token, nil)
	if code != http.StatusOK {
		t.Fatalf("mine: %d %s", code, resp.Error)
	}
	var out []ownStatus
	decode(t, resp.Data, &out)
	return out
}

func TestStatusNeedsASignedInUser(t *testing.T) {
	for _, c := range [][2]string{
		{"POST", "/api/status"}, {"GET", "/api/status"}, {"GET", "/api/status/mine"},
		{"DELETE", "/api/status/00000000-0000-0000-0000-000000000001"},
		{"POST", "/api/status/00000000-0000-0000-0000-000000000001/view"},
	} {
		if code, _ := callJSON(t, c[0], c[1], "", nil); code != http.StatusUnauthorized {
			t.Errorf("%s %s without a token: %d", c[0], c[1], code)
		}
	}
}

func TestAStatusReachesContactsAndOnlyContacts(t *testing.T) {
	author, friend, stranger := sessionUser(t), sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	token := tokenFor(t, author)

	code, out, msg := postStatus(t, token, copyFor(friend, "sealed for the friend"), copyFor(stranger, "sealed for a stranger"))
	if code != http.StatusCreated {
		t.Fatalf("post: %d %s", code, msg)
	}
	if out["recipients"] != float64(1) {
		t.Errorf("recipients = %v, want 1", out["recipients"])
	}
	skipped, _ := out["skipped"].([]interface{})
	if len(skipped) != 1 || skipped[0] != stranger {
		t.Errorf("skipped = %v, want just the stranger", out["skipped"])
	}
	if out["id"] == "" || out["expires_at"] == nil {
		t.Errorf("missing id or expiry: %v", out)
	}

	got := statusesFor(t, tokenFor(t, friend))
	if len(got) != 1 || got[0].Content != "sealed for the friend" || got[0].AuthorID != author || got[0].Viewed {
		t.Errorf("the friend's list: %+v", got)
	}
	if got := statusesFor(t, tokenFor(t, stranger)); len(got) != 0 {
		t.Errorf("the stranger got %+v", got)
	}
	// The author doesn't get a copy of their own status in this list.
	if got := statusesFor(t, token); len(got) != 0 {
		t.Errorf("the author's own list: %+v", got)
	}
	mine := ownStatuses(t, token)
	if len(mine) != 1 || mine[0].Recipients != 1 || len(mine[0].Viewers) != 0 {
		t.Errorf("own statuses: %+v", mine)
	}
}

func TestAStatusIsNotForSomeoneWhoseRequestIsWaiting(t *testing.T) {
	author, stranger := sessionUser(t), sessionUser(t)
	token := tokenFor(t, author)
	// The author wrote to someone new: a request they haven't accepted.
	if ok, err := repository.NewRequestRepository().Open(context.Background(), stranger, author); err != nil || !ok {
		t.Fatalf("open request: %v %v", ok, err)
	}
	befriend(t, author, stranger)
	code, _, msg := postStatus(t, token, copyFor(stranger, "x"))
	if code != http.StatusBadRequest {
		t.Errorf("a status for someone who hasn't accepted: %d %s", code, msg)
	}
}

func TestStatusCopiesAreChecked(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	token := tokenFor(t, author)

	cases := []struct {
		name   string
		copies []map[string]string
	}{
		{"none", nil},
		{"a bad id", []map[string]string{copyFor("nope", "x")}},
		{"empty content", []map[string]string{copyFor(friend, "")}},
		{"too long", []map[string]string{copyFor(friend, strings.Repeat("a", 8<<10+1))}},
		{"a person twice", []map[string]string{copyFor(friend, "a"), copyFor(strings.ToUpper(friend), "b")}},
		{"only strangers", []map[string]string{copyFor("00000000-0000-0000-0000-000000000001", "a")}},
		{"only yourself", []map[string]string{copyFor(author, "a")}},
	}
	for _, c := range cases {
		if code, _, _ := postStatus(t, token, c.copies...); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", c.name, code)
		}
	}
	if n := len(ownStatuses(t, token)); n != 0 {
		t.Errorf("a refused status was stored: %d", n)
	}

	many := make([]map[string]string, 201)
	for i := range many {
		many[i] = copyFor(friend, "x")
	}
	if code, _, _ := postStatus(t, token, many...); code != http.StatusBadRequest {
		t.Errorf("201 copies: %d, want 400", code)
	}
}

func TestStatusesAreLimitedPerDay(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	token := tokenFor(t, author)
	for i := 0; i < 20; i++ {
		if _, err := config.DB.Exec(context.Background(),
			`INSERT INTO statuses (author_id, expires_at) VALUES ($1::uuid, NOW() + interval '1 hour')`, author); err != nil {
			t.Fatal(err)
		}
	}
	if code, _, _ := postStatus(t, token, copyFor(friend, "x")); code != http.StatusTooManyRequests {
		t.Errorf("the 21st status: %d, want 429", code)
	}
	// Ones from before the last day don't count.
	if _, err := config.DB.Exec(context.Background(),
		`UPDATE statuses SET created_at = NOW() - interval '25 hours' WHERE author_id = $1::uuid`, author); err != nil {
		t.Fatal(err)
	}
	if code, _, msg := postStatus(t, token, copyFor(friend, "x")); code != http.StatusCreated {
		t.Errorf("after a day: %d %s", code, msg)
	}
}

func TestViewingMarksItAndTheAuthorSeesWho(t *testing.T) {
	author, a, b := sessionUser(t), sessionUser(t), sessionUser(t)
	befriend(t, author, a)
	befriend(t, author, b)
	token := tokenFor(t, author)
	_, out, _ := postStatus(t, token, copyFor(a, "for a"), copyFor(b, "for b"))
	id := out["id"].(string)

	if code, _ := callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, a), nil); code != http.StatusOK {
		t.Fatalf("view: %d", code)
	}
	// Again is fine, and doesn't add a second viewer.
	if code, _ := callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, a), nil); code != http.StatusOK {
		t.Fatalf("view again: %d", code)
	}
	if got := statusesFor(t, tokenFor(t, a)); len(got) != 1 || !got[0].Viewed {
		t.Errorf("a's list: %+v", got)
	}
	if got := statusesFor(t, tokenFor(t, b)); got[0].Viewed {
		t.Error("b's copy shows as seen")
	}
	mine := ownStatuses(t, token)
	if len(mine[0].Viewers) != 1 || mine[0].Viewers[0].UserID != a {
		t.Errorf("viewers: %+v", mine[0].Viewers)
	}
	if mine[0].Recipients != 2 {
		t.Errorf("recipients = %d", mine[0].Recipients)
	}
}

func TestViewingSomeoneElsesOrAMissingStatusIsNotFound(t *testing.T) {
	author, friend, other := sessionUser(t), sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	_, out, _ := postStatus(t, tokenFor(t, author), copyFor(friend, "x"))
	id := out["id"].(string)

	for name, c := range map[string][2]string{
		"someone it wasn't for": {tokenFor(t, other), id},
		"the author":            {tokenFor(t, author), id},
		"a status that isn't":   {tokenFor(t, friend), "00000000-0000-0000-0000-000000000001"},
	} {
		if code, _ := callJSON(t, "POST", "/api/status/"+c[1]+"/view", c[0], nil); code != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", name, code)
		}
	}
	if code, _ := callJSON(t, "POST", "/api/status/not-a-uuid/view", tokenFor(t, friend), nil); code != http.StatusBadRequest {
		t.Errorf("a bad id: %d, want 400", code)
	}
}

func TestAViewerWithReceiptsOffIsNotListed(t *testing.T) {
	author, quiet, chatty := sessionUser(t), sessionUser(t), sessionUser(t)
	befriend(t, author, quiet)
	befriend(t, author, chatty)
	token := tokenFor(t, author)
	_, out, _ := postStatus(t, token, copyFor(quiet, "q"), copyFor(chatty, "c"))
	id := out["id"].(string)

	if code, _ := callJSON(t, "PATCH", "/api/users/me/settings", tokenFor(t, quiet), map[string]interface{}{"read_receipts": false}); code != http.StatusOK {
		t.Fatalf("settings: %d", code)
	}
	callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, quiet), nil)
	callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, chatty), nil)

	mine := ownStatuses(t, token)
	if len(mine[0].Viewers) != 1 || mine[0].Viewers[0].UserID != chatty {
		t.Errorf("viewers: %+v; the one with receipts off must not be listed", mine[0].Viewers)
	}
	// They still see their own state.
	if got := statusesFor(t, tokenFor(t, quiet)); !got[0].Viewed {
		t.Error("the quiet viewer lost track of what they saw")
	}
}

func TestOnlyTheAuthorDeletesAStatus(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	_, out, _ := postStatus(t, tokenFor(t, author), copyFor(friend, "x"))
	id := out["id"].(string)

	if code, _ := callJSON(t, "DELETE", "/api/status/"+id, tokenFor(t, friend), nil); code != http.StatusNotFound {
		t.Errorf("a recipient deleting: %d, want 404", code)
	}
	if len(statusesFor(t, tokenFor(t, friend))) != 1 {
		t.Fatal("a recipient removed the status")
	}
	if code, _ := callJSON(t, "DELETE", "/api/status/"+id, tokenFor(t, author), nil); code != http.StatusOK {
		t.Fatalf("the author deleting: %d", code)
	}
	if len(statusesFor(t, tokenFor(t, friend))) != 0 || len(ownStatuses(t, tokenFor(t, author))) != 0 {
		t.Error("the status is still there")
	}
	if code, _ := callJSON(t, "DELETE", "/api/status/"+id, tokenFor(t, author), nil); code != http.StatusNotFound {
		t.Errorf("deleting twice: %d, want 404", code)
	}
	if code, _ := callJSON(t, "DELETE", "/api/status/nope", tokenFor(t, author), nil); code != http.StatusBadRequest {
		t.Errorf("a bad id: %d, want 400", code)
	}
}

func TestAnExpiredStatusIsGoneAndCleanedUp(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	_, out, _ := postStatus(t, tokenFor(t, author), copyFor(friend, "x"))
	id := out["id"].(string)

	if _, err := config.DB.Exec(context.Background(),
		`UPDATE statuses SET expires_at = NOW() - interval '1 second' WHERE id = $1::uuid`, id); err != nil {
		t.Fatal(err)
	}
	if len(statusesFor(t, tokenFor(t, friend))) != 0 || len(ownStatuses(t, tokenFor(t, author))) != 0 {
		t.Error("an expired status is still listed")
	}
	if code, _ := callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, friend), nil); code != http.StatusNotFound {
		t.Errorf("viewing an expired status: %d, want 404", code)
	}

	for {
		n, err := repository.NewCleanupRepository().DeleteExpiredStatuses(context.Background(), 1000)
		if err != nil {
			t.Fatal(err)
		}
		if n < 1000 {
			break
		}
	}
	var statuses, copies int
	_ = config.DB.QueryRow(context.Background(), `SELECT count(*) FROM statuses WHERE id = $1::uuid`, id).Scan(&statuses)
	_ = config.DB.QueryRow(context.Background(), `SELECT count(*) FROM status_copies WHERE status_id = $1::uuid`, id).Scan(&copies)
	if statuses != 0 || copies != 0 {
		t.Errorf("after cleanup: %d statuses, %d copies", statuses, copies)
	}
}

func TestAStatusFromSomeoneYouBlockedIsHidden(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	postStatus(t, tokenFor(t, author), copyFor(friend, "x"))
	if len(statusesFor(t, tokenFor(t, friend))) != 1 {
		t.Fatal("setup")
	}
	if code, _ := callJSON(t, "POST", "/api/users/"+author+"/block", tokenFor(t, friend), nil); code != http.StatusOK {
		t.Fatalf("block: %d", code)
	}
	if got := statusesFor(t, tokenFor(t, friend)); len(got) != 0 {
		t.Errorf("a blocked author's status is listed: %+v", got)
	}
	// Nor can the blocked person post to the one who blocked them.
	code, _, _ := postStatus(t, tokenFor(t, author), copyFor(friend, "again"))
	if code != http.StatusBadRequest {
		t.Errorf("posting to someone who blocked you: %d, want 400", code)
	}
}

func TestExpiryIsTwentyFourHours(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	_, out, _ := postStatus(t, tokenFor(t, author), copyFor(friend, "x"))
	exp, err := time.Parse(time.RFC3339Nano, out["expires_at"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if d := time.Until(exp); d < 23*time.Hour+59*time.Minute || d > 24*time.Hour+time.Minute {
		t.Errorf("a status lasts %v", d)
	}
}

// hubClient connects a fake phone for userID to the hub and returns what it is
// sent.
func hubClient(t *testing.T, userID string) *services.WSClient {
	t.Helper()
	hubOnce.Do(func() { go services.Hub.Run() })
	c := services.NewWSClient(userID, nil)
	services.Hub.Register <- c
	t.Cleanup(func() { services.Hub.Unregister <- c })
	return c
}

func eventsOf(c *services.WSClient, kind string, wait time.Duration) []map[string]interface{} {
	var out []map[string]interface{}
	timeout := time.After(wait)
	for {
		select {
		case b := <-c.Send:
			var m map[string]interface{}
			if json.Unmarshal(b, &m) == nil && m["type"] == kind {
				out = append(out, m)
			}
		case <-timeout:
			return out
		}
	}
}

func TestPostingAndViewingTellTheOtherSideOnce(t *testing.T) {
	author, friend := sessionUser(t), sessionUser(t)
	befriend(t, author, friend)
	authorPhone, friendPhone := hubClient(t, author), hubClient(t, friend)

	_, out, _ := postStatus(t, tokenFor(t, author), copyFor(friend, "x"))
	id := out["id"].(string)
	posted := eventsOf(friendPhone, "status_posted", 500*time.Millisecond)
	if len(posted) != 1 || posted[0]["status_id"] != id || posted[0]["author_id"] != author {
		t.Errorf("the friend was told: %v", posted)
	}
	if got := eventsOf(authorPhone, "status_posted", 100*time.Millisecond); len(got) != 0 {
		t.Errorf("the author was told about their own post: %v", got)
	}

	// Seeing it twice tells the author once.
	callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, friend), nil)
	callJSON(t, "POST", "/api/status/"+id+"/view", tokenFor(t, friend), nil)
	viewed := eventsOf(authorPhone, "status_viewed", 500*time.Millisecond)
	if len(viewed) != 1 || viewed[0]["viewer_id"] != friend || viewed[0]["status_id"] != id {
		t.Errorf("the author was told: %v", viewed)
	}
}
