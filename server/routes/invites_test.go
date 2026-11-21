package routes

import (
	"context"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/go-chi/chi/v5"
)

type inviteBody struct {
	Enabled         bool   `json:"enabled"`
	Code            string `json:"code"`
	RequireApproval bool   `json:"require_approval"`
}

func inviteOf(t *testing.T, resp models.JSONResponse) inviteBody {
	t.Helper()
	var inv inviteBody
	decode(t, resp.Data, &inv)
	return inv
}

type previewBody struct {
	GroupID          string `json:"group_id"`
	Name             string `json:"name"`
	MemberCount      int    `json:"member_count"`
	RequireApproval  bool   `json:"require_approval"`
	AlreadyMember    bool   `json:"already_member"`
	AlreadyRequested bool   `json:"already_requested"`
}

func previewOf(t *testing.T, resp models.JSONResponse) previewBody {
	t.Helper()
	var p previewBody
	decode(t, resp.Data, &p)
	return p
}

// anInvite makes a group with an invite link and a newcomer who isn't in it.
func anInvite(t *testing.T) (g *models.Group, admin, member, newcomerToken, newcomerID, code string) {
	t.Helper()
	group, adminTok, memberTok, _ := aGroup(t)
	code0 := func() string {
		_, resp := callJSON(t, "PUT", "/api/groups/"+group.ID+"/invite", adminTok, nil)
		return inviteOf(t, resp).Code
	}()
	newcomer := sessionUser(t)
	return group, adminTok, memberTok, tokenFor(t, newcomer), newcomer, code0
}

func isMember(t *testing.T, groupID, userID string) bool {
	t.Helper()
	var n int
	_ = config.DB.QueryRow(context.Background(),
		`SELECT count(*) FROM group_members WHERE group_id = $1::uuid AND user_id = $2::uuid`, groupID, userID).Scan(&n)
	return n == 1
}

var codeShape = regexp.MustCompile(`^[A-Za-z0-9_-]{32}$`)

func TestAnAdminCreatesResetsAndTurnsOffTheLink(t *testing.T) {
	g, admin, _, newcomer, _, _ := func() (*models.Group, string, string, string, string, string) {
		group, a, m, _ := aGroup(t)
		return group, a, m, tokenFor(t, sessionUser(t)), "", ""
	}()

	_, resp := callJSON(t, "GET", "/api/groups/"+g.ID+"/invite", admin, nil)
	if inv := inviteOf(t, resp); inv.Enabled || inv.Code != "" {
		t.Fatalf("a group starts with no link: %+v", inv)
	}

	code, resp := callJSON(t, "PUT", "/api/groups/"+g.ID+"/invite", admin, nil)
	first := inviteOf(t, resp)
	if code != http.StatusOK || !first.Enabled || !codeShape.MatchString(first.Code) || first.RequireApproval {
		t.Fatalf("create: %d %+v", code, first)
	}

	// Asking again keeps the same code.
	_, resp = callJSON(t, "PUT", "/api/groups/"+g.ID+"/invite", admin, nil)
	if again := inviteOf(t, resp); again.Code != first.Code {
		t.Error("asking for the link again changed the code")
	}
	_, resp = callJSON(t, "GET", "/api/groups/"+g.ID+"/invite", admin, nil)
	if got := inviteOf(t, resp); got.Code != first.Code || !got.Enabled {
		t.Errorf("get: %+v", got)
	}

	// Resetting makes a new code, and the old one stops working at once.
	_, resp = callJSON(t, "PUT", "/api/groups/"+g.ID+"/invite", admin, map[string]interface{}{"reset": true})
	reset := inviteOf(t, resp)
	if reset.Code == first.Code || !codeShape.MatchString(reset.Code) {
		t.Fatalf("reset gave %q after %q", reset.Code, first.Code)
	}
	if c, _ := callJSON(t, "GET", "/api/invites/"+first.Code, newcomer, nil); c != http.StatusNotFound {
		t.Errorf("the old link still works: %d", c)
	}
	if c, _ := callJSON(t, "GET", "/api/invites/"+reset.Code, newcomer, nil); c != http.StatusOK {
		t.Errorf("the new link doesn't work: %d", c)
	}

	// Turning it off ends it.
	if c, _ := callJSON(t, "DELETE", "/api/groups/"+g.ID+"/invite", admin, nil); c != http.StatusOK {
		t.Fatalf("turn off: %d", c)
	}
	if c, _ := callJSON(t, "GET", "/api/invites/"+reset.Code, newcomer, nil); c != http.StatusNotFound {
		t.Errorf("a link that was turned off still works: %d", c)
	}
	_, resp = callJSON(t, "GET", "/api/groups/"+g.ID+"/invite", admin, nil)
	if inv := inviteOf(t, resp); inv.Enabled {
		t.Errorf("still enabled: %+v", inv)
	}
}

