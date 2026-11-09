package repository

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

func pushTestUser(t *testing.T) string {
	t.Helper()
	var id string
	err := config.DB.QueryRow(context.Background(),
		`INSERT INTO users (username, display_name, password_hash) VALUES ($1, 'Push Repo', 'x') RETURNING id::text`,
		fmt.Sprintf("pushrepo.%d", time.Now().UnixNano())).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = config.DB.Exec(context.Background(), "DELETE FROM users WHERE id = $1::uuid", id) })
	return id
}

func endpoints(t *testing.T, repo *PushRepository, uid string) []string {
	t.Helper()
	targets, err := repo.ListByUser(context.Background(), uid)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, tg := range targets {
		out = append(out, tg.Endpoint)
	}
	return out
}

func TestPushUpsertIsIdempotent(t *testing.T) {
	repo := NewPushRepository()
	ctx := context.Background()
	uid := pushTestUser(t)

	for i := 0; i < 3; i++ {
		if err := repo.Upsert(ctx, uid, "https://ntfy.example.org/up1", 5); err != nil {
			t.Fatal(err)
		}
	}
	if got := endpoints(t, repo, uid); len(got) != 1 {
		t.Errorf("registering the same endpoint 3 times stored %d rows", len(got))
	}
}

func TestPushKeepsOnlyTheNewestEndpointsPerUser(t *testing.T) {
	repo := NewPushRepository()
	ctx := context.Background()
	uid := pushTestUser(t)

	for i := 1; i <= 7; i++ {
		if err := repo.Upsert(ctx, uid, fmt.Sprintf("https://ntfy.example.org/up%d", i), 5); err != nil {
			t.Fatal(err)
		}
	}
	got := endpoints(t, repo, uid)
	if len(got) != 5 {
		t.Fatalf("expected 5 endpoints, got %d: %v", len(got), got)
	}
	for _, old := range []string{"https://ntfy.example.org/up1", "https://ntfy.example.org/up2"} {
		for _, e := range got {
			if e == old {
				t.Errorf("the oldest endpoint %s should have been dropped", old)
			}
		}
	}

	// Refreshing an old endpoint keeps it, and drops the next-oldest instead.
	if err := repo.Upsert(ctx, uid, "https://ntfy.example.org/up3", 5); err != nil {
		t.Fatal(err)
	}
	if err := repo.Upsert(ctx, uid, "https://ntfy.example.org/up8", 5); err != nil {
		t.Fatal(err)
	}
	got = endpoints(t, repo, uid)
	has := func(s string) bool {
		for _, e := range got {
			if e == s {
				return true
			}
		}
		return false
	}
	if !has("https://ntfy.example.org/up3") || has("https://ntfy.example.org/up4") {
		t.Errorf("a refreshed endpoint should outlive an older one, got %v", got)
	}
}

func TestPushDeleteOnlyAffectsTheOwner(t *testing.T) {
	repo := NewPushRepository()
	ctx := context.Background()
	alice, bob := pushTestUser(t), pushTestUser(t)
	ep := "https://ntfy.example.org/shared-looking"

	_ = repo.Upsert(ctx, alice, ep, 5)
	_ = repo.Upsert(ctx, bob, ep, 5)

	removed, err := repo.Delete(ctx, alice, ep)
	if err != nil || !removed {
		t.Fatalf("expected alice's endpoint to be removed, got %v %v", removed, err)
	}
	if len(endpoints(t, repo, bob)) != 1 {
		t.Error("deleting alice's endpoint removed bob's")
	}
	if removed, _ := repo.Delete(ctx, alice, ep); removed {
		t.Error("deleting a missing endpoint should report false")
	}
}

func TestPushEndpointsAreRemovedWithTheUser(t *testing.T) {
	repo := NewPushRepository()
	ctx := context.Background()
	uid := pushTestUser(t)
	_ = repo.Upsert(ctx, uid, "https://ntfy.example.org/up1", 5)

	if _, err := config.DB.Exec(ctx, "DELETE FROM users WHERE id = $1::uuid", uid); err != nil {
		t.Fatal(err)
	}
	var n int
	_ = config.DB.QueryRow(ctx, "SELECT count(*) FROM push_endpoints WHERE user_id = $1::uuid", uid).Scan(&n)
	if n != 0 {
		t.Errorf("%d endpoints outlived their user", n)
	}
}
