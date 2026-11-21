package routes

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/services"
)

func ptr[T any](v T) *T { return &v }

func profileOf(t *testing.T, resp models.JSONResponse) models.User {
	t.Helper()
	return userOf(t, resp)
}

func TestAProfileStartsWithNoBioAndNoStatus(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	_, resp := callJSON(t, "GET", "/api/users/me", token, nil)
	got := profileOf(t, resp)
	if got.Bio != "" || got.Status != nil {
		t.Errorf("a new profile has bio %q and status %+v", got.Bio, got.Status)
	}
}

func TestSettingTheBio(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	code, resp := patchMe(t, token, map[string]interface{}{"bio": "  Cyclist. Chai first.  "})
	if code != http.StatusOK {
		t.Fatalf("set bio: %d %+v", code, resp)
	}
	if got := profileOf(t, resp); got.Bio != "Cyclist. Chai first." || got.Username != user.Username {
		t.Errorf("after setting the bio: %+v", got)
	}

	// Anyone who can look the person up sees it.
	_, other := realUser(t, uniquePrefix(t))
	_, resp = callJSON(t, "GET", "/api/users/"+user.ID, other, nil)
	if got := profileOf(t, resp); got.Bio != "Cyclist. Chai first." {
		t.Errorf("another person sees bio %q", got.Bio)
	}

	// An empty one clears it, and 140 characters is the limit.
	_, resp = patchMe(t, token, map[string]interface{}{"bio": ""})
	if got := profileOf(t, resp); got.Bio != "" {
		t.Errorf("the bio was not cleared: %q", got.Bio)
	}
	if code, _ := patchMe(t, token, map[string]interface{}{"bio": strings.Repeat("é", 140)}); code != http.StatusOK {
		t.Errorf("a bio of exactly 140 characters: %d", code)
	}
	if code, _ := patchMe(t, token, map[string]interface{}{"bio": strings.Repeat("é", 141)}); code != http.StatusBadRequest {
		t.Errorf("a bio of 141 characters: %d, want 400", code)
	}
}

func TestSettingACustomStatus(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	code, resp := patchMe(t, token, map[string]interface{}{
		"status": map[string]interface{}{"emoji": " 🚴 ", "text": " On a ride ", "expires_in": 3600},
	})
	if code != http.StatusOK {
		t.Fatalf("set status: %d %+v", code, resp)
	}
	got := profileOf(t, resp)
	if got.Status == nil || got.Status.Emoji != "🚴" || got.Status.Text != "On a ride" {
		t.Fatalf("status: %+v", got.Status)
	}
	if got.Status.ExpiresAt == nil || time.Until(*got.Status.ExpiresAt) < 55*time.Minute || time.Until(*got.Status.ExpiresAt) > 61*time.Minute {
		t.Errorf("an hour from now, but expires at %v", got.Status.ExpiresAt)
	}

	_, other := realUser(t, uniquePrefix(t))
	_, resp = callJSON(t, "GET", "/api/users/"+user.ID, other, nil)
	if seen := profileOf(t, resp); seen.Status == nil || seen.Status.Text != "On a ride" {
		t.Errorf("another person sees status %+v", seen.Status)
	}
}

func TestAStatusWithNoEndLastsUntilChanged(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	for _, expires := range []interface{}{nil, 0} {
		status := map[string]interface{}{"emoji": "🌴", "text": "Away"}
		if expires != nil {
			status["expires_in"] = expires
		}
		_, resp := patchMe(t, token, map[string]interface{}{"status": status})
		if got := profileOf(t, resp); got.Status == nil || got.Status.ExpiresAt != nil {
			t.Errorf("expires_in=%v: %+v", expires, got.Status)
		}
	}
}

func TestAnExpiredStatusIsNotShown(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	patchMe(t, token, map[string]interface{}{
		"status": map[string]interface{}{"emoji": "🚴", "text": "On a ride", "expires_in": 3600},
	})
	if _, err := config.DB.Exec(context.Background(),
		`UPDATE users SET status_expires_at = NOW() - interval '1 minute' WHERE id = $1::uuid`, user.ID); err != nil {
		t.Fatal(err)
	}
	_, other := realUser(t, uniquePrefix(t))
	for who, tok := range map[string]string{"the person": token, "someone else": other} {
		_, resp := callJSON(t, "GET", "/api/users/"+user.ID, tok, nil)
		if got := profileOf(t, resp); got.Status != nil {
			t.Errorf("%s sees an expired status: %+v", who, got.Status)
		}
	}
}

