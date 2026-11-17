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

	// AUTO_MIGRATE: apply pending database migrations at startup ("false" to disable).
	AUTO_MIGRATE string

	GOOGLE_CLIENT_ID     string
	GOOGLE_CLIENT_SECRET string
	GOOGLE_REDIRECT_URL  string

	GITHUB_CLIENT_ID     string
	GITHUB_CLIENT_SECRET string
	GITHUB_REDIRECT_URL  string

	// ARGON_MAX_CONCURRENT: how many password hashes may run at once. Each uses
	// ARGON_MEMORY of RAM, so this bounds the memory a burst of logins can take.
	ARGON_MAX_CONCURRENT string

	// TRUSTED_PROXY_HOPS: how to find a client's address behind reverse proxies.
	// "auto" (default), "0" (never trust X-Forwarded-For), or the number of
	// proxies in front of the server that append to it.
	TRUSTED_PROXY_HOPS string

	// REGISTRATION: "open" (default) or "closed" to stop new accounts being created.
	REGISTRATION string

	// PUSH_ALLOW_PRIVATE_ENDPOINTS: allow UnifiedPush endpoints on private/loopback
	// addresses over plain HTTP, e.g. a self-hosted ntfy on your LAN. Default "false".
	PUSH_ALLOW_PRIVATE_ENDPOINTS string

	// APP_LINK_FINGERPRINTS: SHA-256 fingerprints (comma-separated) of the
	// certificates Android app builds are signed with, published in
	// /.well-known/assetlinks.json so https profile links open the app
	// directly. Defaults to the key GitHub releases are signed with.
	APP_LINK_FINGERPRINTS string

	// Calls. STUN_URLS: comma-separated STUN servers (default Cloudflare's free
	// one; set it empty for none). TURN relays calls that can't connect
	// directly, from either Cloudflare (CLOUDFLARE_TURN_KEY_ID and
	// CLOUDFLARE_TURN_API_TOKEN), your own coturn (TURN_URLS and TURN_SECRET,
	// coturn's static-auth-secret), or a TURN service with a fixed login
	// (TURN_URLS, TURN_USERNAME and TURN_PASSWORD).
	STUN_URLS                 string
	TURN_URLS                 string
	TURN_SECRET               string
	TURN_USERNAME             string
	TURN_PASSWORD             string
	CLOUDFLARE_TURN_KEY_ID    string
	CLOUDFLARE_TURN_API_TOKEN string
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

	AUTO_MIGRATE = getEnv("AUTO_MIGRATE", "true")

	GOOGLE_CLIENT_ID = getEnv("GOOGLE_CLIENT_ID", "")
	GOOGLE_CLIENT_SECRET = getEnv("GOOGLE_CLIENT_SECRET", "")
	GOOGLE_REDIRECT_URL = getEnv("GOOGLE_REDIRECT_URL", "")

	GITHUB_CLIENT_ID = getEnv("GITHUB_CLIENT_ID", "")
	GITHUB_CLIENT_SECRET = getEnv("GITHUB_CLIENT_SECRET", "")
	GITHUB_REDIRECT_URL = getEnv("GITHUB_REDIRECT_URL", "")

	ARGON_MAX_CONCURRENT = getEnv("ARGON_MAX_CONCURRENT", "2")
	TRUSTED_PROXY_HOPS = getEnv("TRUSTED_PROXY_HOPS", "auto")

	REGISTRATION = getEnv("REGISTRATION", "open")
	PUSH_ALLOW_PRIVATE_ENDPOINTS = getEnv("PUSH_ALLOW_PRIVATE_ENDPOINTS", "false")
	APP_LINK_FINGERPRINTS = getEnv("APP_LINK_FINGERPRINTS",
		"ED:08:4D:C4:C9:06:E1:BB:75:13:80:32:81:2E:BE:0B:A2:2B:A7:8D:A7:3A:26:B8:69:D3:50:53:C0:AB:5F:1D")

	STUN_URLS = getEnv("STUN_URLS", "stun:stun.cloudflare.com:3478")
	TURN_URLS = getEnv("TURN_URLS", "")
	TURN_SECRET = getEnv("TURN_SECRET", "")
	TURN_USERNAME = getEnv("TURN_USERNAME", "")
	TURN_PASSWORD = getEnv("TURN_PASSWORD", "")
	CLOUDFLARE_TURN_KEY_ID = getEnv("CLOUDFLARE_TURN_KEY_ID", "")
	CLOUDFLARE_TURN_API_TOKEN = getEnv("CLOUDFLARE_TURN_API_TOKEN", "")
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}