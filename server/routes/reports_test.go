package routes

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
)

type listedReport struct {
	ID               int64                        `json:"id"`
	ReporterID       string                       `json:"reporter_id"`
	ReportedUserID   string                       `json:"reported_user_id"`
	ReportedUsername string                       `json:"reported_username"`
	Reason           string                       `json:"reason"`
	Note             string                       `json:"note"`
	Messages         []repository.ReportedMessage `json:"messages"`
}

func adminIs(t *testing.T, ids ...string) {
	t.Helper()
	old := env.ADMIN_USER_IDS
	env.ADMIN_USER_IDS = strings.Join(ids, " , ")
	t.Cleanup(func() { env.ADMIN_USER_IDS = old })
}

func listReports(t *testing.T, token, query string) (int, []listedReport) {
	t.Helper()
	code, resp := callJSON(t, "GET", "/api/admin/reports"+query, token, nil)
	var out []listedReport
	if code == http.StatusOK {
		decode(t, resp.Data, &out)
	}
	return code, out
}

func report(t *testing.T, token, target, reason string, extra map[string]interface{}) (int, string) {
	t.Helper()
	body := map[string]interface{}{"user_id": target, "reason": reason}
	for k, v := range extra {
		body[k] = v
	}
	code, resp := callJSON(t, "POST", "/api/reports", token, body)
	return code, resp.Error
}

func tokenFor(t *testing.T, uid string) string {
	t.Helper()
	return startSession(t, uid, "Pixel 8").AccessToken
}

func TestReportsNeedASignedInUser(t *testing.T) {
	if code, _ := callJSON(t, "POST", "/api/reports", "", map[string]string{"user_id": "x", "reason": "spam"}); code != http.StatusUnauthorized {
		t.Errorf("report without a token: %d", code)
	}
	if code, _ := callJSON(t, "GET", "/api/admin/reports", "", nil); code != http.StatusUnauthorized {
		t.Errorf("admin list without a token: %d", code)
	}
}

func TestAReportIsStoredAndTheAdminCanReadIt(t *testing.T) {
	reporter, spammer, admin := sessionUser(t), sessionUser(t), sessionUser(t)
	adminIs(t, admin)

	attached := []map[string]interface{}{
		{"from_reported": true, "text": "buy my coins", "at": "2026-11-21T10:00:00Z"},
		{"from_reported": false, "text": "stop", "at": "2026-11-21T10:01:00Z"},
	}
	code, msg := report(t, tokenFor(t, reporter), spammer, "spam", map[string]interface{}{
		"note": "  keeps messaging me  ", "messages": attached,
	})
	if code != http.StatusCreated {
		t.Fatalf("report: %d %s", code, msg)
	}

	code, list := listReports(t, tokenFor(t, admin), "?limit=200")
	if code != http.StatusOK {
		t.Fatalf("admin list: %d", code)
	}
	var found *listedReport
	for i := range list {
		if list[i].ReporterID == reporter && list[i].ReportedUserID == spammer {
			found = &list[i]
		}
	}
	if found == nil {
		t.Fatalf("the report is not in the admin's list: %+v", list)
	}
	if found.Reason != "spam" || found.Note != "keeps messaging me" || found.ReportedUsername == "" {
		t.Errorf("stored %+v", found)
	}
	if len(found.Messages) != 2 || found.Messages[0].Text != "buy my coins" || !found.Messages[0].FromReported || found.Messages[1].FromReported {
		t.Errorf("attached messages: %+v", found.Messages)
	}
}

func TestOnlyAdminsCanReadReports(t *testing.T) {
	reporter, other, admin := sessionUser(t), sessionUser(t), sessionUser(t)

	// Nobody is an admin until the server is told who.
	adminIs(t)
	if code, _ := listReports(t, tokenFor(t, admin), ""); code != http.StatusForbidden {
		t.Errorf("with no admins configured: %d, want 403", code)
	}

	adminIs(t, admin)
	if code, _ := report(t, tokenFor(t, reporter), other, "other", nil); code != http.StatusCreated {
		t.Fatal("report failed")
	}
	for name, uid := range map[string]string{"the reporter": reporter, "the reported person": other} {
		if code, _ := listReports(t, tokenFor(t, uid), ""); code != http.StatusForbidden {
			t.Errorf("%s could read the reports: %d", name, code)
		}
	}
	if code, _ := listReports(t, tokenFor(t, admin), ""); code != http.StatusOK {
		t.Errorf("the admin was refused: %d", code)
	}
}

