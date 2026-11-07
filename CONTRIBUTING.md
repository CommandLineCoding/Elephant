# Contributing to Elephant

Thanks for your interest in Elephant! It's a small, friendly project: a Go server, a Flutter app, and the Signal Protocol in between. You don't need to know cryptography to help; most work is ordinary app and server code.

Ways to help:

- Fix a bug or build a feature from the [issue tracker](https://github.com/CommandLineCoding/Elephant/issues)
- Improve the docs ([docs/](docs/), this file, the READMEs)
- Test the app on your phone and [report bugs](https://github.com/CommandLineCoding/Elephant/issues/new/choose)
- Share ideas in [Discussions → Ideas](https://github.com/CommandLineCoding/Elephant/discussions/categories/ideas)

## Find something to work on

- **New here?** Start with [`good first issue`](https://github.com/CommandLineCoding/Elephant/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22). These are small and well scoped, and each one says which files to look at.
- **Done a few PRs?** Try [`help wanted`](https://github.com/CommandLineCoding/Elephant/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) or `difficulty: medium`.
- **Want something big?** Issues labelled `difficulty: hard` (group E2EE, multi-device, calls) are split into sub-issues. Please discuss your approach in the issue before writing code.
- **What's next for the project:** see the [milestones](https://github.com/CommandLineCoding/Elephant/milestones).

Labels tell you where the work is (`area: mobile`, `area: server`, `area: e2ee`, `area: infra`) and how big it is (`good first issue`, `difficulty: medium`, `difficulty: hard`).

**Claiming an issue:** comment that you'd like to take it, and a maintainer will assign you. If there's no activity for two weeks, we may hand it to someone else. Just comment again if you're still on it. Please work on one issue at a time until your first PR is merged.

## Set up

You need Git, Docker (or Podman), and for the app, Flutter. The Flutter version we build with is pinned as `flutter-version` in [.github/workflows/android-release.yaml](.github/workflows/android-release.yaml).

### Server

```bash
git clone https://github.com/<you>/Elephant.git
cd Elephant
cp .env.example .env          # the defaults work locally; Google/GitHub sign-in stays off
docker compose up -d --build  # or: podman-compose up -d --build
curl http://localhost:3000/api/health
```

Compose starts PostgreSQL, applies every migration, and starts the server on port 3000 (`PORT` in `.env`). To run the server outside Docker, see [Local Development](README.md#local-development).

### App

```bash
cd mobile
flutter pub get
flutter run
```

On the sign-in screen, tap the server chip at the bottom (it says **Elephant Cloud**) and point the app at your local server:

| Where the app runs | Host | Port | Use HTTPS/WSS |
|---|---|---|---|
| Android emulator | `10.0.2.2` | `3000` | off |
| Phone over USB/Wi-Fi debugging | `localhost`, after `adb reverse tcp:3000 tcp:3000` | `3000` | off |

Use **Test** in that sheet to check the connection. To try chats, register two accounts, for example one on an emulator and one on a phone.

## Where things live

| Path | What's there |
|---|---|
| [server/routes/](server/routes/) | Every REST route, grouped by area. A good place to start reading |
| [server/controllers/](server/controllers/) | HTTP handlers |
| [server/services/ws.go](server/services/ws.go) | The WebSocket hub: live delivery, typing, read receipts, presence |
| [server/repository/](server/repository/) | SQL queries |
| [server/migrations/](server/migrations/) | Numbered SQL migrations |
| [mobile/lib/controllers/](mobile/lib/controllers/) | App state: auth, inbox, active chat, groups |
| [mobile/lib/services/](mobile/lib/services/) | API client, WebSocket client, Signal Protocol, encrypted local database |
| [mobile/lib/pages/](mobile/lib/pages/) | Screens |
| [docs/API_CONTRACTS.md](docs/API_CONTRACTS.md) | REST, WebSocket and E2EE API reference |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit together |

## Making a change

1. **Branch from `main`**, named `<issue number>-<short-description>`, e.g. `71-search-min-length`.
2. **Keep the PR focused** on one issue. Unrelated cleanups go in their own PR.
3. **Write commit messages** as `type(scope): summary`, e.g. `fix(server): require 2+ characters for user search`. Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`. Scopes: `server`, `mob`, `docs`, `ci`.
4. **Run the checks** for the part you changed:

   ```bash
   # server
   cd server
   gofmt -l <files you changed>   # should print nothing
   go vet ./...
   go test ./...                  # some tests need the Compose stack running

   # app
   cd mobile
   dart format <files you changed>
   flutter analyze
   flutter test
   ```

5. **Open a PR into `main`** and fill in the template. Put `Closes #<issue>` in the description. For UI changes, add screenshots.

A maintainer will review it. Small follow-up commits on the same branch are fine; you don't need to squash.

### Database changes

- Add a **new** file named with the next number, e.g. `013_add_blocked_users_up.sql`. Never edit a migration that's already merged, because it has already run on real databases.
- Make it safe to run twice (`IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`).
- Tick "This PR adds a migration" in the PR template, so maintainers remember to apply it in production.

### API changes

- Update [docs/API_CONTRACTS.md](docs/API_CONTRACTS.md) in the same PR.
- Keep older app versions working. F-Droid users update slowly, so add fields rather than renaming or removing them.

### Encryption and security

Changes under `area: e2ee` (keys, sessions, `signal_service.dart`, `/api/e2ee/*`) need a careful review, so expect more questions on those PRs. To report a vulnerability, follow [SECURITY.md](SECURITY.md) rather than opening a public issue.

## Questions

Ask in [Discussions → Q&A](https://github.com/CommandLineCoding/Elephant/discussions/categories/q-a), or comment on the issue you're working on. No question is too small.

By contributing, you agree that your contributions are licensed under the project's [AGPL-3.0 license](LICENSE), and to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
