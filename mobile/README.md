# Elephant Mobile

The Flutter client for [Elephant](../README.md), a privacy-first messenger. Android is the primary target, and release APKs are published on [GitHub Releases](https://github.com/commandlinecoding/elephant/releases). The app ID is `in.commandlinecoding.elephant`.

## Getting Started

Requirements: a Flutter SDK with Dart `^3.12.0`, plus the Android SDK. CI uses Java 25 (Temurin) for Android builds.

```bash
cd mobile
flutter pub get
flutter run
```

### Pointing the app at a server

The app connects to the public server `elephant.commandlinecoding.in:443` by default. To use a local or self-hosted server, tap **"Connected to: … ⚙️"** on the login screen and enter a host and port. The values are stored in secure storage.

- Port `443` (or any `*.commandlinecoding.in` host) uses `https://` / `wss://`. Every other port uses plain `http://` / `ws://`.
- From the Android emulator, the host machine is reachable at `10.0.2.2`, e.g. host `10.0.2.2`, port `3000`.

### Building release APKs

```bash
flutter build apk --release --split-per-abi --no-tree-shake-icons   # per-ABI APKs
flutter build apk --release --no-tree-shake-icons                   # universal APK
```

The [android-release workflow](../.github/workflows/android-release.yaml) runs the same commands on every `v*` tag and attaches the APKs to the GitHub Release.

### Launcher icon and name

The launcher icon is generated from `assets/launcher/elephant.png`. The configuration is in `pubspec.yaml` under `flutter_launcher_icons` and `launcher_name`.

```bash
dart run flutter_launcher_icons
```

## Architecture

```
lib/
├── main.dart                     # App bootstrap and provider setup
├── core/constants.dart           # Server host/port (Env) and URL builders
├── controllers/
│   ├── auth_state.dart           # Login/register/OAuth deep-link handling, session state
│   └── chat/                     # Inbox, active chat, connection, search, group details
├── models/                       # User, Message, Conversation, Group, InboxItem, WS event
├── pages/                        # auth, home, chat, new chat, settings screens
├── providers/                    # Group controller and timer providers
├── services/
│   ├── api_services.dart         # Dio client with automatic token refresh
│   ├── auth_service.dart         # Token storage (flutter_secure_storage)
│   ├── ws_service.dart           # WebSocket connection, heartbeat, outgoing events
│   ├── chat/chat_event_handler.dart  # Incoming WS events → local DB + UI
│   ├── chat/chat_sync_service.dart   # Replays the offline action queue
│   ├── db_services.dart          # SQLCipher-encrypted local database
│   ├── signal_service.dart       # Signal Protocol keys, sessions, encrypt/decrypt
│   └── sqlite_signal_store.dart  # Signal key/session store backed by the local DB
├── themes/                       # Light/dark themes and theme provider
└── widgets/                      # Shared chat and home widgets
```

### Authentication

- Username/password login and registration go through `/api/auth/*`. Access and refresh tokens are stored in `flutter_secure_storage`.
- `ApiService` refreshes the access token automatically when it expires. Concurrent requests share a single refresh call.
- Google/GitHub sign-in opens `/api/auth/{provider}` in the browser. The server redirects back to `elephant://oauth-callback?access_token=…&refresh_token=…`, and `app_links` picks that up.

### Messaging and offline support

- Messages are written to the local database first (`sync_status = pending`) and added to `action_queue`. They are sent over the WebSocket when connected.
- `ChatSyncService` replays queued actions on reconnect. Each action is retried up to 5 times. The client generates the message UUID, so the server stores the message under the same ID.
- The local database is encrypted with SQLCipher. Its 32-byte random key is kept in secure storage. If the keystore becomes unreadable, the local database is wiped and recreated.

### End-to-end encryption

- On login, if no keys exist on the device yet, the app generates a Signal identity key pair, a signed prekey and 100 one-time prekeys. It uploads the public halves to `/api/e2ee/keys` with `device_id = "main"`.
- To message a contact for the first time, the app fetches the contact's bundle from `/api/e2ee/bundle/{userId}` and builds a session (X3DH). Later messages use the Double Ratchet.
- Direct message `content` is sent as `{"type": <signal message type>, "ciphertext": "<base64>"}`.
- **Group messages are not yet end-to-end encrypted.** They are currently sent as `{"type": 0, "ciphertext": "<plaintext>"}`. Sender Key helpers (`encryptGroupMessage`, `processSenderKeyDistribution`) exist in `SignalService` but aren't wired into sending yet.
- The **Privacy and security** settings screen can reset all sessions to recover from decryption errors.

See [docs/API_CONTRACTS.md](../docs/API_CONTRACTS.md) for the full server protocol.