func TestOnlyAdminsManageTheLinkAndTheRequests(t *testing.T) {
	g, admin, member, newcomer, newcomerID, code := anInvite(t)
	_ = admin
	for name, call := range map[string]func(string) int{
		"read the link": func(tok string) int { c, _ := callJSON(t, "GET", "/api/groups/"+g.ID+"/invite", tok, nil); return c },
		"make the link": func(tok string) int { c, _ := callJSON(t, "PUT", "/api/groups/"+g.ID+"/invite", tok, nil); return c },
		"turn it off":   func(tok string) int { c, _ := callJSON(t, "DELETE", "/api/groups/"+g.ID+"/invite", tok, nil); return c },
		"list requests": func(tok string) int { c, _ := callJSON(t, "GET", "/api/groups/"+g.ID+"/requests", tok, nil); return c },
		"approve someone": func(tok string) int {
			c, _ := callJSON(t, "POST", "/api/groups/"+g.ID+"/requests/"+newcomerID, tok, nil)
			return c
		},
		"deny someone": func(tok string) int {
			c, _ := callJSON(t, "DELETE", "/api/groups/"+g.ID+"/requests/"+newcomerID, tok, nil)
			return c
		},
	} {
		for who, tok := range map[string]string{"a member": member, "an outsider": newcomer} {
			if c := call(tok); c != http.StatusForbidden {
				t.Errorf("%s tried to %s: %d, want 403", who, name, c)
			}
		}
	}
	// The link is still there.
	if c, _ := callJSON(t, "GET", "/api/invites/"+code, newcomer, nil); c != http.StatusOK {
		t.Errorf("the link was changed by someone who isn't an admin: %d", c)
	}
}

func TestThePreviewShowsTheGroupAndNamesNoOne(t *testing.T) {
	g, _, member, newcomer, _, code := anInvite(t)

	c, resp := callJSON(t, "GET", "/api/invites/"+code, newcomer, nil)
	if c != http.StatusOK {
		t.Fatalf("preview: %d", c)
	}
	p := previewOf(t, resp)
	if p.Name != "Trek" || p.MemberCount != 2 || p.GroupID != g.ID || p.AlreadyMember || p.RequireApproval {
		t.Errorf("preview: %+v", p)
	}
	// Only a name and a count: nothing about who the members are.
	raw, _ := resp.Data.(map[string]interface{})
	for key := range raw {
		switch key {
		case "group_id", "name", "member_count", "require_approval", "already_member", "already_requested":
		default:
			t.Errorf("the preview has an unexpected field %q", key)
		}
	}

	_, resp = callJSON(t, "GET", "/api/invites/"+code, member, nil)
	if !previewOf(t, resp).AlreadyMember {
		t.Error("a member isn't told they are in the group already")
	}
}

func TestBadAndUnknownCodesAreNotFound(t *testing.T) {
	_, _, _, newcomer, _, _ := anInvite(t)
	for name, code := range map[string]string{
		"too short":   "abc",
		"too long":    strings.Repeat("a", 33),
		"bad symbols": strings.Repeat("!", 32),
		"unknown":     strings.Repeat("a", 32),
	} {
		if c, _ := callJSON(t, "GET", "/api/invites/"+code, newcomer, nil); c != http.StatusNotFound {
			t.Errorf("preview of a code that is %s: %d, want 404", name, c)
		}
		if c, _ := callJSON(t, "POST", "/api/invites/"+code+"/join", newcomer, nil); c != http.StatusNotFound {
			t.Errorf("joining with a code that is %s: %d, want 404", name, c)
		}
	}
	if c, _ := callJSON(t, "GET", "/api/invites/"+strings.Repeat("a", 32), "", nil); c != http.StatusUnauthorized {
		t.Errorf("without signing in: %d", c)
	}
}

func TestJoiningWithTheLink(t *testing.T) {
	g, _, member, newcomer, newcomerID, code := anInvite(t)

	c, resp := callJSON(t, "POST", "/api/invites/"+code+"/join", newcomer, nil)
	if c != http.StatusOK {
		t.Fatalf("join: %d %+v", c, resp)
	}
	var body map[string]string
	decode(t, resp.Data, &body)
	if body["status"] != "joined" || body["group_id"] != g.ID {
		t.Errorf("join answered %+v", body)
	}
	if !isMember(t, g.ID, newcomerID) {
		t.Fatal("not a member after joining")
	}

	// Again, and a member using it.
	_, resp = callJSON(t, "POST", "/api/invites/"+code+"/join", newcomer, nil)
	decode(t, resp.Data, &body)
	if body["status"] != "already_member" {
		t.Errorf("joining twice: %+v", body)
	}
	_, resp = callJSON(t, "POST", "/api/invites/"+code+"/join", member, nil)
	decode(t, resp.Data, &body)
	if body["status"] != "already_member" {
		t.Errorf("a member joining: %+v", body)
	}
	// They joined as an ordinary member.
	var role string
	_ = config.DB.QueryRow(context.Background(),
		`SELECT role FROM group_members WHERE group_id = $1::uuid AND user_id = $2::uuid`, g.ID, newcomerID).Scan(&role)
	if role != "member" {
		t.Errorf("joined as %q", role)
	}
}

