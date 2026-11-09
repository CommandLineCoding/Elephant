package config

import (
	"context"
	"fmt"
	"io/fs"
	"log"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// migrationLockID is the Postgres advisory lock held while migrating, so two
// instances starting at once don't apply the same migration twice.
const migrationLockID int64 = 7249081115

// legacyProbes tell whether a migration's changes are already in a database
// that was set up by hand, before schema_migrations existed (Elephant Cloud
// was). Only the migrations that existed back then need one; they are not
// all safe to run twice.
var legacyProbes = map[string]string{
	"001_create_users_up.sql":              "SELECT to_regclass('users') IS NOT NULL",
	"002_create_refresh_tokens_up.sql":     "SELECT to_regclass('refresh_tokens') IS NOT NULL",
	"003_add_search_indexes_up.sql":        "SELECT to_regclass('idx_users_display_name') IS NOT NULL",
	"004_create_message_up.sql":            "SELECT to_regclass('messages') IS NOT NULL",
	"005_add_message_status_up.sql":        columnExists("messages", "is_read"),
	"006_create_groups_table_up.sql":       "SELECT to_regclass('groups') IS NOT NULL AND to_regclass('group_members') IS NOT NULL",
	"007_add_group_last_read_up.sql":       columnExists("group_members", "last_read_at"),
	"008_add_message_reply_to_up.sql":      columnExists("messages", "reply_to_message_id"),
	"009_add_oauth_providers_up.sql":       columnExists("users", "google_id"),
	"010_create_e2ee_keys_up.sql":          "SELECT to_regclass('user_devices') IS NOT NULL AND to_regclass('one_time_prekeys') IS NOT NULL",
	"011_create_user_verifications_up.sql": "SELECT to_regclass('user_verifications') IS NOT NULL",
	"012_add_edited_at_to_messages_up.sql": columnExists("messages", "edited_at"),
}

func columnExists(table, column string) string {
	return fmt.Sprintf(`SELECT EXISTS (SELECT 1 FROM information_schema.columns
		WHERE table_schema = current_schema() AND table_name = '%s' AND column_name = '%s')`, table, column)
}

// Migrate applies every pending *_up.sql file in fsys, in filename order, each
// in its own transaction, and records it in schema_migrations (the same table
// migrate.sh uses, so both can be used on one database).
//
// A database that has the users table but no recorded migrations was set up by
// hand. For those, migrations whose changes are already present are recorded
// instead of re-run, and anything missing is applied. That way a deploy can't
// go live with a column missing, which is what broke chat history in v0.3.2.
func Migrate(ctx context.Context, pool *pgxpool.Pool, fsys fs.FS) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire connection: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", migrationLockID); err != nil {
		return fmt.Errorf("take migration lock: %w", err)
	}
	defer func() { _, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", migrationLockID) }()

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		filename TEXT PRIMARY KEY,
		applied_at TIMESTAMPTZ DEFAULT NOW()
	)`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	names, err := fs.Glob(fsys, "*_up.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)

	applied, err := appliedMigrations(ctx, conn)
	if err != nil {
		return err
	}
	legacy := false
	if len(applied) == 0 {
		if err := conn.QueryRow(ctx, "SELECT to_regclass('users') IS NOT NULL").Scan(&legacy); err != nil {
			return fmt.Errorf("check for an existing schema: %w", err)
		}
		if legacy {
			log.Println("Migrations: found an existing schema with no migration history; checking which migrations are already applied")
		}
	}

	pending := 0
	for _, name := range names {
		if applied[name] {
			continue
		}

		if probe, ok := legacyProbes[name]; ok && legacy {
			var present bool
			if err := conn.QueryRow(ctx, probe).Scan(&present); err != nil {
				return fmt.Errorf("check %s: %w", name, err)
			}
			if present {
				if _, err := conn.Exec(ctx, "INSERT INTO schema_migrations (filename) VALUES ($1) ON CONFLICT DO NOTHING", name); err != nil {
					return fmt.Errorf("record %s: %w", name, err)
				}
				log.Printf("Migrations: %s already present, recorded", name)
				continue
			}
		}

		body, err := fs.ReadFile(fsys, name)
		if err != nil {
			return err
		}
		if err := applyMigration(ctx, conn, name, string(body)); err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		log.Printf("Migrations: applied %s", name)
		pending++
	}

	if pending == 0 {
		log.Println("Migrations: database is up to date")
	}
	return nil
}

func appliedMigrations(ctx context.Context, conn *pgxpool.Conn) (map[string]bool, error) {
	rows, err := conn.Query(ctx, "SELECT filename FROM schema_migrations")
	if err != nil {
		return nil, fmt.Errorf("read schema_migrations: %w", err)
	}
	defer rows.Close()

	applied := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		applied[strings.TrimSpace(name)] = true
	}
	return applied, rows.Err()
}

func applyMigration(ctx context.Context, conn *pgxpool.Conn, name, body string) error {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// No arguments, so pgx uses the simple protocol and allows several statements.
	if _, err := tx.Exec(ctx, body); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations (filename) VALUES ($1)", name); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
