package routes

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
)

// realUser signs up properly, so it can sign in with its password afterwards.
func realUser(t *testing.T, prefix string) (user *models.User, token string) {
	t.Helper()
	sessionsDB(t)
	u, err := services.NewUserService().Register(context.Background(), prefix, "Maya", "correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", u.ID) })
	return u, startSession(t, u.ID, "Pixel 8").AccessToken
}

func uniquePrefix(t *testing.T) string {
	t.Helper()
	return fmt.Sprintf("maya%d", time.Now().UnixNano()%1_000_000_000)
}

func patchMe(t *testing.T, token string, body map[string]interface{}) (int, models.JSONResponse) {
	t.Helper()
	return callJSON(t, "PATCH", "/api/users/me", token, body)
}

func userOf(t *testing.T, resp models.JSONResponse) models.User {
	t.Helper()
	var u models.User
	decode(t, resp.Data, &u)
	return u
}

func TestChangingTheUsernameGivesANewNumberAndKeepsTheRest(t *testing.T) {
	old, token := realUser(t, uniquePrefix(t))
	prefix := uniquePrefix(t) + "x"

	code, resp := patchMe(t, token, map[string]interface{}{"username": "  " + strings.ToUpper(prefix) + " "})
	if code != http.StatusOK {
		t.Fatalf("change: %d %+v", code, resp)
	}
	got := userOf(t, resp)
	if !strings.HasPrefix(got.Username, prefix+".") || len(got.Username) != len(prefix)+5 {
		t.Errorf("new username %q, want %s.NNNN", got.Username, prefix)
	}
	if got.Username == old.Username {
		t.Error("the username did not change")
	}
	if got.ID != old.ID || got.DisplayName != "Maya" {
		t.Errorf("the account changed: %+v", got)
	}
	if got.UsernameChangedAt == nil {
		t.Error("the reply doesn't say when it was changed")
	}

	// Chats use user IDs, so the same account answers to the new name.
	_, me := callJSON(t, "GET", "/api/users/me", token, nil)
	meUser := userOf(t, me)
	if meUser.Username != got.Username || meUser.UsernameChangedAt == nil {
		t.Errorf("/me says %+v", meUser)
	}

	// Signing in needs the new username from now on.
	auth := services.NewAuthService()
	if _, _, err := auth.Login(context.Background(), got.Username, "correct horse battery", ""); err != nil {
		t.Errorf("signing in with the new username: %v", err)
	}
	if _, _, err := auth.Login(context.Background(), old.Username, "correct horse battery", ""); err == nil {
		t.Error("the old username still signs in")
	}
	if found, _ := repository.NewUserRepository().FindByUsername(context.Background(), old.Username); found != nil {
		t.Error("the old username still resolves to someone")
	}
}

func TestTheUsernameCanBeChangedOnlyOnceEvery30Days(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	if code, _ := patchMe(t, token, map[string]interface{}{"username": uniquePrefix(t) + "a"}); code != http.StatusOK {
		t.Fatalf("first change: %d", code)
	}
	code, resp := patchMe(t, token, map[string]interface{}{"username": uniquePrefix(t) + "b"})
	if code != http.StatusTooManyRequests {
		t.Fatalf("a second change at once: %d, want 429", code)
	}
	if !strings.Contains(resp.Error, "once every 30 days") {
		t.Errorf("message: %q", resp.Error)
	}

	// 29 days later it is still refused; 31 days later it works.
	for days, want := range map[int]int{29: http.StatusTooManyRequests, 31: http.StatusOK} {
		if _, err := config.DB.Exec(context.Background(),
			`UPDATE users SET username_changed_at = NOW() - make_interval(days => $2) WHERE id = $1::uuid`, user.ID, days); err != nil {
			t.Fatal(err)
		}
		if code, _ := patchMe(t, token, map[string]interface{}{"username": uniquePrefix(t) + "c"}); code != want {
			t.Errorf("%d days later: %d, want %d", days, code, want)
		}
	}
}