func TestAGroupThatWantsApproval(t *testing.T) {
	g, admin, _, newcomer, newcomerID, code := anInvite(t)

	_, resp := callJSON(t, "PUT", "/api/groups/"+g.ID+"/invite", admin, map[string]interface{}{"require_approval": true})
	if inv := inviteOf(t, resp); !inv.RequireApproval || inv.Code != code {
		t.Fatalf("turning approval on changed %+v (code was %s)", inv, code)
	}
	_, resp = callJSON(t, "GET", "/api/invites/"+code, newcomer, nil)
	if !previewOf(t, resp).RequireApproval {
		t.Error("the preview doesn't say approval is needed")
	}

	var body map[string]string
	_, resp = callJSON(t, "POST", "/api/invites/"+code+"/join", newcomer, nil)
	decode(t, resp.Data, &body)
	if body["status"] != "requested" || isMember(t, g.ID, newcomerID) {
		t.Fatalf("with approval on: %+v, member=%v", body, isMember(t, g.ID, newcomerID))
	}
	_, resp = callJSON(t, "GET", "/api/invites/"+code, newcomer, nil)
	if !previewOf(t, resp).AlreadyRequested {
		t.Error("the preview doesn't say they already asked")
	}

	// The admin sees who is waiting, and lets them in.
	_, resp = callJSON(t, "GET", "/api/groups/"+g.ID+"/requests", admin, nil)
	var reqs []struct {
		UserID   string `json:"user_id"`
		Username string `json:"username"`
	}
	decode(t, resp.Data, &reqs)
	if len(reqs) != 1 || reqs[0].UserID != newcomerID || reqs[0].Username == "" {
		t.Fatalf("requests: %+v", reqs)
	}
	if c, _ := callJSON(t, "POST", "/api/groups/"+g.ID+"/requests/"+newcomerID, admin, nil); c != http.StatusOK {
		t.Fatalf("approve: %d", c)
	}
	if !isMember(t, g.ID, newcomerID) {
		t.Error("approved, but not a member")
	}
	_, resp = callJSON(t, "GET", "/api/groups/"+g.ID+"/requests", admin, nil)
	decode(t, resp.Data, &reqs)
	if len(reqs) != 0 {
		t.Errorf("an approved request is still waiting: %+v", reqs)
	}
	if c, _ := callJSON(t, "POST", "/api/groups/"+g.ID+"/requests/"+newcomerID, admin, nil); c != http.StatusNotFound {
		t.Errorf("approving twice: %d, want 404", c)
	}
}

func TestDenyingARequestAndTurningTheLinkOff(t *testing.T) {
	g, admin, _, newcomer, newcomerID, code := anInvite(t)
	callJSON(t, "PUT", "/api/groups/"+g.ID+"/invite", admin, map[string]interface{}{"require_approval": true})
	callJSON(t, "POST", "/api/invites/"+code+"/join", newcomer, nil)

	if c, _ := callJSON(t, "DELETE", "/api/groups/"+g.ID+"/requests/"+newcomerID, admin, nil); c != http.StatusOK {
		t.Fatalf("deny: %d", c)
	}
	if isMember(t, g.ID, newcomerID) {
		t.Error("denied, but in the group")
	}

	// Waiting people are dropped when the link is turned off.
	callJSON(t, "POST", "/api/invites/"+code+"/join", newcomer, nil)
	callJSON(t, "DELETE", "/api/groups/"+g.ID+"/invite", admin, nil)
	var n int
	_ = config.DB.QueryRow(context.Background(),
		`SELECT count(*) FROM group_join_requests WHERE group_id = $1::uuid`, g.ID).Scan(&n)
	if n != 0 {
		t.Errorf("%d requests left after the link was turned off", n)
	}
	if c, _ := callJSON(t, "DELETE", "/api/groups/"+g.ID+"/requests/not-a-uuid", admin, nil); c != http.StatusBadRequest {
		t.Errorf("a bad user ID: %d", c)
	}
}

func TestEveryGroupsLinkIsDifferent(t *testing.T) {
	_, _, _, _, _, a := anInvite(t)
	_, _, _, _, _, b := anInvite(t)
	if a == b || !codeShape.MatchString(a) || !codeShape.MatchString(b) {
		t.Errorf("codes %q and %q", a, b)
	}
}

func TestThePublicPageDoesNotNameTheGroup(t *testing.T) {
	_, _, _, _, _, code := anInvite(t)
	r := chi.NewRouter()
	LinkRoutes(r)

	get := func(path string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		return w
	}
	w := get("/g/" + code)
	body := w.Body.String()
	if w.Code != http.StatusOK || !strings.Contains(body, "elephant://g/"+code) || strings.Contains(body, "Trek") {
		t.Errorf("page: %d, opens app=%v, names group=%v", w.Code, strings.Contains(body, "elephant://g/"+code), strings.Contains(body, "Trek"))
	}
	if w.Header().Get("Referrer-Policy") != "no-referrer" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Errorf("headers: %v", w.Header())
	}
	if c := get("/g/short").Code; c != http.StatusNotFound {
		t.Errorf("a bad code: %d", c)
	}
	if c := get("/g/" + strings.Repeat("<", 32)).Code; c != http.StatusNotFound {
		t.Errorf("a code with markup in it: %d", c)
	}
}