func TestClearingTheStatus(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	patchMe(t, token, map[string]interface{}{"status": map[string]interface{}{"emoji": "🚴", "text": "On a ride"}})
	code, resp := patchMe(t, token, map[string]interface{}{"status": map[string]interface{}{"emoji": "", "text": ""}})
	if got := profileOf(t, resp); code != http.StatusOK || got.Status != nil {
		t.Errorf("clearing: %d %+v", code, got.Status)
	}
	// An emoji alone, or text alone, is a status.
	_, resp = patchMe(t, token, map[string]interface{}{"status": map[string]interface{}{"emoji": "🎧"}})
	if got := profileOf(t, resp); got.Status == nil || got.Status.Emoji != "🎧" || got.Status.Text != "" {
		t.Errorf("emoji only: %+v", got.Status)
	}
}

func TestProfileChangesAreCheckedAndAllOrNothing(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	bad := map[string]map[string]interface{}{
		"a status too long":               {"status": map[string]interface{}{"text": strings.Repeat("a", 61)}},
		"an emoji too long":               {"status": map[string]interface{}{"emoji": strings.Repeat("😀", 17), "text": "x"}},
		"an end too soon":                 {"status": map[string]interface{}{"text": "x", "expires_in": 5}},
		"an end too far":                  {"status": map[string]interface{}{"text": "x", "expires_in": 8 * 24 * 3600}},
		"a negative end":                  {"status": map[string]interface{}{"text": "x", "expires_in": -1}},
		"a bio too long":                  {"bio": strings.Repeat("a", 141)},
		"a bad display name":              {"display_name": "   "},
		"a bad username, with a good bio": {"username": "ab", "bio": "fine"},
		"a good bio, with a bad status":   {"bio": "fine", "status": map[string]interface{}{"text": strings.Repeat("a", 61)}},
	}
	for name, body := range bad {
		if code, _ := patchMe(t, token, body); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, code)
		}
	}
	_, resp := callJSON(t, "GET", "/api/users/me", token, nil)
	got := profileOf(t, resp)
	if got.Bio != "" || got.Status != nil || got.DisplayName != "Maya" || got.Username != user.Username {
		t.Errorf("a refused request changed %+v", got)
	}
	// An end time is only for a status that exists.
	_, resp = patchMe(t, token, map[string]interface{}{"status": map[string]interface{}{"expires_in": 3600}})
	if got := profileOf(t, resp); got.Status != nil {
		t.Errorf("an end time alone made a status: %+v", got.Status)
	}
}

func TestBioAndStatusCanChangeWithTheDisplayName(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	code, resp := patchMe(t, token, map[string]interface{}{
		"display_name": "Maya Chen",
		"bio":          "About me",
		"status":       map[string]interface{}{"emoji": "📚", "text": "Studying"},
	})
	got := profileOf(t, resp)
	if code != http.StatusOK || got.DisplayName != "Maya Chen" || got.Bio != "About me" || got.Status == nil {
		t.Errorf("all together: %d %+v", code, got)
	}
}

func TestProfileRulesInTheService(t *testing.T) {
	now := time.Now()
	if _, err := services.NormalizeStatus(services.StatusInput{Text: "ok", ExpiresIn: ptr(60)}, now); err != nil {
		t.Errorf("a minute: %v", err)
	}
	if _, err := services.NormalizeStatus(services.StatusInput{Text: "ok", ExpiresIn: ptr(7 * 24 * 3600)}, now); err != nil {
		t.Errorf("a week: %v", err)
	}
	if s, _ := services.NormalizeStatus(services.StatusInput{Emoji: " ", Text: " ", ExpiresIn: ptr(3600)}, now); s.Emoji != "" || s.ExpiresAt != nil {
		t.Errorf("blank status: %+v", s)
	}
}
