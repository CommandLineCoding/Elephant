package routes

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

// aGroup makes a group whose admin is the first user returned, with a member.
func aGroup(t *testing.T) (group *models.Group, adminToken, memberToken, outsiderToken string) {
	t.Helper()
	admin, member, outsider := sessionUser(t), sessionUser(t), sessionUser(t)
	g, err := repository.NewGroupRepository().Create(context.Background(), "Trek", admin)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM groups WHERE id = $1::uuid", g.ID) })
	if err := repository.NewGroupRepository().AddMember(context.Background(), g.ID, member); err != nil {
		t.Fatal(err)
	}
	return g, tokenFor(t, admin), tokenFor(t, member), tokenFor(t, outsider)
}

func groupOf(t *testing.T, resp models.JSONResponse) models.Group {
	t.Helper()
	var g models.Group
	decode(t, resp.Data, &g)
	return g
}

func TestAGroupStartsWithNoDescriptionAndEveryonePosting(t *testing.T) {
	g, admin, _, _ := aGroup(t)
	_, resp := callJSON(t, "GET", "/api/groups/"+g.ID, admin, nil)
	got := groupOf(t, resp)
	if got.Description != "" || got.AdminsOnly {
		t.Errorf("a new group has %+v", got)
	}
	_, list := callJSON(t, "GET", "/api/groups", admin, nil)
	var all []models.Group
	decode(t, list.Data, &all)
	found := false
	for _, x := range all {
		if x.ID == g.ID {
			found = true
		}
	}
	if !found {
		t.Error("the group is not in the list")
	}
}

func TestAnAdminSetsTheDescriptionAndAdminsOnly(t *testing.T) {
	g, admin, member, _ := aGroup(t)

	code, resp := callJSON(t, "PATCH", "/api/groups/"+g.ID, admin, map[string]interface{}{
		"description": "  Weekend rides, every Sunday.  ", "admins_only": true,
	})
	if code != http.StatusOK {
		t.Fatalf("patch: %d %+v", code, resp)
	}
	got := groupOf(t, resp)
	if got.Description != "Weekend rides, every Sunday." || !got.AdminsOnly || got.Name != "Trek" {
		t.Errorf("after the patch: %+v", got)
	}

	// Members see it too.
	_, resp = callJSON(t, "GET", "/api/groups/"+g.ID, member, nil)
	if got := groupOf(t, resp); got.Description != "Weekend rides, every Sunday." || !got.AdminsOnly {
		t.Errorf("a member sees %+v", got)
	}

	// Sending only one thing leaves the others.
	_, resp = callJSON(t, "PATCH", "/api/groups/"+g.ID, admin, map[string]interface{}{"admins_only": false})
	if got := groupOf(t, resp); got.AdminsOnly || got.Description != "Weekend rides, every Sunday." {
		t.Errorf("turning admins-only off changed more: %+v", got)
	}
	_, resp = callJSON(t, "PATCH", "/api/groups/"+g.ID, admin, map[string]interface{}{"name": "Sunday Ride"})
	if got := groupOf(t, resp); got.Name != "Sunday Ride" || got.Description == "" {
		t.Errorf("renaming changed more: %+v", got)
	}
	// An empty description clears it.
	_, resp = callJSON(t, "PATCH", "/api/groups/"+g.ID, admin, map[string]interface{}{"description": ""})
	if got := groupOf(t, resp); got.Description != "" {
		t.Errorf("the description was not cleared: %q", got.Description)
	}
}

func TestOnlyAdminsChangeAGroup(t *testing.T) {
	g, _, member, outsider := aGroup(t)
	body := map[string]interface{}{"description": "mine now", "admins_only": true}
	if code, _ := callJSON(t, "PATCH", "/api/groups/"+g.ID, member, body); code != http.StatusForbidden {
		t.Errorf("a member changed the group: %d", code)
	}
	if code, _ := callJSON(t, "PATCH", "/api/groups/"+g.ID, outsider, body); code != http.StatusForbidden {
		t.Errorf("an outsider changed the group: %d", code)
	}
	var d string
	_ = config.DB.QueryRow(context.Background(), `SELECT description FROM groups WHERE id = $1::uuid`, g.ID).Scan(&d)
	if d != "" {
		t.Errorf("the description is %q", d)
	}
}

func TestAGroupChangeIsChecked(t *testing.T) {
	g, admin, _, _ := aGroup(t)
	cases := map[string]map[string]interface{}{
		"nothing to change":         {},
		"a description too long":    {"description": strings.Repeat("é", 501)},
		"an empty name":             {"name": "   "},
		"a name too long":           {"name": strings.Repeat("a", 101)},
		"one bad thing with a good": {"admins_only": true, "description": strings.Repeat("a", 501)},
	}
	for name, body := range cases {
		if code, _ := callJSON(t, "PATCH", "/api/groups/"+g.ID, admin, body); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, code)
		}
	}
	if code, _ := callJSON(t, "PATCH", "/api/groups/"+g.ID, admin, map[string]interface{}{"description": strings.Repeat("é", 500)}); code != http.StatusOK {
		t.Error("a description of exactly 500 characters was refused")
	}
	// The refused ones changed nothing.
	_, resp := callJSON(t, "GET", "/api/groups/"+g.ID, admin, nil)
	if got := groupOf(t, resp); got.AdminsOnly || got.Name != "Trek" {
		t.Errorf("a refused request changed %+v", got)
	}
}

func TestWhoMayPostInTheDatabase(t *testing.T) {
	g, _, _, _ := aGroup(t)
	repo := repository.NewGroupRepository()
	ctx := context.Background()
	var adminID, memberID string
	_ = config.DB.QueryRow(ctx, `SELECT user_id::text FROM group_members WHERE group_id = $1::uuid AND role = 'admin'`, g.ID).Scan(&adminID)
	_ = config.DB.QueryRow(ctx, `SELECT user_id::text FROM group_members WHERE group_id = $1::uuid AND role = 'member'`, g.ID).Scan(&memberID)
	outsider := sessionUser(t)

	check := func(user string, wantMay, wantMember bool, why string) {
		t.Helper()
		may, member, err := repo.MayPost(ctx, g.ID, user)
		if err != nil || may != wantMay || member != wantMember {
			t.Errorf("%s: may=%v member=%v err=%v, want may=%v member=%v", why, may, member, err, wantMay, wantMember)
		}
	}
	check(adminID, true, true, "admin, open group")
	check(memberID, true, true, "member, open group")
	check(outsider, false, false, "outsider")

	on := true
	if _, err := repo.Update(ctx, g.ID, repository.GroupChanges{AdminsOnly: &on}); err != nil {
		t.Fatal(err)
	}
	check(adminID, true, true, "admin, admins-only")
	check(memberID, false, true, "member, admins-only")
	check(outsider, false, false, "outsider, admins-only")
}
