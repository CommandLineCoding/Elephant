package env

import (
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
)

// global variables
var (
	HOST string
	PORT string

	POSTGRES_USER     string
	POSTGRES_PASSWORD string
	POSTGRES_DB       string
	POSTGRES_PORT     string
	POSTGRES_HOST     string

	JWT_SECRET string

	ARGON_MEMORY      string
	ARGON_ITERATIONS  string
	ARGON_PARALLELISM string

	GOOGLE_CLIENT_ID     string
	GOOGLE_CLIENT_SECRET string
	GOOGLE_REDIRECT_URL  string

	GITHUB_CLIENT_ID     string
	GITHUB_CLIENT_SECRET string
	GITHUB_REDIRECT_URL  string

	// REGISTRATION: "open" (default) or "closed" to stop new accounts being created.
	REGISTRATION string
)

func init() {
	cwd, err := os.Getwd()
	if err == nil {
		for {
			target := filepath.Join(cwd, ".env")
			if _, err := os.Stat(target); err == nil {
				_ = godotenv.Load(target)
				break
			}
			parent := filepath.Dir(cwd)
			if parent == cwd {
				break
			}
			cwd = parent
		}
	}

	HOST = getEnv("HOST", "127.0.0.1")
	PORT = getEnv("PORT", "3000")

	POSTGRES_USER = getEnv("POSTGRES_USER", "postgres")
	POSTGRES_PASSWORD = getEnv("POSTGRES_PASSWORD", "very_strong_password")
	POSTGRES_DB = getEnv("POSTGRES_DB", "myapi_db")
	POSTGRES_PORT = getEnv("POSTGRES_PORT", "5432")
	POSTGRES_HOST = getEnv("POSTGRES_HOST", "localhost")

	JWT_SECRET = getEnv("JWT_SECRET", "default-long-safe-secret-key-string")

	ARGON_MEMORY = getEnv("ARGON_MEMORY", "65536")
	ARGON_ITERATIONS = getEnv("ARGON_ITERATIONS", "3")
	ARGON_PARALLELISM = getEnv("ARGON_PARALLELISM", "2")

	GOOGLE_CLIENT_ID = getEnv("GOOGLE_CLIENT_ID", "")
	GOOGLE_CLIENT_SECRET = getEnv("GOOGLE_CLIENT_SECRET", "")
	GOOGLE_REDIRECT_URL = getEnv("GOOGLE_REDIRECT_URL", "")

	GITHUB_CLIENT_ID = getEnv("GITHUB_CLIENT_ID", "")
	GITHUB_CLIENT_SECRET = getEnv("GITHUB_CLIENT_SECRET", "")
	GITHUB_REDIRECT_URL = getEnv("GITHUB_REDIRECT_URL", "")

	REGISTRATION = getEnv("REGISTRATION", "open")
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}