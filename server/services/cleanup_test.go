package services

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/repository"
)

func addToken(t *testing.T, userID, hash string, expires time.Duration) {
	t.Helper()
	db := pushTestDB(t)
	if _, err := db.Exec(context.Background(),
		`INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1::uuid, $2, NOW() + $3 * interval '1 second')`,
		userID, hash, expires.Seconds()); err != nil {
		t.Fatal(err)
	}
}

func hasToken(t *testing.T, hash string) bool {
	t.Helper()
	var n int
	if err := pushTestDB(t).QueryRow(context.Background(),
		`SELECT count(*) FROM refresh_tokens WHERE token_hash = $1`, hash).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func addEndpoint(t *testing.T, userID, endpoint string, failures int) int64 {
	t.Helper()
	var id int64
	if err := pushTestDB(t).QueryRow(context.Background(),
		`INSERT INTO push_endpoints (user_id, endpoint, failures) VALUES ($1::uuid, $2, $3) RETURNING id`,
		userID, endpoint, failures).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func endpointExists(t *testing.T, id int64) bool {
	t.Helper()
	var n int
	if err := pushTestDB(t).QueryRow(context.Background(),
		`SELECT count(*) FROM push_endpoints WHERE id = $1`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func TestCleanupDeletesExpiredTokensAndKeepsLiveOnes(t *testing.T) {
	pushTestDB(t)
	uid := newTestUser(t)
	addToken(t, uid, "cleanup-old-1", -time.Hour)
	addToken(t, uid, "cleanup-old-2", -time.Minute)
	addToken(t, uid, "cleanup-live", time.Hour)

	report, ran, err := NewCleaner(defaultCleanupTasks()...).RunOnce(context.Background())
	if err != nil || !ran {
		t.Fatalf("RunOnce: ran=%v err=%v", ran, err)
	}
	if report["refresh_tokens"] < 2 {
		t.Errorf("deleted %d tokens, want at least the 2 expired ones", report["refresh_tokens"])
	}
	if hasToken(t, "cleanup-old-1") || hasToken(t, "cleanup-old-2") {
		t.Error("an expired token is still there")
	}
	if !hasToken(t, "cleanup-live") {
		t.Error("a token that is still valid was deleted")
	}
}

func TestCleanupDeletesOnlyEndpointsThatKeepFailing(t *testing.T) {
	pushTestDB(t)
	uid := newTestUser(t)
	dead := addEndpoint(t, uid, "https://ntfy.example.org/dead", pushFailureLimit)
	flaky := addEndpoint(t, uid, "https://ntfy.example.org/flaky", pushFailureLimit-1)
	fine := addEndpoint(t, uid, "https://ntfy.example.org/fine", 0)

	if _, _, err := NewCleaner(defaultCleanupTasks()...).RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if endpointExists(t, dead) {
		t.Error("an endpoint that failed too often is still there")
	}
	if !endpointExists(t, flaky) || !endpointExists(t, fine) {
		t.Error("an endpoint under the limit was deleted")
	}
}

func TestAPingResultCountsFailuresAndASuccessResetsThem(t *testing.T) {
	pushTestDB(t)
	repo := repository.NewPushRepository()
	uid := newTestUser(t)
	id := addEndpoint(t, uid, "https://ntfy.example.org/count", 0)
	ctx := context.Background()

	failures := func() int {
		var n int
		if err := pushTestDB(t).QueryRow(ctx, `SELECT failures FROM push_endpoints WHERE id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for i := 0; i < 3; i++ {
		if err := repo.RecordResult(ctx, id, false); err != nil {
			t.Fatal(err)
		}
	}
	if got := failures(); got != 3 {
		t.Fatalf("after 3 failures the count is %d", got)
	}
	if err := repo.RecordResult(ctx, id, true); err != nil {
		t.Fatal(err)
	}
	if got := failures(); got != 0 {
		t.Errorf("a success should reset the count, got %d", got)
	}
}

// A ping that fails adds to the endpoint's run of failures and one that gets
// through clears it, so only an endpoint that is gone for good is dropped.
func TestDeliverRecordsHowPingsWentForTheCleanup(t *testing.T) {
	pushTestDB(t)
	status := http.StatusInternalServerError
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
	}))
	defer srv.Close()

	uid := newTestUser(t)
	id := addEndpoint(t, uid, srv.URL+"/up", 0)
	p := NewPushService(true)
	failures := func() int {
		var n int
		if err := pushTestDB(t).QueryRow(context.Background(),
			`SELECT failures FROM push_endpoints WHERE id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	p.deliver(pushJob{userID: uid, ttl: time.Minute})
	p.deliver(pushJob{userID: uid, ttl: time.Minute})
	if got := failures(); got != 2 {
		t.Fatalf("after two failed pings the count is %d", got)
	}
	status = http.StatusOK
	p.deliver(pushJob{userID: uid, ttl: time.Minute})
	if got := failures(); got != 0 {
		t.Errorf("a ping that got through should clear the count, got %d", got)
	}
}

// Two instances must not clean at once: the one that doesn't get the lock
// does nothing.
func TestCleanupSkipsWhenAnotherInstanceHoldsTheLock(t *testing.T) {
	db := pushTestDB(t)
	ctx := context.Background()
	conn, err := db.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", cleanupLockID); err != nil {
		t.Fatal(err)
	}
	released := false
	release := func() {
		if !released {
			released = true
			_, _ = conn.Exec(ctx, "SELECT pg_advisory_unlock($1)", cleanupLockID)
		}
	}
	defer release()

	ran := false
	c := NewCleaner(CleanupTask{Name: "probe", Run: func(context.Context, int) (int64, error) {
		ran = true
		return 0, nil
	}})
	_, did, err := c.RunOnce(ctx)
	if err != nil || did || ran {
		t.Fatalf("with the lock held elsewhere: ran=%v task ran=%v err=%v", did, ran, err)
	}

	release()
	if _, did, err := c.RunOnce(ctx); err != nil || !did || !ran {
		t.Fatalf("after it was released: ran=%v task ran=%v err=%v", did, ran, err)
	}
}

func TestCleanupKeepsGoingWhileBatchesAreFullButNotForever(t *testing.T) {
	pushTestDB(t)
	calls := 0
	endless := CleanupTask{Name: "endless", Run: func(_ context.Context, limit int) (int64, error) {
		calls++
		return int64(limit), nil
	}}
	report, _, err := NewCleaner(endless).RunOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if calls != cleanupMaxBatches {
		t.Errorf("an endless backlog ran %d batches, want the cap of %d", calls, cleanupMaxBatches)
	}
	if report["endless"] != int64(cleanupMaxBatches*cleanupBatch) {
		t.Errorf("report says %d deleted", report["endless"])
	}

	calls = 0
	short := CleanupTask{Name: "short", Run: func(_ context.Context, limit int) (int64, error) {
		calls++
		if calls < 3 {
			return int64(limit), nil
		}
		return 7, nil
	}}
	report, _, _ = NewCleaner(short).RunOnce(context.Background())
	if calls != 3 || report["short"] != int64(2*cleanupBatch+7) {
		t.Errorf("stopped after %d batches with %d deleted", calls, report["short"])
	}
}

func TestOneFailingTaskDoesNotStopTheOthers(t *testing.T) {
	pushTestDB(t)
	ranSecond := false
	c := NewCleaner(
		CleanupTask{Name: "broken", Run: func(context.Context, int) (int64, error) { return 0, errors.New("boom") }},
		CleanupTask{Name: "fine", Run: func(context.Context, int) (int64, error) { ranSecond = true; return 1, nil }},
	)
	report, ran, err := c.RunOnce(context.Background())
	if err == nil || !ran {
		t.Fatalf("expected the error to be reported: ran=%v err=%v", ran, err)
	}
	if !ranSecond || report["fine"] != 1 {
		t.Error("a task after a failing one did not run")
	}
}

func TestCleanupStatusReportsCountsOnly(t *testing.T) {
	pushTestDB(t)
	c := NewCleaner(CleanupTask{Name: "things", Run: func(context.Context, int) (int64, error) { return 4, nil }})
	if _, ok := c.Status()["last_run"]; ok {
		t.Error("status shows a run that has not happened")
	}
	if _, _, err := c.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	st := c.Status()
	if st["deleted_total"] != int64(4) {
		t.Errorf("deleted_total = %v, want 4", st["deleted_total"])
	}
	if last, _ := st["last_deleted"].(map[string]int64); last["things"] != 4 {
		t.Errorf("last_deleted = %v", st["last_deleted"])
	}
	if _, ok := st["last_run"]; !ok {
		t.Error("status has no last_run after a run")
	}
}

func TestCleanupIntervalReadsTheSetting(t *testing.T) {
	cases := map[string]time.Duration{
		"10": 10 * time.Minute, " 3 ": 3 * time.Minute, "0": 0, "-5": 0, "soon": 0, "": 0,
	}
	for in, want := range cases {
		old := cleanupEnv()
		setCleanupEnv(in)
		if got := CleanupInterval(); got != want {
			t.Errorf("CLEANUP_INTERVAL_MINUTES=%q gives %v, want %v", in, got, want)
		}
		setCleanupEnv(old)
	}
}

func cleanupEnv() string     { return env.CLEANUP_INTERVAL_MINUTES }
func setCleanupEnv(v string) { env.CLEANUP_INTERVAL_MINUTES = v }
