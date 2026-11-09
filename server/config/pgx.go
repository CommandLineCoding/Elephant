package config

import (
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/jackc/pgx/v5/pgxpool"
)

var DB *pgxpool.Pool

func isPrivateOrLocal(host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))

	// Local hostnames and Docker container service names
	if h == "localhost" || h == "postgres" || h == "db" || h == "host.docker.internal" {
		return true
	}

	// Parse IP and check RFC 1918 private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) and Loopbacks
	ip := net.ParseIP(h)
	if ip != nil {
		return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified()
	}

	// Fallback string prefix checks
	return strings.HasPrefix(h, "10.") ||
		strings.HasPrefix(h, "192.168.") ||
		strings.HasPrefix(h, "127.")
}

// databaseURL builds the connection string from the POSTGRES_* variables.
func databaseURL() string {
	sslMode := "require"
	if isPrivateOrLocal(env.POSTGRES_HOST) {
		sslMode = "disable"
	}

	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		env.POSTGRES_USER,
		env.POSTGRES_PASSWORD,
		env.POSTGRES_HOST,
		env.POSTGRES_PORT,
		env.POSTGRES_DB,
		sslMode,
	)
}

func InitDatabase() {
	dsn := databaseURL()

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("Unable to parse database DSN config string: %v", err)
	}

	cfg.MaxConns = 25                      // Prevent socket exhaustion on standard containers
	cfg.MinConns = 5                       // Keep cold start latency low
	cfg.MaxConnLifetime = 30 * time.Minute // Cycle old sockets out safely
	cfg.MaxConnIdleTime = 15 * time.Minute // Prune idle workers under low load

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	DB, err = pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Fatalf("Failed to initialize production pgxpool framework: %v", err)
	}

	if err := DB.Ping(ctx); err != nil {
		log.Fatalf("Database validation ping failed: %v", err)
	}

	log.Println("PostgreSQL connection pool running with production configurations!")
}