func TestAdminListPagesNewestFirst(t *testing.T) {
	reporter, admin := sessionUser(t), sessionUser(t)
	adminIs(t, admin)
	tok := tokenFor(t, reporter)
	var targets []string
	for i := 0; i < 3; i++ {
		target := sessionUser(t)
		targets = append(targets, target)
		if code, msg := report(t, tok, target, "harassment", nil); code != http.StatusCreated {
			t.Fatalf("report %d: %d %s", i, code, msg)
		}
	}

	_, first := listReports(t, tokenFor(t, admin), "?limit=2")
	if len(first) != 2 || first[0].ReportedUserID != targets[2] || first[1].ReportedUserID != targets[1] {
		t.Fatalf("first page: %+v", first)
	}
	_, next := listReports(t, tokenFor(t, admin), "?limit=2&before="+itoa(first[1].ID))
	if len(next) == 0 || next[0].ReportedUserID != targets[0] {
		t.Errorf("next page should start with the oldest of mine: %+v", next)
	}
}

func TestReportsAreChecked(t *testing.T) {
	reporter, other := sessionUser(t), sessionUser(t)
	tok := tokenFor(t, reporter)

	cases := []struct {
		name   string
		target string
		reason string
		extra  map[string]interface{}
		want   int
	}{
		{"an unknown reason", other, "rude", nil, http.StatusBadRequest},
		{"no reason", other, "", nil, http.StatusBadRequest},
		{"reporting yourself", reporter, "spam", nil, http.StatusBadRequest},
		{"a bad user ID", "not-a-uuid", "spam", nil, http.StatusBadRequest},
		{"a user that doesn't exist", services.NewSessionID(), "spam", nil, http.StatusNotFound},
		{"a note that is too long", other, "spam", map[string]interface{}{"note": strings.Repeat("é", 501)}, http.StatusBadRequest},
		{"too many attached messages", other, "spam", map[string]interface{}{"messages": make([]map[string]interface{}, 11)}, http.StatusBadRequest},
		{"an attached message that is too long", other, "spam", map[string]interface{}{"messages": []map[string]interface{}{{"text": strings.Repeat("a", 1001)}}}, http.StatusBadRequest},
		{"a note of exactly the limit", other, "other", map[string]interface{}{"note": strings.Repeat("é", 500)}, http.StatusCreated},
	}
	for _, c := range cases {
		if code, msg := report(t, tok, c.target, c.reason, c.extra); code != c.want {
			t.Errorf("%s: %d (%s), want %d", c.name, code, msg, c.want)
		}
	}
	if code, _ := callJSON(t, "POST", "/api/reports", tok, "not an object"); code != http.StatusBadRequest {
		t.Errorf("a malformed body: %d", code)
	}
}

func TestOnePersonCannotFloodTheReports(t *testing.T) {
	reporter, other := sessionUser(t), sessionUser(t)
	tok := tokenFor(t, reporter)
	for i := 0; i < 20; i++ {
		if code, msg := report(t, tok, other, "spam", nil); code != http.StatusCreated {
			t.Fatalf("report %d: %d %s", i+1, code, msg)
		}
	}
	if code, _ := report(t, tok, other, "spam", nil); code != http.StatusTooManyRequests {
		t.Errorf("the 21st report in a day: %d, want 429", code)
	}
	// Someone else is not affected.
	if code, _ := report(t, tokenFor(t, other), reporter, "spam", nil); code != http.StatusCreated {
		t.Errorf("another person was refused: %d", code)
	}
}

func decode(t *testing.T, data interface{}, into interface{}) {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatal(err)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
