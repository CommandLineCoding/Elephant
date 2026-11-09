package config

import (
	"context"
	"fmt"
	"io/fs"
	"sort"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/commandlinecoding/elephant/server/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
)

// isolatedPool returns a pool whose connections use a fresh, empty schema, so
// each test starts from nothing and can't affect other tests or real data.
// The test is skipped when no database is reachable.
func isolatedPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()

	admin, err := pgxpool.New(ctx, databaseURL())
	if err == nil {
		err = admin.Ping(ctx)
	}
	if err != nil {
		t.Skipf("no database available: %v", err)
	}

	schema := fmt.Sprintf("mig_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}

	cfg, err := pgxpool.ParseConfig(databaseURL())
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		pool.Close()
		_, _ = admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE")
		admin.Close()
	})
	return pool
}

func embeddedMigrations(t *testing.T) []string {
	t.Helper()
	names, err := fs.Glob(migrations.FS, "*_up.sql")
	if err != nil || len(names) == 0 {
		t.Fatalf("no embedded migrations: %v", err)
	}
	sort.Strings(names)
	return names
}

// applyByHand runs migration files directly, the way production was set up.
func applyByHand(t *testing.T, pool *pgxpool.Pool, names []string) {
	t.Helper()
	for _, n := range names {
		body, err := fs.ReadFile(migrations.FS, n)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(context.Background(), string(body)); err != nil {
			t.Fatalf("applying %s by hand: %v", n, err)
		}
	}
}

func recorded(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM schema_migrations").Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func hasColumn(t *testing.T, pool *pgxpool.Pool, table, column string) bool {
	t.Helper()
	var ok bool
	if err := pool.QueryRow(context.Background(), columnExists(table, column)).Scan(&ok); err != nil {
		t.Fatal(err)
	}
	return ok
}

func TestLegacyProbesCoverEmbeddedMigrations(t *testing.T) {
	have := map[string]bool{}
	for _, n := range embeddedMigrations(t) {
		have[n] = true
	}
	for n := range legacyProbes {
		if !have[n] {
			t.Errorf("legacy probe for %s, which is not an embedded migration (renamed?)", n)
		}
	}
}

func TestMigrateFreshDatabase(t *testing.T) {
	pool := isolatedPool(t)
	ctx := context.Background()
	names := embeddedMigrations(t)

	if err := Migrate(ctx, pool, migrations.FS); err != nil {
		t.Fatal(err)
	}
	if got := recorded(t, pool); got != len(names) {
		t.Errorf("recorded %d migrations, want %d", got, len(names))
	}
	if !hasColumn(t, pool, "messages", "edited_at") {
		t.Error("messages.edited_at is missing after migrating")
	}

	// Running again is a no-op.
	if err := Migrate(ctx, pool, migrations.FS); err != nil {
		t.Fatalf("second run failed: %v", err)
	}
	if got := recorded(t, pool); got != len(names) {
		t.Errorf("second run changed the history: %d recorded", got)
	}
}

// Elephant Cloud: every migration applied by hand, and no schema_migrations table.
func TestMigrateExistingDatabaseThatIsComplete(t *testing.T) {
	pool := isolatedPool(t)
	names := embeddedMigrations(t)
	applyByHand(t, pool, names)

	// 001, 002, 004, 005, 006, 007 and 008 would fail if run a second time.
	if err := Migrate(context.Background(), pool, migrations.FS); err != nil {
		t.Fatalf("migrating a complete existing database failed: %v", err)
	}
	if got := recorded(t, pool); got != len(names) {
		t.Errorf("recorded %d migrations, want %d", got, len(names))
	}
}

// The v0.3.2 outage: production had migrations up to 011 applied by hand but
// not 012 (and, later, nothing after it). They must all be applied at startup.
func TestMigrateExistingDatabaseMissingRecentMigrations(t *testing.T) {
	pool := isolatedPool(t)
	names := embeddedMigrations(t)

	const firstMissing = "012_add_edited_at_to_messages_up.sql"
	var present []string
	for _, n := range names {
		if n < firstMissing {
			present = append(present, n)
		}
	}
	applyByHand(t, pool, present)
	if hasColumn(t, pool, "messages", "edited_at") {
		t.Fatal("test setup is wrong: edited_at should not exist yet")
	}

	if err := Migrate(context.Background(), pool, migrations.FS); err != nil {
		t.Fatal(err)
	}
	if !hasColumn(t, pool, "messages", "edited_at") {
		t.Error("the missing migration was not applied")
	}
	if got := recorded(t, pool); got != len(names) {
		t.Errorf("recorded %d migrations, want %d", got, len(names))
	}
}

// Compose runs migrate.sh, which records the same filenames.
func TestMigrateTrustsRecordedHistory(t *testing.T) {
	pool := isolatedPool(t)
	ctx := context.Background()
	names := embeddedMigrations(t)
	applyByHand(t, pool, names)
	if _, err := pool.Exec(ctx, "CREATE TABLE schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ DEFAULT NOW())"); err != nil {
		t.Fatal(err)
	}
	for _, n := range names {
		if _, err := pool.Exec(ctx, "INSERT INTO schema_migrations (filename) VALUES ($1)", n); err != nil {
			t.Fatal(err)
		}
	}

	if err := Migrate(ctx, pool, migrations.FS); err != nil {
		t.Fatalf("re-ran migrations that were already recorded: %v", err)
	}
}

func TestMigrateRollsBackAFailedMigration(t *testing.T) {
	pool := isolatedPool(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"001_ok_up.sql":   {Data: []byte("CREATE TABLE good (id int);")},
		"002_bad_up.sql":  {Data: []byte("CREATE TABLE half_done (id int);\nTHIS IS NOT SQL;")},
		"003_next_up.sql": {Data: []byte("CREATE TABLE never_reached (id int);")},
	}

	err := Migrate(ctx, pool, fsys)
	if err == nil {
		t.Fatal("expected an error from the broken migration")
	}

	var halfDone, never bool
	_ = pool.QueryRow(ctx, "SELECT to_regclass('half_done') IS NOT NULL").Scan(&halfDone)
	_ = pool.QueryRow(ctx, "SELECT to_regclass('never_reached') IS NOT NULL").Scan(&never)
	if halfDone {
		t.Error("the failed migration was not rolled back")
	}
	if never {
		t.Error("migrations after the failure should not run")
	}
	if got := recorded(t, pool); got != 1 {
		t.Errorf("recorded %d migrations, want only the one that succeeded", got)
	}
}

// Two instances starting together must not apply the same migration twice.
func TestMigrateConcurrentStartup(t *testing.T) {
	pool := isolatedPool(t)
	names := embeddedMigrations(t)

	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- Migrate(context.Background(), pool, migrations.FS)
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Errorf("concurrent migrate failed: %v", err)
		}
	}
	if got := recorded(t, pool); got != len(names) {
		t.Errorf("recorded %d migrations, want %d", got, len(names))
	}
}
