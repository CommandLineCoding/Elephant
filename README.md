[![GitHub Release](https://img.shields.io/github/v/release/commandlinecoding/elephant?style=flat-square&color=blue)](https://github.com/commandlinecoding/elephant/releases)
[![Docker Pulls (Docker Hub)](https://img.shields.io/docker/pulls/commandlinecoding/elephant?style=flat-square&logo=docker)](https://hub.docker.com/r/commandlinecoding/elephant)
[![Go Integration & Test Suite](https://github.com/commandlinecoding/elephant/actions/workflows/backend.yaml/badge.svg)](https://github.com/commandlinecoding/elephant/actions)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL-green.svg?style=flat-square)](LICENSE)

---

# Elephant
Elephant is a privacy-first, open-source messaging application built with Go and Flutter. It offers end-to-end encrypted direct messages based on the Signal Protocol, group chats, and real-time delivery over WebSocket. It also supports password and Google/GitHub sign-in, and keeps an encrypted on-device message store.

<img src="./mobile/assets/launcher/elephant.png" width="200" height="200" alt="App Screenshot">

## Features

- **End-to-end encrypted direct messages:** The Signal Protocol (X3DH + Double Ratchet, via `libsignal_protocol_dart`) runs on the device. The server only stores public prekey bundles and opaque ciphertext.
- **Contact verification:** Users can mark a contact's identity key as verified. The verification resets automatically if that contact's identity key changes.
- **Group chats:** Groups have admin/member roles, renaming, member management, unread tracking, and typing indicators and read receipts. *Group messages are not yet end-to-end encrypted.*
- **Real-time messaging:** Chat, typing indicators, read receipts and online presence are delivered over a single WebSocket.
- **Message features:** Users can reply/quote messages and edit their own messages within 15 minutes. Paginated history is available for direct and group chats.
- **Authentication:** Accounts use a username and password (Argon2id) or Google/GitHub OAuth. Short-lived JWT access tokens are paired with rotating refresh tokens.
- **Offline-first client:** The app keeps a local SQLCipher-encrypted database and queues outgoing messages while offline, then replays them on reconnect.
- **Self-hostable:** The app can point at any Elephant server, which is set from the login screen.

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Go 1.26 (chi, pgx, gorilla/websocket, golang-jwt, argon2id, golang.org/x/oauth2) |
| Mobile | Flutter (dio, web_socket_channel, provider, sqflite_sqlcipher, flutter_secure_storage, libsignal_protocol_dart, app_links) |
| Database | PostgreSQL 16 |
| CI/CD | GitHub Actions, Docker Compose, GHCR, Docker Hub |

## GitHub Releases (Mobile Apps)

If you only want to install the app, go to the **[GitHub Releases Page](https://github.com/commandlinecoding/elephant/releases)**.

Each release includes Android APKs: a universal build plus per-ABI builds (`arm64-v8a`, `armeabi-v7a`, `x86_64`).

By default, the app connects to the public server at `elephant.commandlinecoding.in`. To use your own server, tap the server indicator on the login screen and enter its host and port.

---

## Quick Start (Docker Compose, recommended)

[compose.yaml](compose.yaml) starts PostgreSQL, applies all database migrations, then starts the server.

```bash
git clone https://github.com/commandlinecoding/elephant.git
cd elephant

# Copy and fill in environment variables
cp .env.example .env

docker compose up -d
# or: podman-compose up -d
```

The `server` service is built from [server/Dockerfile](server/Dockerfile), so local changes take effect after `docker compose up -d --build`.

Once it's running, verify the server is healthy:

```bash
curl http://HOST:PORT/api/health
```

You should see:

```json
{"success":true,"data":{"postgres":"up","timestamp":"..."}}
```

## Running the Published Image

Prebuilt server images are published on every version tag. The image runs **only** the server binary, so you must provide a PostgreSQL 16 database and apply the migrations yourself (see [Database Migrations](#database-migrations)).

#### Docker Hub
```bash
docker run --name elephant-server \
  -e PORT=3000 \
  -e POSTGRES_HOST=host.docker.internal \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=your_db_user \
  -e POSTGRES_PASSWORD=your_db_password \
  -e POSTGRES_DB=your_db_name \
  -e JWT_SECRET=a_secure_random_secret_of_at_least_32_chars \
  -p 3000:3000 \
  -d commandlinecoding/elephant:latest
```

#### GitHub Container Registry
```bash
podman run --name elephant-server \
  -e PORT=3000 \
  -e POSTGRES_HOST=host.containers.internal \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=your_db_user \
  -e POSTGRES_PASSWORD=your_db_password \
  -e POSTGRES_DB=your_db_name \
  -e JWT_SECRET=a_secure_random_secret_of_at_least_32_chars \
  -p 3000:3000 \
  -d ghcr.io/commandlinecoding/elephant:latest
```

To enable Google/GitHub sign-in, also pass the `GOOGLE_*` / `GITHUB_*` variables listed in [Environment Variables](#environment-variables).

> The server speaks plain HTTP/WS. In production, put it behind a TLS-terminating reverse proxy (e.g. Caddy or nginx) that forwards WebSocket upgrades on `/api/ws`.

## Local Development

### Running the backend without Docker

```bash
cd server
go mod download
go run main.go
```

The server looks for a `.env` file in the current directory and every parent directory, so the repo-root `.env` is picked up automatically. Make sure PostgreSQL is reachable with the `POSTGRES_*` values and that migrations have been applied.

### Database Migrations

SQL migrations live in [server/migrations/](server/migrations/) as numbered `NNN_*_up.sql` files. [server/migrate.sh](server/migrate.sh) applies them in order and records each one in a `schema_migrations` table, so re-running it is safe. Docker Compose runs it automatically through the `migration` service.

To run it against your own database:

```bash
docker run --rm \
  -v ./server/migrations:/migrations:z \
  -v ./server/migrate.sh:/migrate.sh:z \
  -e POSTGRES_HOST=<db host> -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=<user> -e POSTGRES_PASSWORD=<password> -e POSTGRES_DB=<db> \
  postgres:16-alpine sh /migrate.sh
```

### Running the mobile app

```bash
cd mobile
flutter pub get
flutter run
```

See [mobile/README.md](mobile/README.md) for details on pointing the app at a local server and on how the client is structured.

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `HOST` | Host shown in the startup log. The server binds to `0.0.0.0` when this is `localhost`, `127.0.0.1` or empty | `127.0.0.1` |
| `PORT` | Server port | `3000` |
| `POSTGRES_USER` | Database username | `postgres` |
| `POSTGRES_PASSWORD` | Database password | `very_strong_password` |
| `POSTGRES_DB` | Database name | `myapi_db` |
| `POSTGRES_PORT` | Database port | `5432` |
| `POSTGRES_HOST` | Database host | `localhost` |
| `JWT_SECRET` | Secret key for signing JWTs (HS256). **Always set this**, because the built-in default is public | `default-long-safe-secret-key-string` |
| `ARGON_MEMORY` | Argon2id memory cost (KiB) | `65536` |
| `ARGON_ITERATIONS` | Argon2id iteration count | `3` |
| `ARGON_PARALLELISM` | Argon2id parallelism degree | `2` |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID | — |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret | — |
| `GOOGLE_REDIRECT_URL` | Google OAuth callback URL, e.g. `https://HOST/api/auth/google/callback` | — |
| `GITHUB_CLIENT_ID` | GitHub OAuth client ID | — |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth client secret | — |
| `GITHUB_REDIRECT_URL` | GitHub OAuth callback URL, e.g. `https://HOST/api/auth/github/callback` | — |

See [.env.example](.env.example) for a starting template. In Docker Compose, `POSTGRES_PORT` sets the **host** port that the database is published on. The server always connects to `db:5432` inside the network.

## API

Check out the [API documentation](docs/API_CONTRACTS.md) for every REST endpoint, the WebSocket event protocol, and the E2EE key-distribution endpoints.

### Registration note

Usernames are normalized to lowercase and always given a random 4-digit discriminator, e.g. registering as `abc` results in a username such as `abc.4821`. Log in with the full username returned in the registration response. OAuth accounts get a username derived from the email handle in the same format.

## Testing

Run the backend checks and test suite:

```bash
cd server
go vet ./...
go test -v ./...
```

Some tests need a live database and server: the repository tests, the controller tests, and the integration tests under [server/tests/](server/tests/). Start the stack first (and apply migrations), then run:

```bash
HOST=$HOST PORT=$PORT go test -v ./tests/...
```

For the mobile app:

```bash
cd mobile
flutter analyze
```

### CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| [backend.yaml](.github/workflows/backend.yaml) | Every push and PR | `go vet`, staticcheck, then starts PostgreSQL + server and runs `go test ./...` |
| [release.yaml](.github/workflows/release.yaml) | `v*` tag | Builds and pushes the server image to GHCR |
| [docker-release.yaml](.github/workflows/docker-release.yaml) | `v*` tag | Builds and pushes the server image to Docker Hub |
| [android-release.yaml](.github/workflows/android-release.yaml) | `v*` tag | Runs `flutter analyze`, builds universal and split-ABI APKs, and attaches them to the GitHub Release |

## Project Structure

```
elephant/
├── .github/                  # Issue templates and GitHub Actions workflows
├── docs/
│   └── API_CONTRACTS.md      # REST, WebSocket and E2EE API reference
├── metadata/                 # F-Droid / store listing metadata
├── mobile/                   # Flutter client (see mobile/README.md)
│   ├── android/
│   ├── ios/
│   ├── assets/
│   ├── lib/
│   └── pubspec.yaml
├── server/                   # Go backend
│   ├── config/               # Router, DB pool, Argon2, OAuth configuration
│   ├── controllers/          # HTTP and WebSocket handlers
│   ├── env/                  # Environment variable loading (.env lookup)
│   ├── errors/               # Error definitions
│   ├── middlewares/          # Auth, group membership/admin guards, CORS, logging, rate limiting
│   ├── migrations/           # Numbered SQL migrations (*_up.sql)
│   ├── models/               # Request/response and domain models
│   ├── repository/           # Database access layer
│   ├── routes/               # Route definitions (/auth, /users, /messages, /groups, /e2ee)
│   ├── services/             # Business logic (auth, JWT, OAuth, messages, E2EE, WebSocket hub)
│   ├── tests/                # Integration tests
│   ├── migrate.sh            # Migration runner used by Docker Compose
│   └── Dockerfile
├── compose.yaml              # PostgreSQL + migrations + server (built from source)
├── .env.example              # Environment variable template
├── SECURITY.md
├── CODE_OF_CONDUCT.md
└── LICENSE
```

## Contributing

Contributions are welcome. Please open an issue using one of the [issue templates](.github/ISSUE_TEMPLATE/) before starting larger changes, and follow the [pull request template](.github/ISSUE_TEMPLATE/pull_request_template.md). Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

To report a security issue, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

Elephant is licensed under the AGPL-3.0. See [LICENSE](LICENSE) for details.