// Two requests that both read "never changed" must not both go through. Each
// waits in pick for the other, so without the row lock both would get there.
func TestTwoChangesAtOnceDoNotBothGoThrough(t *testing.T) {
	user, _ := realUser(t, uniquePrefix(t))
	var arrived sync.WaitGroup
	arrived.Add(2)
	pick := func(prefix string) (string, error) {
		arrived.Done()
		done := make(chan struct{})
		go func() { arrived.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
		}
		return fmt.Sprintf("%s.%d", prefix, 1000+time.Now().UnixNano()%9000), nil
	}

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = repository.NewUserRepository().ChangeUsername(
				context.Background(), user.ID, fmt.Sprintf("%s%c", uniquePrefix(t), 'a'+i), time.Now(), pick)
		}(i)
	}
	wg.Wait()

	ok, limited := 0, 0
	for _, err := range errs {
		var recent repository.ErrUsernameChangedRecently
		switch {
		case err == nil:
			ok++
		case errors.As(err, &recent):
			limited++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if ok != 1 || limited != 1 {
		t.Errorf("two changes at once gave %d done and %d refused, want 1 and 1", ok, limited)
	}
}

func TestTheUsernameFollowsTheSignUpRules(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	current := strings.Split(user.Username, ".")[0]
	for name, prefix := range map[string]string{
		"too short":          "ab",
		"too long":           strings.Repeat("a", 26),
		"punctuation":        "maya.smith",
		"spaces inside":      "maya smith",
		"symbols":            "maya_1",
		"what it already is": current,
		"empty":              "",
	} {
		if code, resp := patchMe(t, token, map[string]interface{}{"username": prefix}); code != http.StatusBadRequest {
			t.Errorf("%s (%q): %d %q, want 400", name, prefix, code, resp.Error)
		}
	}
	// None of those used up the one change.
	if code, _ := patchMe(t, token, map[string]interface{}{"username": uniquePrefix(t) + "z"}); code != http.StatusOK {
		t.Errorf("a refused request used up the change: %d", code)
	}
}

func TestADisplayNameAndAUsernameChangeTogether(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	prefix := uniquePrefix(t) + "d"
	code, resp := patchMe(t, token, map[string]interface{}{"username": prefix, "display_name": "Maya Chen"})
	got := userOf(t, resp)
	if code != http.StatusOK || got.DisplayName != "Maya Chen" || !strings.HasPrefix(got.Username, prefix+".") {
		t.Errorf("both: %d %+v", code, got)
	}
}

func TestADisplayNameAloneStillWorksAndAnEmptyRequestIsRefused(t *testing.T) {
	user, token := realUser(t, uniquePrefix(t))
	code, resp := patchMe(t, token, map[string]interface{}{"display_name": "Maya Chen"})
	got := userOf(t, resp)
	if code != http.StatusOK || got.Username != user.Username || got.DisplayName != "Maya Chen" {
		t.Errorf("display name: %d %+v", code, got)
	}
	if got.UsernameChangedAt != nil {
		t.Errorf("never changed, but the reply says %v", got.UsernameChangedAt)
	}

	// Once it has been changed, a later rename still tells the app when, so
	// the app knows when it can be changed again.
	patchMe(t, token, map[string]interface{}{"username": uniquePrefix(t) + "r"})
	_, resp = patchMe(t, token, map[string]interface{}{"display_name": "Maya C"})
	if got := userOf(t, resp); got.UsernameChangedAt == nil {
		t.Error("a display name change dropped when the username was last changed")
	}
	if code, _ := patchMe(t, token, map[string]interface{}{}); code != http.StatusBadRequest {
		t.Errorf("nothing to change: %d, want 400", code)
	}
}

func TestARefusedUsernameLeavesTheDisplayNameAlone(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	code, _ := patchMe(t, token, map[string]interface{}{"username": "ab", "display_name": "Changed"})
	if code != http.StatusBadRequest {
		t.Fatalf("code %d", code)
	}
	_, me := callJSON(t, "GET", "/api/users/me", token, nil)
	if got := userOf(t, me); got.DisplayName != "Maya" {
		t.Errorf("the display name changed to %q although the request was refused", got.DisplayName)
	}
}

func TestOnlyThePersonSeesWhenTheyLastChangedIt(t *testing.T) {
	_, token := realUser(t, uniquePrefix(t))
	other, otherToken := realUser(t, uniquePrefix(t))
	patchMe(t, otherToken, map[string]interface{}{"username": uniquePrefix(t) + "o"})

	_, resp := callJSON(t, "GET", "/api/users/"+other.ID, token, nil)
	if got := userOf(t, resp); got.UsernameChangedAt != nil {
		t.Errorf("someone else's profile shows when they changed their username: %v", got.UsernameChangedAt)
	}
}

func TestWhenEveryCandidateIsTakenItSaysSo(t *testing.T) {
	taken, _ := realUser(t, uniquePrefix(t))
	user, _ := realUser(t, uniquePrefix(t))
	_, err := repository.NewUserRepository().ChangeUsername(context.Background(), user.ID, "whatever", time.Now(),
		func(string) (string, error) { return taken.Username, nil })
	if err != repository.ErrUsernameTaken {
		t.Errorf("error = %v, want ErrUsernameTaken", err)
	}
	got, _ := repository.NewUserRepository().FindByID(context.Background(), user.ID)
	if got.Username != user.Username {
		t.Errorf("the username changed to %q", got.Username)
	}
	if at, _ := repository.NewUserRepository().UsernameChangedAt(context.Background(), user.ID); at != nil {
		t.Error("a change that didn't happen used up the 30 days")
	}
}
