# Elephant Messenger API Contracts

## Global Requirements & Configuration

- **Base URL:** `http://HOST:PORT/api` (every route below is mounted under `/api`)
- **Default Content-Type:** `application/json`
- **Authorization:** `Authorization: Bearer <access_token>` on every protected route
- **Timestamp Format:** `RFC3339 / ISO8601` (e.g. `2026-10-04T12:34:56.789Z`)
- **IDs:** All user, group and message IDs are UUIDs
- **CORS:** `Access-Control-Allow-Origin: *`; allowed methods `GET, POST, PUT, DELETE, OPTIONS`

### Response envelope

Every JSON response uses the same envelope. `data` is omitted on errors, and `error` is omitted on success.

```json
{
  "success": true,
  "data": { },
  "error": "<message>"
}
```

### Tokens

| Token | Lifetime | Notes |
|---|---|---|
| Access token | 15 minutes | HS256 JWT, `sub` = user ID, `sid` = the signed-in device. Send it as a Bearer token, or as `?token=` for the WebSocket |
| Refresh token | 7 days | HS256 JWT. Its hash is stored server-side. Each refresh **rotates** it, so the old refresh token stops working. The device (`sid`) stays the same across refreshes |

Each sign-in is one *session*, shown to the person as a signed-in device (see [Signed-in devices](#11-signed-in-devices)). Signing a session out deletes its refresh token, so it can't refresh, and its WebSocket is closed. Its current access token still works for HTTP requests until it expires (at most 15 minutes), but it can't open a new WebSocket.

### Common error: `401 Unauthorized`

Every route behind the auth guard returns this when the access token is missing, expired or malformed. The sections below don't repeat it.

```json
{
  "success": false,
  "error": "Access token missing, expired or malformed"
}
```

### Common errors: `404` and `405`

A request to a route that doesn't exist returns `404`, and a known path with the wrong HTTP method returns `405`. Both use the usual envelope. Routes behind the auth guard answer `401` first when the token is missing.

```json
{ "success": false, "error": "Route not found" }
```

```json
{ "success": false, "error": "Method not allowed" }
```

---

## API Overview

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| GET | [/api/health](#health-endpoint) | No | Health check (server + database status) |
| GET | [/u/{username}](#profile-links) | No | Profile link page for people without the app |
| GET | [/.well-known/assetlinks.json](#profile-links) | No | Android app-link declaration |
| POST | [/api/auth/register](#1-register-user) | No | Register a new user |
| POST | [/api/auth/login](#2-login-user) | No | Log in and receive a token pair |
| POST | [/api/auth/login/2fa](#6-two-step-sign-in) | No | Finish a sign-in that asked for an authenticator code |
| POST | [/api/auth/refresh](#3-refresh) | No | Rotate a refresh token for a new token pair |
| GET | [/api/auth/{provider}](#4-oauth-redirect) | No | Start Google / GitHub OAuth sign-in |
| GET | [/api/auth/{provider}/callback](#5-oauth-callback) | No | OAuth callback that hands tokens back to the app |
| GET | [/api/users/me](#1-user-me) | Yes | Get the authenticated user's profile |
| GET | [/api/users/{id}](#2-get-user-by-id) | Yes | Get a user by ID |
| GET | [/api/users/search?q=&page=&limit=](#3-search-users) | Yes | Search users by username or display name (rate limited) |
| DELETE | [/api/users/me](#4-delete-account) | Yes | Permanently delete the authenticated user's account |
| PATCH | [/api/users/me](#10-update-your-profile) | Yes | Change your display name or username (once every 30 days) |
| POST | [/api/users/me/push](#5-register-a-push-endpoint) | Yes | Register a UnifiedPush endpoint for new-message pings |
| DELETE | [/api/users/me/push](#6-remove-a-push-endpoint) | Yes | Remove a UnifiedPush endpoint |
| POST | [/api/users/{id}/block](#7-block-a-user) | Yes | Block a user |
| DELETE | [/api/users/{id}/block](#8-unblock-a-user) | Yes | Unblock a user |
| GET | [/api/users/me/blocked](#9-list-blocked-users) | Yes | List the people you blocked |
| GET | [/api/users/me/settings](#12-privacy-settings) | Yes | Get your privacy settings |
| POST | [/api/reports](#reports-endpoints) | Yes | Report someone for spam or abuse (rate limited) |
| GET | [/api/admin/reports?limit=&before=](#reports-endpoints) | Admin | The server admin's list of reports |
| POST | [/api/status](#post-a-status) | Yes | Post a text status, encrypted for each contact |
| GET | [/api/status](#list-statuses) | Yes | The statuses posted for you |
| GET | [/api/status/mine](#list-your-statuses) | Yes | Your statuses, and who has seen them |
| DELETE | [/api/status/{id}](#delete-a-status) | Yes | Remove your status early |
| POST | [/api/status/{id}/view](#mark-a-status-seen) | Yes | Say you saw a status |
| PATCH | [/api/users/me/settings](#12-privacy-settings) | Yes | Change your privacy settings |
| GET | [/api/users/me/export](#13-export-your-data) | Yes | Everything the server keeps about you, as one JSON document (rate limited) |
| GET | [/api/users/me/2fa](#6-two-step-sign-in) | Yes | Whether two-step sign-in is on |
| POST | [/api/users/me/2fa/setup](#6-two-step-sign-in) | Yes | Get a secret for an authenticator app |
| POST | [/api/users/me/2fa/enable](#6-two-step-sign-in) | Yes | Confirm a code and turn it on |
| POST | [/api/users/me/2fa/disable](#6-two-step-sign-in) | Yes | Turn it off (password and a code) |
| GET | [/api/users/me/sessions](#11-signed-in-devices) | Yes | List the devices you are signed in on |
| DELETE | [/api/users/me/sessions/{id}](#11-signed-in-devices) | Yes | Sign one device out |
| DELETE | [/api/users/me/sessions](#11-signed-in-devices) | Yes | Sign out every device but this one |
| GET | [/api/calls/ice-servers](#ice-servers) | Yes | STUN/TURN servers and credentials for a call (rate limited) |
| GET | [/api/calls/pending](#pending-call) | Yes | The call ringing for you, after a push woke the app (rate limited) |
| GET | [/api/ws?token=](#1-connect-to-websocket) | Yes (query) | WebSocket upgrade endpoint |
| WS | [Client → Server](#2-client-to-server-messages) | — | Events the client sends |
| WS | [Server → Client](#3-server-to-client-messages) | — | Events the server pushes |
| WS | [Calls](#4-calls) | — | 1:1 voice call signalling |
| POST | [/api/messages](#1-send-message) | Yes | Send a direct message (REST fallback, no live delivery) |
| GET | [/api/messages?with=&before=&limit=](#2-direct-message-history) | Yes | Paginated direct message history |
| GET | [/api/messages/conversations](#3-conversations) | Yes | Inbox: latest message and unread count per chat |
| PUT | [/api/messages/{id}](#4-edit-message) | Yes | Edit your own message (15-minute window) |
| POST | [/api/messages/read](#5-mark-direct-messages-read) | Yes | Mark a sender's messages as read |
| POST | [/api/messages/requests/{userId}/accept](#8-accept-a-message-request) | Yes | Accept a message request |
| DELETE | [/api/messages/conversations/{userId}?for=me\|everyone](#6-delete-a-direct-conversation) | Yes | Delete a direct conversation for you, or your messages for both people |
| DELETE | [/api/messages/{id}?for=me\|everyone](#7-delete-a-message) | Yes | Delete one message for you, or one of yours for everyone |
| POST | [/api/groups](#1-create-group) | Yes | Create a group |
| GET | [/api/groups](#2-list-my-groups) | Yes | List the groups you belong to |
| GET | [/api/groups/{id}](#3-get-group-by-id) | Member | Get group details |
| GET | [/api/groups/{id}/messages?before=&limit=](#4-group-message-history) | Member | Paginated group message history |
| GET | [/api/groups/{id}/members](#5-group-members) | Member | List group members |
| POST | [/api/groups/{id}/leave](#6-leave-group) | Member | Leave a group |
| PATCH | [/api/groups/{id}](#7-update-group-details) | Admin | Rename a group |
| POST | [/api/groups/{id}/members](#8-add-member-to-group) | Admin | Add a member |
| DELETE | [/api/groups/{id}/members/{userId}](#9-remove-member-from-group) | Admin | Remove a member |
| DELETE | [/api/groups/{id}/history](#10-clear-group-history) | Member | Clear a group's messages for you only |
| DELETE | [/api/groups/{id}](#11-delete-group) | Admin | Delete a group, its members and messages |
| GET, PUT, DELETE | [/api/groups/{id}/invite](#12-group-invite-link) | Admin | See, create or reset, and turn off the group's invite link |
| GET | [/api/groups/{id}/requests](#13-join-requests) | Admin | Who is waiting to be let in |
| POST, DELETE | [/api/groups/{id}/requests/{userId}](#13-join-requests) | Admin | Let someone in, or turn them down |
| GET | [/api/invites/{code}](#14-using-an-invite-link) | Yes | What an invite link is for: the group's name and size |
| POST | [/api/invites/{code}/join](#14-using-an-invite-link) | Yes | Join with an invite link, or ask to |
| POST | [/api/e2ee/keys](#1-upload-prekey-bundle) | Yes | Upload identity key, signed prekey and one-time prekeys |
| GET | [/api/e2ee/bundle/{userId}?device_id=](#2-fetch-prekey-bundle) | Yes | Fetch a user's prekey bundle (consumes one one-time prekey) |
| POST | [/api/e2ee/verify](#3-set-contact-verification) | Yes | Mark a contact's identity key as verified or unverified |
| GET | [/api/e2ee/verify/{userId}](#4-get-contact-verification) | Yes | Get your verification status for a contact |
| POST | [/api/e2ee/reset](#5-reset-encryption-keys) | Yes | Wipe all of your server-side keys (password re-auth) |

---

## Health Endpoint

Reports the status of the server and its PostgreSQL connection pool.

- **URL:** `/api/health`
- **Method:** `GET`
- **Authentication Required:** `NO`
- **curl:** `curl -s http://HOST:PORT/api/health | jq .`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "postgres": "up",
    "registration": "open",
    "cleanup": {
      "deleted_total": 12,
      "last_run": "<Timestamp>",
      "last_deleted": { "refresh_tokens": 12, "messages": 3, "statuses": 1, "push_endpoints": 0 }
    },
    "timestamp": "<Timestamp>"
  }
}
```

`registration` is `"open"` or `"closed"` (the server's `REGISTRATION` setting), so clients can hide their sign-up option on servers that don't accept new accounts.

`cleanup` is the background job that deletes expired data: refresh tokens, [disappearing messages](#disappearing-messages), [statuses](#status-endpoints) and dead push endpoints (see `CLEANUP_INTERVAL_MINUTES`). It holds counts only: how many rows this server instance has deleted since it started, and what its last run deleted. `last_run` and `last_deleted` are missing until the job has run on this instance, for example when another instance holds the lock.

#### `500 Internal Server Error`

Returned when the database ping fails.

```json
{
  "success": false,
  "data": {
    "postgres": "down",
    "timestamp": "<Timestamp>"
  },
  "error": "Database engine unreachable"
}
```

---

## Profile and Group Links

Served at the root, outside `/api`.

- **`GET /u/{username}`**: a small HTML page for someone who opens a profile link (`https://<host>/u/alex.4821`) without the app: the username, an **Open in Elephant** link (`elephant://u/alex.4821`) and where to get the app. Anything that isn't a full username (`name.1234`) gives `404`. With the app installed, Android opens the chat instead.
- **`GET /g/{code}`**: the same for a [group invite link](#12-group-invite-link) (`https://<host>/g/<code>`, or `elephant://g/<code>`): a page with an **Open in Elephant** link. It doesn't name the group, since anything that sees the link, such as a chat app making a preview, can fetch it. A code that isn't 32 letters, digits, `-` and `_` gives `404`.
- **`GET /.well-known/assetlinks.json`**: tells Android that the Elephant app (`in.commandlinecoding.elephant`) may open `https://<host>/u/…` and `/g/…` links directly. The certificate fingerprints come from `APP_LINK_FINGERPRINTS`. The app only claims https links for `elephant.commandlinecoding.in`, so on other servers profile and group links use the `elephant://` form.

---

## Authentication Endpoints

### 1. Register User

- **URL:** `/api/auth/register`
- **Method:** `POST`
- **Authentication Required:** `NO`
- **curl:** `curl -X POST http://HOST:PORT/api/auth/register -H "Content-Type: application/json" -d '{ "username": "<username>", "display_name": "Full Name", "password": "<password>" }' -s`

#### Request Body

```json
{
  "username": "<username>",
  "display_name": "Full Name",
  "password": "<password>",
  "device_name": "Pixel 8"
}
```

`device_name` is optional: what the app calls this phone, shown in the person's list of signed-in devices. Extra spaces are collapsed and it is cut to 60 characters.

#### Validation rules

- `username` is trimmed and lowercased. It must then be 3–25 characters and contain only `a-z` and `0-9`.
- `password` must be at least 8 characters. It is hashed with Argon2id.
- `display_name` must not be empty.

#### Note

The server **always** appends a random 4-digit discriminator (1000–9999) to the requested username, e.g. `abc` → `abc.4130`. Use the full username returned in the response to log in.

#### `201 Created`

```json
{
  "success": true,
  "data": {
    "tokens": {
      "access_token": "<access_token>",
      "refresh_token": "<refresh_token>"
    },
    "user": {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "username": "<username>.1234",
      "display_name": "Full Name",
      "created_at": "<Timestamp>"
    }
  }
}
```

#### `400 Bad Request`

Returned for malformed JSON (`"Invalid payload syntax"`) or a failed validation rule. Examples:

```json
{ "success": false, "error": "username prefix must be between 3 and 25 characters" }
```
```json
{ "success": false, "error": "username prefix must contain only alphanumeric characters" }
```
```json
{ "success": false, "error": "password must be at least 8 characters long" }
```
```json
{ "success": false, "error": "display name cannot be empty" }
```

#### `403 Forbidden`

The server has `REGISTRATION=closed`. Existing users can still log in.

```json
{ "success": false, "error": "Registration is closed on this server" }
```

#### `429 Too Many Requests`

Each client address may make a burst of 5 sign-ups, then one every 20 seconds. The response has a `Retry-After` header (seconds).

```json
{ "success": false, "error": "Too many sign-up attempts. Please wait a moment and try again." }
```

#### `503 Service Unavailable`

Password hashing is capped (`ARGON_MAX_CONCURRENT`) to bound memory. Requests wait their turn and give up after about 10 seconds. The response has `Retry-After: 2`. Retry shortly.

```json
{ "success": false, "error": "the server is busy, please try again in a moment" }
```

#### `500 Internal Server Error`

`"Token generation failure"` or `"Failed to securely record registration token metrics"`.

### 2. Login User

- **URL:** `/api/auth/login`
- **Method:** `POST`
- **Authentication Required:** `NO`
- **curl:** `curl -X POST http://HOST:PORT/api/auth/login -H "Content-Type: application/json" -d '{ "username": "<username>", "password": "<password>" }' -s`

#### Request Body

```json
{
  "username": "<username>.1234",
  "password": "<password>",
  "device_name": "Pixel 8"
}
```

The username is trimmed and lowercased before lookup. `device_name` is optional, as in [Register](#1-register-user).

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "tokens": {
      "access_token": "<access_token>",
      "refresh_token": "<refresh_token>"
    },
    "user": {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "username": "<username>.1234",
      "display_name": "Full Name",
      "created_at": "<Timestamp>"
    }
  }
}
```

#### `200 OK` with two-step sign-in

If the password is right and the account has [two-step sign-in](#6-two-step-sign-in) on, there are no tokens yet. The reply is a challenge to answer with a code from the authenticator app, within 5 minutes, at [`/api/auth/login/2fa`](#6-two-step-sign-in):

```json
{
  "success": true,
  "data": {
    "two_factor_required": true,
    "challenge": "<challenge>"
  }
}
```

An app that doesn't know about this sees `success: true` with no `tokens`, and has to treat that as a failure.

#### `401 Unauthorized`

```json
{
  "success": false,
  "error": "invalid username or password credentials"
}
```

#### `400 Bad Request`

```json
{
  "success": false,
  "error": "Invalid json payload structure"
}
```

#### `429 Too Many Requests`

Each client address may make a burst of 10 sign-in attempts, then one every 5 seconds. The response has a `Retry-After` header (seconds).

```json
{ "success": false, "error": "Too many sign-in attempts. Please wait a moment and try again." }
```

#### `503 Service Unavailable`

Password hashing is capped (`ARGON_MAX_CONCURRENT`) to bound memory. Requests wait their turn and give up after about 10 seconds. The response has `Retry-After: 2`. Retry shortly.

```json
{ "success": false, "error": "the server is busy, please try again in a moment" }
```

### 3. Refresh

Exchanges a refresh token for a new access/refresh pair. The submitted refresh token is revoked.

- **URL:** `/api/auth/refresh`
- **Method:** `POST`
- **Authentication Required:** `NO`
- **curl:** `curl -X POST http://HOST:PORT/api/auth/refresh -H "Content-Type: application/json" -d '{ "refresh_token": "<refresh_token>" }' -s`

#### Request Body

```json
{
  "refresh_token": "<refresh_token>",
  "device_name": "Pixel 8"
}
```

`device_name` is optional. It names the device if it has no name yet, which is how a phone that signed in with Google or GitHub (in a browser, which can't say what phone it is) gets one.

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "access_token": "<access_token>",
    "refresh_token": "<refresh_token>"
  }
}
```

#### `400 Bad Request`

`"Invalid json payload structure"` or `"Refresh token parameter missing"`.

#### `401 Unauthorized`

```json
{ "success": false, "error": "invalid or altered refresh token payload" }
```
```json
{ "success": false, "error": "refresh token expired or revoked" }
```

### 4. OAuth Redirect

Starts the OAuth sign-in flow. The app opens this URL in a browser.

- **URL:** `/api/auth/{provider}`, where `provider` is `google` or `github`
- **Method:** `GET`
- **Authentication Required:** `NO`

#### `307 Temporary Redirect`

Redirects to the provider's consent screen. It also sets an `oauth_state` cookie (HttpOnly, SameSite=Lax, 5 minutes) that the callback validates.

#### `400 Bad Request`

```json
{
  "success": false,
  "error": "Unsupported OAuth provider context"
}
```

### 5. OAuth Callback

The provider redirects here. Set it as the redirect URL in your Google / GitHub OAuth app, and in `GOOGLE_REDIRECT_URL` / `GITHUB_REDIRECT_URL`.

- **URL:** `/api/auth/{provider}/callback?code=&state=`
- **Method:** `GET`
- **Authentication Required:** `NO`

#### Account resolution

1. If a user is already linked to this provider account ID, sign them in.
2. Otherwise, if a user exists with the same email, link the provider to that user.
3. Otherwise, create a new user, unless the server has `REGISTRATION=closed`, in which case the "Authentication Failed" page is shown. The username is `<alphanumeric email handle>.<4 digits>` and the display name comes from the provider. OAuth-only accounts have no usable password.

GitHub sign-in requires a verified primary email on the GitHub account.

#### `200 OK` (HTML)

Returns an HTML handoff page that opens the app with the token pair:

```
elephant://oauth-callback?access_token=<access_token>&refresh_token=<refresh_token>
```

On Android, the page first tries an `intent://…#Intent;scheme=elephant;package=in.commandlinecoding.elephant;end;` URL, then falls back to the custom scheme.

#### `401 Unauthorized` (HTML)

An "Authentication Failed" HTML page is returned when the state cookie doesn't match, the provider exchange fails, or the account can't be created.

### 6. Two-step sign-in

A second step after the password: a six digit code from an authenticator app (TOTP, RFC 6238: SHA-1, 30 second steps), or a one-time recovery code. It is only for accounts that sign in with a password. Signing in with Google or GitHub is unchanged.

The server keeps the secret encrypted (AES-256-GCM, with the key from `TOTP_ENCRYPTION_KEY`, or `JWT_SECRET` if that is empty). A code is accepted for the current 30 second step and one either side, to allow for a clock that is a little off, and each code works once.

Wrong codes are counted: after 5 in a row, code entry is locked for 15 minutes for that account (`429` with `Retry-After`), and a right code is refused while it is locked. A right code starts the count again.

#### Finish a sign-in: `POST /api/auth/login/2fa`

- **Authentication Required:** `NO`
- **Rate limit:** a burst of 10 per address, then one every 5 seconds.

```json
{ "challenge": "<from login>", "code": "123456", "device_name": "Pixel 8" }
```

`code` is the six digits (spaces are ignored) or a recovery code (`k3f9-p2mx`, in any case, with or without the dash). The reply is the same as a normal [login](#2-login-user): `user` and `tokens`.

- `400 Bad Request`: no challenge or code.
- `401 Unauthorized`: a wrong or already used code (`"that code didn't work"`), or a challenge that is altered or older than 5 minutes (`"your sign-in took too long. Start again"`).
- `429 Too Many Requests`: code entry is locked.

An access token is not accepted as a challenge, and a challenge is not accepted as an access token.

#### Turn it on (signed in)

1. `POST /api/users/me/2fa/setup` returns `{ "secret": "<base32>", "otpauth_uri": "otpauth://totp/Elephant:<username>?secret=…" }`. Show the URI as a QR code (and the secret as text) for the authenticator app. It isn't on yet: a password is still enough to sign in. `400` for an account that has no password, `409` if it is already on. Asking again before confirming replaces the secret.
2. `POST /api/users/me/2fa/enable` with `{ "code": "123456" }` confirms the app works, turns it on and returns `{ "recovery_codes": ["k3f9-p2mx", … 10 codes] }`. **This is the only time they are shown**; the server keeps hashes. `401` for a wrong code, `400` if setup wasn't started, `409` if it is on. Rate limited as above.

#### Look and turn it off (signed in)

- `GET /api/users/me/2fa` returns `{ "enabled": true, "recovery_codes_left": 10 }`.
- `POST /api/users/me/2fa/disable` with `{ "password": "…", "code": "123456" }` turns it off, so someone holding an unlocked phone can't. The code can be a recovery code. `401` for a wrong password or code, `400` for either missing, `429` while locked.

---

## User Endpoints

`User` objects can also include `email`, `google_id` and `github_id`. These fields are omitted when empty, and the endpoints below never populate them.

### 1. User ME

- **URL:** `/api/users/me`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/users/me" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "username": "<username>",
    "display_name": "Full Name",
    "created_at": "<Timestamp>",
    "username_changed_at": "<Timestamp>",
    "bio": "",
    "status": { "emoji": "🚴", "text": "On a ride", "expires_at": "<Timestamp>" }
  }
}
```

`bio` is the person's "about" text (empty if none). `status` is their custom status, and is left out if they have none or it has expired; `expires_at` is left out for one with no end. Both are in [Get User by ID](#2-get-user-by-id) too, since they are visible to anyone who can look the person up. `username_changed_at` is when you last [changed your username](#10-update-your-profile); it is left out if you never have. Other people's profiles never include it.

#### `404 Not Found`

```json
{
  "success": false,
  "error": "User profile not found"
}
```

### 2. Get User by ID

- **URL:** `/api/users/{id}`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/users/{id}" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "username": "<username>",
    "display_name": "Full Name",
    "created_at": "<Timestamp>",
    "bio": "Cyclist. Chai first.",
    "status": { "emoji": "🚴", "text": "On a ride", "expires_at": "<Timestamp>" }
  }
}
```

`bio` and `status` are described under [User ME](#1-user-me). `username_changed_at` is never included for someone else.

#### `404 Not Found`

```json
{
  "success": false,
  "error": "Requested profile does not exist"
}
```

### 3. Search Users

Case-insensitive substring match on username **or** display name, ordered by username.

- **URL:** `/api/users/search?q={query}&page={page}&limit={limit}`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **Rate limit:** Token bucket per client IP: 10-request burst, refilling at 2 requests/second
- **curl:** `curl "http://HOST:PORT/api/users/search?q={query}&page=1&limit=20" -H "Authorization: Bearer <access_token>"`

| Param | Default | Notes |
|---|---|---|
| `q` | required | At least 2 characters after trimming whitespace, otherwise `400` |
| `page` | `1` | 1-based |
| `limit` | `20` | Values outside 1–100 fall back to 20 |

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "username": "<username>",
      "display_name": "Full Name",
      "created_at": "<Timestamp>"
    }
  ]
}
```

If no users match, `data` is an empty array.

#### `400 Bad Request`

The query is shorter than 2 characters.

```json
{
  "success": false,
  "error": "Search needs at least 2 characters"
}
```

#### `429 Too Many Requests`

```json
{
  "success": false,
  "error": "Rate limit exceeded. Too many search requests."
}
```

#### `500 Internal Server Error`

```json
{
  "success": false,
  "error": "Failed to execute user directory search operations"
}
```

### 4. Delete Account

- **URL:** `/api/users/me`
- **Method:** `DELETE`
- **Authentication Required:** `YES`
- **curl:** `curl -X DELETE "http://HOST:PORT/api/users/me" -H "Authorization: Bearer <access_token>"`

Deletes the user. Their messages, group memberships, devices and prekeys, refresh tokens and safety-number verifications are removed by `ON DELETE CASCADE`, and any live WebSocket is closed. The access token stays valid until it expires but no longer refers to an account.

#### `200 OK`

```json
{
  "success": true
}
```

#### `404 Not Found`

```json
{
  "success": false,
  "error": "User profile not found"
}
```

#### `500 Internal Server Error`

```json
{
  "success": false,
  "error": "Failed to delete account"
}
```

### 5. Register a Push Endpoint

Registers a [UnifiedPush](https://unifiedpush.org) endpoint, so the server can tell the app when it has new messages while the app is closed. Registering an endpoint that is already stored just refreshes it.

- **URL:** `/api/users/me/push`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/users/me/push" -H "Authorization: Bearer <access_token>" -H "Content-Type: application/json" -d '{"endpoint":"https://ntfy.example.org/upAbC123"}'`

#### Request Body

```json
{ "endpoint": "https://ntfy.example.org/upAbC123" }
```

The endpoint must be an `https` URL of at most 2048 characters, with no credentials in it. Because the server calls this URL, it must not point at a private or reserved address: loopback, private ranges (`10/8`, `172.16/12`, `192.168/16`, `fc00::/7`), shared address space (`100.64/10`, which includes Tailscale), link-local (including the cloud metadata address `169.254.169.254`), unspecified and multicast addresses are all refused. The address is checked again when the server connects, so a hostname that later resolves to one of these is refused too. A server operator can allow private endpoints over plain `http` (for a self-hosted ntfy on a LAN) with `PUSH_ALLOW_PRIVATE_ENDPOINTS=true`. Link-local, unspecified and multicast addresses stay blocked either way.

Each user keeps at most 5 endpoints. Registering a sixth drops the one that was refreshed least recently.

#### `200 OK`

```json
{ "success": true }
```

#### `400 Bad Request`

```json
{ "success": false, "error": "invalid push endpoint: endpoint must use https" }
```

#### The ping

When a **chat message** is for a user who has **no live WebSocket**, the server sends one request to each of their endpoints, about a second after the message is stored:

```
POST <endpoint>
Content-Type: application/json
TTL: 3600

{"type":"new_messages"}
```

The ping carries **no message content, sender or conversation**, so the push server learns only that something arrived. On receiving it, the app connects and fetches its messages as usual.

A **call** to someone whose app isn't connected sends the same ping straight away (not spaced), with `TTL: 60` since a call only rings for a minute. The payload is identical, so the push server can't tell a call from a message. The app asks [`GET /api/calls/pending`](#pending-call) on every ping to find out. Pings to one user are spaced at least 5 seconds apart, and messages that arrive meanwhile are covered by the next ping. Redirects are not followed. An endpoint that answers `404` or `410` is removed automatically. Typing indicators and read receipts never trigger a ping.

### 6. Remove a Push Endpoint

- **URL:** `/api/users/me/push`
- **Method:** `DELETE`
- **Authentication Required:** `YES`

```json
{ "endpoint": "https://ntfy.example.org/upAbC123" }
```

#### `200 OK`

Returned even if the endpoint wasn't stored, so apps can call it freely on sign-out.

```json
{ "success": true }
```

### 7. Block a User

Stops someone from reaching you. The blocked person isn't told:

- Their direct messages are dropped: not stored, not delivered, no push. Over REST they still get a normal `201 Created` (see [Send Message](#1-send-message)).
- Their typing indicators, read receipts and message edits don't reach you.
- Neither of you sees the other's online status.
- Group chats are not affected: you still see their messages in groups you share.

Blocking someone already blocked is not an error.

- **URL:** `/api/users/{id}/block`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/users/<user_id>/block" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{ "success": true, "data": "User blocked" }
```

#### `400 Bad Request`

`"Invalid user ID"` or `"You can't block yourself"`.

#### `404 Not Found`

`"User not found"`.

### 8. Unblock a User

Messages sent while the person was blocked are not delivered afterwards. Unblocking someone who isn't blocked is not an error.

- **URL:** `/api/users/{id}/block`
- **Method:** `DELETE`
- **Authentication Required:** `YES`
- **curl:** `curl -X DELETE "http://HOST:PORT/api/users/<user_id>/block" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{ "success": true, "data": "User unblocked" }
```

#### `400 Bad Request`

`"Invalid user ID"` or `"You can't block yourself"`.

### 9. List Blocked Users

The people you blocked, most recent first.

- **URL:** `/api/users/me/blocked`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/users/me/blocked" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "username": "bob.1234",
      "display_name": "Bob",
      "blocked_at": "<Timestamp>"
    }
  ]
}
```

### 10. Update Your Profile

Changes your display name, username, bio or custom status. Send only what to change; at least one is needed.

- **URL:** `/api/users/me`
- **Method:** `PATCH`
- **Authentication Required:** `YES`
- **curl:** `curl -X PATCH "http://HOST:PORT/api/users/me" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "display_name": "Maya Chen" }'`

#### Request Body

```json
{
  "display_name": "Maya Chen",
  "username": "maya",
  "bio": "Cyclist. Chai first.",
  "status": { "emoji": "🚴", "text": "On a ride", "expires_in": 3600 }
}
```

- `display_name` is trimmed, and must have 1 to 100 characters (counted as characters, not bytes). Other people see the new name the next time their app loads your profile.
- `username` is the part before the dot, as when signing up: 3 to 25 letters and digits (it is lowercased). The server adds a new four digit number, so `maya` becomes `maya.4821`. It can be changed **once every 30 days**. Your chats are unaffected, since they use user IDs; but signing in needs the new username from then on, and the old one (and profile links with it) stops finding you.

- `bio` is the "about" text: up to 140 characters, trimmed; an empty string clears it.
- `status` is the custom status: an `emoji` (up to 16 characters) and `text` (up to 60), either of which can be empty, and `expires_in`, how many seconds it lasts (60 to 604800; `0` or left out means until you change it). A status with neither emoji nor text clears it. An expired status is no longer shown.

Bio and status are visible to anyone who can look you up. If anything in the request is refused, nothing is changed.

#### `200 OK`

The updated user, as in [User ME](#1-user-me), with `username_changed_at` (only you are told it).

```json
{
  "success": true,
  "data": {
    "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "username": "maya.4821",
    "display_name": "Maya Chen",
    "created_at": "<Timestamp>",
    "username_changed_at": "<Timestamp>",
    "bio": "Cyclist. Chai first.",
    "status": { "emoji": "🚴", "text": "On a ride", "expires_at": "<Timestamp>" }
  }
}
```

#### `400 Bad Request`

`"Expected a display_name, a username, a bio or a status"`, `"your about text can be at most 140 characters"`, `"your status can be at most 60 characters"`, `"the status emoji is too long"`, `"a status lasts from a minute to a week"`, `"display name cannot be empty"`, `"display name must be at most 100 characters"`, `"username prefix must be between 3 and 25 characters"`, `"username prefix must contain only alphanumeric characters"` or `"that is already your username"`.

#### `409 Conflict`

`"username namespace collision; please try again"`: every number tried for that name was taken. Try again.

#### `429 Too Many Requests`

The username was changed less than 30 days ago. A `Retry-After` header says how many seconds to wait, and the message says the date.

### 11. Signed-in devices

Each sign-in is a session. These endpoints list them and sign them out. Signing a device out deletes its refresh token and closes its WebSocket at once; the device has to sign in again.

- **URL:** `/api/users/me/sessions`
- **Authentication Required:** `YES`

#### `GET /api/users/me/sessions`

The devices you are signed in on, most recently used first. `current` is true for the device that is asking. `last_used_at` is when it last refreshed its tokens, so it can be up to 15 minutes behind.

```json
{
  "success": true,
  "data": [
    {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "device_name": "Pixel 8",
      "started_at": "<Timestamp>",
      "last_used_at": "<Timestamp>",
      "current": true
    }
  ]
}
```

`device_name` is an empty string if the device never sent one.

#### `DELETE /api/users/me/sessions/{id}`

Signs one device out. It can be the device that is asking.

- `200 OK`: `{ "success": true }`
- `400 Bad Request`: `"Invalid device ID"`
- `404 Not Found`: `"No such device"`, including a device that belongs to someone else.

#### `DELETE /api/users/me/sessions`

Signs out every device except the one that is asking.

```json
{ "success": true, "data": { "signed_out": 2 } }
```

`400 Bad Request` (`"Sign in again to use this"`) for an access token issued before sessions existed, which doesn't say which device is the current one.

### 12. Privacy settings

What a person lets others see and do. **The server enforces every setting**, so a modified app can't get around them. Someone who never changed anything has the defaults, which are how the server behaved before there were settings.

- **URL:** `/api/users/me/settings`
- **Authentication Required:** `YES`

| Field | Values | Default | What it does |
|---|---|---|---|
| `online_status` | `everyone`, `contacts`, `nobody` | `contacts` | Who is told you are online (`user_status` events and `request_status` answers). `contacts` is people who share a chat or a group with you; `everyone` is anyone you haven't blocked and who hasn't blocked you; with `nobody` everyone is told you are offline. |
| `read_receipts` | `true`, `false` | `true` | When `false`, your `read_receipt` events aren't forwarded, and the people who sent you messages don't see them as read in the history or the chat list. You still see which messages you read. |
| `group_adds` | `everyone`, `contacts`, `nobody` | `everyone` | Who can add you to a group. [Add Member](#8-add-member-to-group) answers `403` for someone who isn't allowed. |

If the server can't load someone's settings it shares nothing: they are reported offline and no read receipt is forwarded.

#### `GET /api/users/me/settings`

```json
{
  "success": true,
  "data": { "online_status": "contacts", "read_receipts": true, "group_adds": "everyone" }
}
```

#### `PATCH /api/users/me/settings`

Send only the fields to change. The reply is all the settings after the change, in the same shape as `GET`.

```json
{ "online_status": "nobody", "read_receipts": false }
```

`400 Bad Request` for a body that isn't an object, or an `online_status` or `group_adds` that isn't one of the three values. Nothing is changed.

### 13. Export your data

Everything the server keeps about the signed-in user, in one JSON document they can save. The app offers it next to the chat backup and saves it as `elephant-account-<date>.json`; the chats on the phone are exported separately (see [docs/EXPORT.md](EXPORT.md)).

- **URL:** `/api/users/me/export`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **Rate limit:** 3 in a row, then one a minute per IP. Over the limit: `429` with `Retry-After`.

The reply has `Cache-Control: no-store`. Every list is `[]` when there is nothing in it. Times are RFC 3339; fields that may be empty in the database are `null`.

```json
{
  "success": true,
  "data": {
    "app": "elephant",
    "format": 1,
    "exported_at": "<Timestamp>",
    "account": {
      "id": "<UUID>", "username": "maya.0042", "display_name": "Maya",
      "email": null, "google_id": null, "github_id": null,
      "created_at": "<Timestamp>", "username_changed_at": null,
      "bio": "", "status_emoji": "", "status_text": "", "status_expires_at": null
    },
    "settings": { "online_status": "contacts", "read_receipts": true, "group_adds": "everyone" },
    "two_factor": { "enabled": false, "created_at": null, "recovery_codes_left": 0 },
    "sessions": [ { "id": "<UUID>", "device_name": "Pixel 8", "started_at": "<Timestamp>", "last_used_at": "<Timestamp>", "expires_at": "<Timestamp>" } ],
    "devices": [ { "device_id": "1", "identity_key": "<base64>", "signed_prekey": "<base64>", "signed_prekey_signature": "<base64>", "one_time_prekeys": 42, "updated_at": "<Timestamp>" } ],
    "push_endpoints": [ { "created_at": "<Timestamp>", "updated_at": "<Timestamp>", "failures": 0 } ],
    "blocked_users": [ { "user_id": "<UUID>", "blocked_at": "<Timestamp>" } ],
    "verified_contacts": [ { "user_id": "<UUID>", "is_verified": true, "updated_at": "<Timestamp>" } ],
    "message_requests": [ { "sender_id": "<UUID>", "created_at": "<Timestamp>" } ],
    "groups": [ { "id": "<UUID>", "name": "Trek", "description": "", "admins_only": false, "created_by": "<UUID>", "created_at": "<Timestamp>", "role": "admin", "joined_at": "<Timestamp>", "last_read_at": "<Timestamp>" } ],
    "group_join_requests": [ { "group_id": "<UUID>", "requested_at": "<Timestamp>" } ],
    "messages": [
      {
        "id": "<UUID>", "sender_id": "<UUID>", "receiver_id": "<UUID>", "group_id": null,
        "content": "{\"type\":3,\"ciphertext\":\"<base64>\"}",
        "created_at": "<Timestamp>", "is_read": true, "delivered_at": "<Timestamp>",
        "edited_at": null, "deleted_at": null, "expires_at": null,
        "reply_to_message_id": null, "silent": false
      }
    ],
    "hidden_messages": [ { "message_id": "<UUID>" } ],
    "cleared_chats": [ { "peer_id": "<UUID>", "group_id": null, "cleared_at": "<Timestamp>" } ],
    "statuses": [ { "id": "<UUID>", "created_at": "<Timestamp>", "expires_at": "<Timestamp>", "recipients": 5 } ],
    "received_statuses": [ { "id": "<UUID>", "author_id": "<UUID>", "content": "<ciphertext>", "created_at": "<Timestamp>", "expires_at": "<Timestamp>", "viewed_at": null } ],
    "reports": [ { "id": 7, "reported_user_id": "<UUID>", "reason": "spam", "note": "", "messages": [], "created_at": "<Timestamp>" } ]
  }
}
```

| Section | What it is |
|---|---|
| `account` | The profile row. The custom status is as stored, even if it has run out. |
| `settings` | The [privacy settings](#12-privacy-settings), or the defaults if they were never changed. |
| `two_factor` | Whether [two-step sign-in](#6-two-step-sign-in) is on and how many recovery codes are unused. |
| `sessions` | Every refresh token row: one per signed-in device, including ones that ran out and wait for cleanup. |
| `devices` | Each device's public prekey bundle, as anyone who starts a chat can fetch it, and how many one-time prekeys are left. |
| `push_endpoints` | When each push registration was made and how many pings in a row failed. |
| `blocked_users`, `verified_contacts` | The person's own choices about others. |
| `message_requests` | First messages from strangers waiting for the person to accept them. |
| `groups`, `group_join_requests` | Groups they are in, their role, and invite link requests an admin hasn't answered. |
| `messages` | Direct messages they sent or received, and the group messages they sent, oldest first. Messages they deleted for themselves or cleared are still here, because the other person still has them; `hidden_messages` and `cleared_chats` say which. A message that ran out is not. |
| `statuses`, `received_statuses` | Statuses they posted (how many copies were made, not who saw them) and the copies encrypted for them. |
| `reports` | Reports they sent, with the messages they chose to attach. |

`content` is what the sending phone uploaded. For direct messages and statuses that is Signal ciphertext, which only the phones can read; the readable chats come from the phone's export. Group messages are a plaintext envelope (`type` 0), since they are not end to end encrypted yet.

Left out on purpose:

- **Secrets:** the password hash, refresh token hashes, the two-step secret and recovery code hashes, push endpoint URLs and group invite codes. Each would let whoever holds the file sign in as the person, push to their phone or join their groups, and none says anything the person doesn't know.
- **Other people's data:** other members' group messages, who blocked the person, requests they sent that are still pending, who has seen their statuses, and reports about them (which would name the reporter).

#### `404 Not Found`

The account was deleted while the token was still valid.

```json
{ "success": false, "error": "User profile not found" }
```

#### `500 Internal Server Error`

```json
{ "success": false, "error": "Failed to export your data" }
```

---

## Reports Endpoints

Blocking stops someone reaching you; a report tells the server's admin. Direct messages are end-to-end encrypted, so the server can't see what was said. A report can include a few messages that the reporter's phone attaches as plain text, after asking the reporter.

### Report someone

- **URL:** `/api/reports`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **Rate limit:** a burst of 3, then one every 20 seconds, and at most 20 reports per person per day.

```json
{
  "user_id": "<reported user ID>",
  "reason": "spam",
  "note": "Keeps sending me links",
  "messages": [
    { "from_reported": true, "text": "buy my coins", "at": "<Timestamp>" }
  ]
}
```

`reason` is `spam`, `harassment` or `other`. `note` is optional, up to 500 characters. `messages` is optional: up to 10, each up to 1000 characters, as plain text. Blocking the person is a separate call ([Block a user](#7-block-a-user)).

- `201 Created`: `{ "success": true, "data": { "id": 12 } }`
- `400 Bad Request`: an invalid user ID, reason, note or messages, or reporting yourself.
- `404 Not Found`: `"User not found"`.
- `429 Too Many Requests`: the rate limit or the daily limit.

### List reports (admins)

- **URL:** `/api/admin/reports?limit=50&before=<id>`
- **Method:** `GET`
- **Authentication Required:** `YES`, and the user ID must be in the server's `ADMIN_USER_IDS`. Anyone else gets `403` (`"Admins only"`).

Reports, newest first. `limit` is 1 to 200 (default 50); pass the last `id` of a page as `before` to get the next one.

```json
{
  "success": true,
  "data": [
    {
      "id": 12,
      "reporter_id": "<user ID>",
      "reporter_username": "ava.1234",
      "reported_user_id": "<user ID>",
      "reported_username": "spam.5678",
      "reason": "spam",
      "note": "Keeps sending me links",
      "messages": [{ "from_reported": true, "text": "buy my coins", "at": "<Timestamp>" }],
      "created_at": "<Timestamp>"
    }
  ]
}
```

---

## Status Endpoints

A **status** is a short text that lasts 24 hours and goes to the people the author has chatted with. It is end-to-end encrypted like a direct message: the author's app encrypts it separately for each contact, and the server keeps one opaque `content` copy per recipient and never learns what it says or how it looks. All of these need a token.

### Post a status

`POST /api/status`

```json
{
  "copies": [
    { "recipient_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "content": "<ciphertext for this person>" }
  ]
}
```

- 1 to 200 copies, each at most 8 KiB, one per person.
- Only the author's **contacts** get a copy: people they have exchanged a direct message with (a [message request](#message-requests) that is still waiting doesn't count) or share a group with, and who haven't blocked them and weren't blocked. Anyone else, and the author, is listed in `skipped` and gets nothing. If nobody can receive it the answer is `400`.
- At most 20 statuses per author in 24 hours (`429` after that), and a rate limit on top.

#### `201 Created`

```json
{
  "success": true,
  "data": {
    "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "created_at": "<Timestamp>",
    "expires_at": "<Timestamp>",
    "recipients": 3,
    "skipped": ["dddddddd-dddd-dddd-dddd-dddddddddddd"]
  }
}
```

Connected recipients are sent a [`status_posted`](#12-status-posted) event. No push ping is sent for a status.

### List statuses

`GET /api/status` returns the statuses posted for you that haven't run out, newest first (at most 500), as `{ "id", "author_id", "content", "created_at", "expires_at", "viewed" }`. `content` is your copy, to decrypt as a direct message from `author_id`. `viewed` is whether you [marked it seen](#mark-a-status-seen). Statuses of someone you blocked, or who blocked you, are left out.

### List your statuses

`GET /api/status/mine` returns your statuses that haven't run out, newest first, as `{ "id", "created_at", "expires_at", "recipients", "viewers": [{ "user_id", "viewed_at" }] }`. Someone who has turned off [read receipts](#12-privacy-settings) is never listed as a viewer, even if they saw it.

### Delete a status

`DELETE /api/status/{id}` removes your status for everyone. `404` if it isn't yours or is gone.

### Mark a status seen

`POST /api/status/{id}/view` records that you saw a status, once. Its author is sent a [`status_viewed`](#13-status-viewed) event, unless you have turned off read receipts. `404` if it wasn't posted for you, or has run out.

---

## Calls Endpoints

### ICE Servers

The STUN and TURN servers to use for a call, with TURN credentials that expire after `ttl` seconds. Ask each time a call starts.

- **URL:** `/api/calls/ice-servers`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **Rate limit:** a burst of 5, then one every 5 seconds.

#### `200 OK`

`ice_servers` can be passed straight to WebRTC as `iceServers`. STUN entries have no `username` or `credential`. The list may be empty if the server has no STUN or TURN configured.

```json
{
  "success": true,
  "data": {
    "ice_servers": [
      { "urls": ["stun:stun.cloudflare.com:3478"] },
      {
        "urls": [
          "turn:turn.example.org:3478?transport=udp",
          "turn:turn.example.org:3478?transport=tcp"
        ],
        "username": "1794976213:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "credential": "q1E3c3l0Yq0p4c9mJb0n0o5hY8w="
      }
    ],
    "ttl": 86400
  }
}
```

If the server can't get TURN credentials (e.g. Cloudflare is unreachable), it answers `200` with STUN only.

#### `429 Too Many Requests`

```json
{
  "success": false,
  "error": "Rate limit exceeded. Too many call setup requests."
}
```

### Pending Call

The call ringing for you, if any. The app asks when a [push](#the-ping) wakes it, to show who is calling before it has connected.

- **URL:** `/api/calls/pending`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **Rate limit:** a burst of 10, then one every 2 seconds.

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "call_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
    "caller_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "caller_display_name": "Ava"
  }
}
```

With no call ringing for you, `data` is absent:

```json
{ "success": true }
```

---

## WebSocket Endpoints

### 1. Connect to WebSocket

- **URL:** `/api/ws?token={access_token}`
- **Method:** `GET` (WebSocket upgrade)
- **Authentication Required:** `YES` (access token in the `token` query parameter)
- **wscat:** `wscat -c "ws://HOST:PORT/api/ws?token={access_token}"`

#### `101 Switching Protocols`

The connection is open. Your connected [contacts](#5-user-status) receive a `user_status` event with `online: true`.

#### `401 Unauthorized`

Returned (with no body) when `token` is missing, expired or invalid.

```
error: Unexpected server response: 401
```

#### Connection behaviour

- The server sends a WebSocket ping every 54 seconds. A connection that hasn't sent a pong (or any message) within 60 seconds is closed.
- The maximum inbound frame size is **4096 bytes**, except `call_offer`, `call_answer` and `call_ice`, which may be up to **64 KB**. A larger frame closes the connection, and any other event over 4096 bytes is ignored.
- Each user has one live connection. A new connection for the same user replaces the previous one in the hub.
- Unknown `type` values (e.g. an application-level `ping`) and malformed JSON are ignored.
- The server never echoes a sent event back to the sender.

### Direct vs. group targeting

Every event targets **either** a user (`receiver_id`) **or** a group (`group_id`), never both. For group events, the server fans the event out to every member of the group except the sender.

Direct `chat`, `typing` and `read_receipt` events, and `message_edited`, from someone the receiver has [blocked](#7-block-a-user) are dropped silently. Group events are not affected.

### Message content format (E2EE)

The server stores and relays `content` as an opaque string. The Elephant app sends a JSON-encoded envelope:

```json
"{\"type\": <int>, \"ciphertext\": \"<base64 or text>\"}"
```

- **Direct messages:** `ciphertext` is a base64-encoded Signal Protocol message, and `type` is the libsignal ciphertext message type. The first message to a new contact is a PreKey message built from the contact's [prekey bundle](#2-fetch-prekey-bundle).
- **Group messages:** currently sent with `type: 0`, and `ciphertext` holds the **plaintext** message. Group messages are not yet end-to-end encrypted.

#### Structured messages

Apps can send small structured payloads (reactions, poll votes, pins, shared contacts, locations, link previews) inside the encrypted `content`. The server never sees them. The plaintext is a readable first part, followed by one hidden Markdown reference-definition line carrying the payload:

```
👍 Reacted to a message

[//]: # (elephant:v1:<base64url, no padding, of a JSON object>)
```

Apps that don't understand a payload show only the first part (Markdown hides the definition line). The JSON object has a `kind` (for example `reaction`) and kind-specific fields. Actions (reactions, votes, pins) are sent with `silent: true`. This is a convention between apps; the server treats `content` as opaque.

A `timer` payload, `{"kind": "timer", "seconds": 86400}`, sets how long later messages in the chat last (`0` turns it off). It is a normal, visible message, so it counts as unread and the chat shows it as a note. In a group, apps only honour it from an admin. See [disappearing messages](#disappearing-messages).

#### Mentions

A mention of a group member is written in the message text as `@[Name](user-id)`, where `user-id` is the member's ID (a UUID). The ID is what counts, so a renamed member is still the one mentioned; `Name` (no brackets or parentheses, one line, up to 60 characters) is what apps without mentions show, as a link named `Name`. Apps that know mentions show the member's current name, mark mentions of the person reading, and open the member when one is tapped.

### 2. Client to Server Messages

#### 1. Send Chat Message

Persists the message and delivers it live to online recipients. Offline recipients pick it up through the history endpoints.

```json
{
  "type": "chat",
  "message_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "<content>",
  "reply_to_message_id": "dddddddd-dddd-dddd-dddd-dddddddddddd"
}
```

- `message_id` is optional. If you send a client-generated UUID, the server uses it as the stored message ID, which lets offline-queued sends stay idempotent with the local DB. If you omit it, the server generates one.
- `reply_to_message_id` is optional.
- `expires_in` is optional: seconds until the message [disappears](#disappearing-messages).
- `silent` is optional (default `false`). Set it for a message that only carries an [action](#structured-messages) such as a reaction. The server stores it and relays it (with `silent: true`), but it is not the chat's last message in [`/api/messages/conversations`](#3-conversations), doesn't count as unread, and sends no [push ping](#the-ping). It still appears in history. The flag is the only thing the server learns about an action: not what it is. The REST [`POST /api/messages`](#1-send-message) doesn't accept it.
- For a group, send `group_id` instead of `receiver_id`. The sender must be a member, or the message is dropped without a reply. If the group is [admins-only](#7-update-group-details), only an admin's message is accepted, apart from actions (a reaction, a vote or a pin), which members can still send. The server checks that an action really is one: its text must end with the hidden action line, with a `kind` of `reaction`, `vote` or `pin`.

#### 2. Read Receipt

```json
{
  "type": "read_receipt",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
}
```

- **Direct:** marks every unread message from `receiver_id` to you as read, and forwards the receipt to that user.
- **Group** (`group_id`): updates your `last_read_at` for the group, and forwards the receipt to the other members.

#### 3. Request Online Status

```json
{
  "type": "request_status",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
}
```

The server replies directly with a [`user_status`](#5-user-status) event. The answer is only real for your [contacts](#5-user-status): for anyone else the reply always says `"online": false`, so a stranger can't use this to find out when someone is around.

#### 4. Typing Indicator

```json
{
  "type": "typing",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "true"
}
```

`content` is relayed as-is. The app sends `"true"` when typing starts and `"false"` when it stops. Use `group_id` for groups.

#### 5. Delivered

The recipient's app tells the server which direct messages have reached it, so their senders can show a second tick. Send it for messages received live and for ones that came in with a history page. Up to 100 IDs; anything that isn't a message ID, a message that wasn't sent to you, a group message, and one already reported are ignored.

```json
{
  "type": "delivered",
  "message_ids": ["cccccccc-cccc-cccc-cccc-cccccccccccc"]
}
```

Each sender is sent a [`message_delivered`](#10-message-delivered) event. Reading messages ([`read_receipt`](#2-read-receipt)) delivers them too, so apps that never send this still get ticks.

### 3. Server to Client Messages

#### 1. Incoming Chat Message

```json
{
  "type": "chat",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "<content>",
  "message_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "timestamp": "<Timestamp>"
}
```

For group messages, `group_id` is set instead of `receiver_id`.

#### 2. Incoming Chat Message (reply)

When `reply_to_message_id` resolves to a stored message, the event includes a preview of the quoted message. In this form, both `receiver_id` and `group_id` are always present, and the unused one is an empty string.

```json
{
  "type": "chat",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "group_id": "",
  "content": "<content>",
  "message_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "reply_to_message_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
  "timestamp": "<Timestamp>",
  "expires_at": "<Timestamp>",
  "quoted_message": {
    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "sender_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "content": "<original message content>"
  }
}
```

#### 3. Typing Indicator

```json
{
  "type": "typing",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "true"
}
```

#### 4. Read Receipt

```json
{
  "type": "read_receipt",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "timestamp": "<Timestamp>"
}
```

`sender_id` is the user who read the messages.

#### 5. User Status

Sent when a user connects or disconnects, to **their contacts** who are connected, and directly in response to `request_status`.

A user's **contacts** are the people they have exchanged a direct message with (in either direction) and the people they share a group with. Someone whose [message request](#message-requests) is still waiting is not a contact (unless they share a group), so writing to a stranger doesn't show when they are around. Nobody else is told when they are online, and a `request_status` about a non-contact is answered with `online: false`. If the server can't load someone's contacts, it shares nothing rather than falling back to telling everyone.

Contact lists are cached for about 20 seconds when answering `request_status`, so someone you have only just started a conversation with can show as offline for a short while. Connect and disconnect events always use a fresh list.

```json
{
  "type": "user_status",
  "user_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "online": true
}
```

#### 6. Message Edited

Sent when someone edits a message ([`PUT /api/messages/{id}`](#4-edit-message)), to the **other** person in a direct chat or to the **other members** of a group. The editor is not sent their own edit.

```json
{
  "type": "message_edited",
  "message_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "<new content>",
  "created_at": "<Timestamp>",
  "edited_at": "<Timestamp>"
}
```

A group edit carries `group_id` instead of `receiver_id`. `content` is exactly what the editor sent, so for E2EE direct messages it is ciphertext that the receiver decrypts like any other message. Someone who isn't connected doesn't receive the event; they get the edited message (with `edited_at`) the next time they load the conversation. Edits never trigger a push notification.

#### 7. Messages Deleted

Sent to the **other** person in a direct chat when someone deletes the conversation for everyone ([`DELETE /api/messages/conversations/{userId}?for=everyone`](#6-delete-a-direct-conversation)). Every message `sender_id` sent to `receiver_id` up to `before` is gone; the app should remove its local copies. The receiver's own messages are not affected.

```json
{
  "type": "messages_deleted",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "before": "<Timestamp>"
}
```

Someone who isn't connected doesn't receive the event; the messages are simply missing the next time they load the conversation.

#### 8. Group Deleted

Sent to every **other** member when an admin deletes a group ([`DELETE /api/groups/{id}`](#11-delete-group)). The app should remove the group and its messages.

```json
{
  "type": "group_deleted",
  "group_id": "gggggggg-gggg-gggg-gggg-gggggggggggg",
  "deleted_by": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
}
```

#### 9. Message Deleted

Sent to the other people in a chat when someone deletes one of their messages [for everyone](#7-delete-a-message): the other person in a direct chat, or every other member of a group. Nobody is told who isn't connected; they see the tombstone when they next load the chat. Not sent to someone who has blocked the sender.

```json
{
  "type": "message_deleted",
  "message_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "deleted_at": "<Timestamp>"
}
```

A group message has `group_id` instead of `receiver_id`. The app should show "This message was deleted" in its place and drop anything it kept of the content.

#### 10. Message Delivered

Sent to the sender of direct messages when they reach the recipient's phone. The sender shows a second tick. Not sent for messages that were already reported, or if the sender isn't connected (they see it in history's `delivered_at`).

```json
{
  "type": "message_delivered",
  "message_ids": ["cccccccc-cccc-cccc-cccc-cccccccccccc"],
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "delivered_at": "<Timestamp>"
}
```

#### 11. Group Updated

Sent to the live members of a group when an admin changes its name, description or who may post ([`PATCH /api/groups/{id}`](#7-update-group-details)), including the admin who made the change. It says only which group; load [the group](#3-get-group-by-id) for the new details.

```json
{
  "type": "group_updated",
  "group_id": "dddddddd-dddd-dddd-dddd-dddddddddddd"
}
```

#### 12. Status Posted

Sent to a connected recipient when someone posts a [status](#post-a-status) for them. It has no content: fetch [`GET /api/status`](#list-statuses).

```json
{
  "type": "status_posted",
  "status_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "author_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "created_at": "<Timestamp>",
  "expires_at": "<Timestamp>"
}
```

#### 13. Status Viewed

Sent to the author the first time a recipient [marks their status seen](#mark-a-status-seen), unless that person has turned off read receipts.

```json
{
  "type": "status_viewed",
  "status_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "viewer_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "viewed_at": "<Timestamp>"
}
```

### 4. Calls

One-to-one voice calls use WebRTC. The server relays the messages that set a call up; the audio goes directly between the two phones (or through a TURN relay), never through this server.

Every call event carries a `call_id`, a UUID the caller generates. The server sets `sender_id` on everything it relays.

The `content` of `call_offer`, `call_answer` and `call_ice` is the SDP or ICE candidate, encrypted by the app with the Signal session in the same [envelope](#message-content-format-e2ee) as a direct message. The server relays it without reading it.

#### Events

| Event | Sent by | Relayed to | Fields |
|---|---|---|---|
| `call_offer` | caller | callee | `call_id`, `receiver_id` (when sending), `content` |
| `call_ring` | callee | caller | `call_id`: the callee's phone is ringing |
| `call_answer` | callee | caller | `call_id`, `content` |
| `call_ice` | either person | the other | `call_id`, `content` |
| `call_hangup` | either person, or the server | the other, or both | `call_id`, `reason` |
| `call_busy` | the server | caller | `call_id`: the callee is already in a call |

Start a call:

```json
{
  "type": "call_offer",
  "call_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "<content>"
}
```

The callee receives:

```json
{
  "type": "call_offer",
  "call_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "content": "<content>"
}
```

Other events only need `call_id` (plus `content` or `reason`). The server knows who else is in the call.

```json
{ "type": "call_hangup", "call_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "reason": "declined" }
```

#### Hang-up reasons

| `reason` | Meaning |
|---|---|
| `ended` | Someone hung up. This is the default when a client sends no reason or an unknown one. |
| `declined` | The callee declined before answering. |
| `timeout` | Nobody answered within 60 seconds. Sent to both people. |
| `unavailable` | The call couldn't start: the callee isn't connected and has no [push endpoint](#5-register-a-push-endpoint) to wake them, you don't share a chat or group, you've blocked them, or you're already in a call. |
| `disconnected` | The other person's connection dropped and didn't come back. A ringing call ends at once. An answered call is given 30 seconds, because a phone switching networks reconnects while the audio may carry on. |

#### Rules

- You can only call people you share a chat or a group with.
- One call per person at a time. Calling someone who's in a call gets `call_busy`.
- If the callee has [blocked](#7-block-a-user) the caller, the call isn't delivered and ends with `timeout` after 60 seconds, as if nobody answered. The caller isn't told about the block.
- `call_ring`, `call_answer`, `call_ice` and `call_hangup` from anyone outside the call are ignored, as is `call_answer` from the caller.
- **A callee whose app is closed** but who has a [push endpoint](#5-register-a-push-endpoint) is woken with a [ping](#the-ping), and the call rings for the caller as usual (no `call_ring` until the callee's app connects). The server keeps the `call_offer`, and up to 50 of the caller's `call_ice`, and sends them to the callee as soon as their WebSocket connects, once. Without a push endpoint the call ends at once with `unavailable`.
- If such a call ends before the callee's app connects (it rang out, or the caller hung up or dropped), the callee gets a `call_missed` event the next time they connect:

  ```json
  { "type": "call_missed", "call_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "at": "2026-11-17T10:37:12Z" }
  ```

  Missed calls are kept in memory, at most 20 per person for 24 hours. Waiting calls and missed calls are lost if the server restarts.

---

## Messages Endpoints

### Message object

```json
{
  "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "group_id": "<group_id>",
  "content": "<content>",
  "created_at": "<Timestamp>",
  "is_read": false,
  "edited_at": "<Timestamp>",
  "deleted_at": "<Timestamp>",
  "delivered_at": "<Timestamp>",
  "expires_at": "<Timestamp>",
  "reply_to_message_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
  "quoted_message": {
    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "sender_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "content": "<quoted content>"
  }
}
```

`receiver_id`, `group_id`, `edited_at`, `deleted_at`, `delivered_at`, `expires_at`, `reply_to_message_id` and `quoted_message` are omitted when empty.

`delivered_at` is when a **direct** message reached the recipient's phone (see the [`delivered`](#5-delivered) event). Reading a message counts as delivering it. It is never set for group messages.

A message deleted for everyone (see [Delete a Message](#7-delete-a-message)) stays in history as a **tombstone**: `deleted_at` is set and `content` is empty. It can no longer be edited, and replies that quoted it have nothing to quote.

### Disappearing messages

A `chat` frame can carry `expires_in`, a number of seconds, for a message that should not last. The server turns it into `expires_at` (the message's timestamp plus `expires_in`), stores that, and includes it in the relayed `chat` event and in the [message object](#message-object). `expires_in` is clamped to between 60 seconds and 28 days, and is ignored when it is zero, negative or missing: the message then lasts as before.

Once `expires_at` has passed the server treats the message as gone: it is left out of [direct](#2-direct-message-history) and [group](#4-group-message-history) history, doesn't count as unread and is never a chat's last message in [`/api/messages/conversations`](#3-conversations). The [cleanup job](#health-endpoint) deletes the rows later, so a message can be unreadable before it is deleted. Apps hide and delete their own copies at `expires_at` too, since a relayed or stored copy is out of the server's reach.

The server does not know a chat's setting, only each message's expiry. The setting itself is a [`timer` message](#structured-messages), end-to-end encrypted in a direct chat, and it is up to each app to put `expires_in` on what it sends afterwards. The Elephant app never gives a timer message an expiry, so the chat keeps a record of the change.

Disappearing messages are not a promise: a recipient can still screenshot or copy a message, and an app that doesn't know about them keeps what it receives.

### Message requests

A direct message from someone you have never exchanged a direct message with, and who shares no group with you, is a **message request**. Conversations that exist when this is introduced, and everything that involves a shared group, are not requests. The server keeps a request until you accept it, or until you write back (answering accepts it).

While a request is waiting:

- The relayed `chat` event has `"request": true` (only the server sets it; a value from the sender is ignored), and the conversation has `is_request: true` in [`/api/messages/conversations`](#3-conversations). Apps list it apart, without a notification.
- No [push ping](#the-ping) is sent for it, so a request never wakes the phone. It is stored and delivered like any message.
- The sender is not told that you saw it: your `read_receipt`, `typing` and `delivered` events about them are not passed on, [`POST /api/messages/read`](#5-mark-direct-messages-read) does not mark their messages read, and neither of you is the other's [contact](#5-user-status) for online status.
- Deleting the conversation or blocking the sender doesn't end the request: if they write again it comes back as a request. Block them to stop that.

[Accept a request](#8-accept-a-message-request) to turn it into an ordinary chat. If the server can't tell whether something is a request, it delivers the message as an ordinary one, and holds back receipts rather than leak them.

### 1. Send Message

REST fallback for direct messages. The message is stored but **not** pushed over the WebSocket.

If the receiver has [blocked](#7-block-a-user) the sender, the message is dropped but the response is the same `201 Created`, so the sender can't tell.

- **URL:** `/api/messages`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/messages" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "receiver_id": "<receiver_id>", "content": "<content>" }'`

#### Request Body

```json
{
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "<content>",
  "reply_to_message_id": "dddddddd-dddd-dddd-dddd-dddddddddddd"
}
```

`reply_to_message_id` is optional.

#### `201 Created`

```json
{
  "success": true,
  "data": {
    "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "content": "<content>",
    "created_at": "<Timestamp>",
    "is_read": false
  }
}
```

#### `400 Bad Request`

`"Invalid json payload structure"`, `"Receiver identity token required"`, `"message content cannot be empty"`, `"cannot send a message to yourself"`, or a database error message.

### 2. Direct Message History

Returns messages between you and another user, newest first.

- **URL:** `/api/messages?with={user_id}&before={timestamp}&limit={limit}`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/messages?with={user_id}&limit=50" -H "Authorization: Bearer <access_token>"`

| Param | Required | Default | Notes |
|---|---|---|---|
| `with` | Yes | — | The other user's ID |
| `before` | No | now + 1 minute | RFC3339 timestamp. Returns messages created strictly before it. To page backwards, pass the `created_at` of the oldest message you have |
| `limit` | No | `50` | Values outside 1–100 fall back to 50 |

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
      "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "content": "<content>",
      "created_at": "<Timestamp>",
      "is_read": true,
      "edited_at": "<Timestamp>",
      "reply_to_message_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
      "quoted_message": {
        "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
        "sender_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        "content": "<quoted content>"
      }
    }
  ]
}
```

#### `400 Bad Request`

```json
{
  "success": false,
  "error": "Missing target 'with' user query constraint"
}
```

#### `500 Internal Server Error`

`"Failed to pull chat logs"`.

### 3. Conversations

Returns one entry per direct chat and per group you belong to, ordered by latest message (newest first). Groups with no messages yet are not listed.

- **URL:** `/api/messages/conversations`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/messages/conversations" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "id": "<other user's id | group id>",
      "type": "direct",
      "name": "<username | group name>",
      "display_name": "<display name, empty for groups>",
      "last_message": "<content>",
      "last_message_time": "<Timestamp>",
      "sender_id": "<sender of the last message>",
      "is_read": false,
      "unread_count": 3,
      "last_message_deleted": false,
      "is_request": false
    }
  ]
}
```

- `type` is `direct` or `group`.
- `is_request` is `true` for a direct chat that is a [message request](#message-requests) you haven't accepted. It is always `false` for a group.
- `last_message_deleted` is `true` (and `last_message` empty) when the last message was [deleted for everyone](#7-delete-a-message). It is omitted when `false`. A message you deleted for yourself, and [silent actions](#structured-messages), are never the last message.
- **Direct:** `is_read` is the read flag of the last message, and `unread_count` counts unread messages sent to you.
- **Group:** `is_read` is true if the last message is no newer than your `last_read_at`, and `unread_count` counts other members' messages since then.

#### `500 Internal Server Error`

`"Failed to compile inbox conversations"`.

### 4. Edit Message

Replaces the content of a message you sent. Edits are only allowed within **15 minutes** of `created_at`. The other people in the conversation who are connected are sent a [`message_edited`](#6-message-edited) event over the WebSocket. For E2EE direct messages, the client must send newly encrypted content.

- **URL:** `/api/messages/{id}`
- **Method:** `PUT`
- **Authentication Required:** `YES`
- **curl:** `curl -X PUT "http://HOST:PORT/api/messages/{id}" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "content": "<new content>" }'`

#### Request Body

```json
{
  "content": "<new content>"
}
```

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "sender_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "content": "<new content>",
    "created_at": "<Timestamp>",
    "is_read": false,
    "edited_at": "<Timestamp>"
  }
}
```

#### `400 Bad Request`

`"Message ID required"`, `"Invalid json payload structure"` or `"Content cannot be empty"`.

#### `403 Forbidden`

```json
{ "success": false, "error": "You can only edit your own messages" }
```
```json
{ "success": false, "error": "Message can no longer be edited (15 minute window expired)" }
```

#### `404 Not Found`

```json
{ "success": false, "error": "Message not found" }
```

### 5. Mark Direct Messages Read

Marks every unread message that `sender_id` sent to you as read. This is the REST equivalent of the WebSocket `read_receipt`, but the sender is not notified.

- **URL:** `/api/messages/read`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/messages/read" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "sender_id": "<sender_id>" }'`

#### Request Body

```json
{
  "sender_id": "<sender_id>"
}
```

#### `200 OK`

```json
{
  "success": true,
  "data": "Target messages marked read successfully"
}
```

#### `400 Bad Request`

`"Invalid payload layout"` or `"Sender identification missing"`.

### 6. Delete a Direct Conversation

- **`for=me`** (the default): hides the conversation's current messages from you only. They disappear from your history, inbox and unread counts. The other person keeps everything, and the conversation comes back for you when a new message arrives.
- **`for=everyone`**: also deletes every message **you** sent in the conversation, for both people, and sends the other person a [`messages_deleted`](#7-messages-deleted) event. Their messages are never deleted by you.

Both return `cleared_at`: the app should delete its local copies of the conversation's messages up to that time.

- **URL:** `/api/messages/conversations/{userId}?for=me|everyone`
- **Method:** `DELETE`
- **Authentication Required:** `YES`
- **curl:** `curl -X DELETE "http://HOST:PORT/api/messages/conversations/<user_id>?for=everyone" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "cleared_at": "<Timestamp>",
    "deleted": 2
  }
}
```

`deleted` is how many of your messages were removed for both people (always `0` for `for=me`).

#### `400 Bad Request`

`"Invalid user ID"`, `"You can't have a conversation with yourself"`, or `"'for' must be 'me' or 'everyone'"`.

#### `404 Not Found`

`"User not found"`.

### 7. Delete a Message

- **`for=me`** (the default): removes the message from **your** view only: your history, chat list and unread counts. Everyone else still sees it. Works for any message you can see.
- **`for=everyone`**: deletes a message **you** sent, for everyone in the chat, at any time. The content is cleared and the message stays as a tombstone ("This message was deleted"). The other people are sent a [`message_deleted`](#9-message-deleted) event. You can't delete other people's messages for everyone.

- **URL:** `/api/messages/{id}?for=me|everyone`
- **Method:** `DELETE`
- **Authentication Required:** `YES`
- **curl:** `curl -X DELETE "http://HOST:PORT/api/messages/<message_id>?for=everyone" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "deleted_at": "<Timestamp>"
  }
}
```

`deleted_at` is only returned for `for=everyone`.

#### `400 Bad Request`

`"Invalid message ID"` or `"'for' must be 'me' or 'everyone'"`.

#### `403 Forbidden`

`"You can only delete your own messages for everyone"`.

#### `404 Not Found`

`"Message not found"`: it doesn't exist, you can't see it, or it was already deleted for everyone.

### 8. Accept a Message Request

Accepts the [message request](#message-requests) from a user. The chat becomes an ordinary one: they are told when you read their messages (if you allow it, see [privacy settings](#12-privacy-settings)), and you are contacts for online status. The sender is sent a [`message_delivered`](#10-message-delivered) event for the newest messages (up to 100) that were held back.

- **URL:** `/api/messages/requests/{userId}/accept`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/messages/requests/<user_id>/accept" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{ "success": true, "data": { "user_id": "<user_id>" } }
```

#### `400 Bad Request`

`"Invalid user id"`.

#### `404 Not Found`

`"No message request from this user"`: there is none, or it was already accepted.

---

## Group Endpoints

Routes under `/api/groups/{id}` require group membership. When the caller isn't a member, or the group doesn't exist, they return:

```json
{
  "success": false,
  "error": "Access denied: you are not a member of this group"
}
```

Admin-only routes additionally return `403` for non-admins:

```json
{
  "success": false,
  "error": "Administrative clearance privileges required"
}
```

The group creator becomes its `admin`, and added users join as `member`.

### 1. Create Group

- **URL:** `/api/groups`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/groups" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "name": "<group_name>" }'`

#### Request Body

```json
{
  "name": "<group_name>"
}
```

#### `201 Created`

```json
{
  "success": true,
  "data": {
    "id": "<group_id>",
    "name": "<group_name>",
    "created_by": "<creator_id>",
    "created_at": "<Timestamp>"
  }
}
```

#### `400 Bad Request`

`"Invalid payload group name configuration"` (empty or missing name).

### 2. List My Groups

Returns the groups you belong to, newest first.

- **URL:** `/api/groups`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/groups" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "id": "<group_id>",
      "name": "<group_name>",
      "created_by": "<creator_id>",
      "created_at": "<Timestamp>"
    }
  ]
}
```

### 3. Get Group by ID

- **URL:** `/api/groups/{id}`
- **Method:** `GET`
- **Authentication Required:** `YES` (member)
- **curl:** `curl "http://HOST:PORT/api/groups/{id}" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "id": "<group_id>",
    "name": "<group_name>",
    "created_by": "<creator_id>",
    "created_at": "<Timestamp>",
    "description": "",
    "admins_only": false
  }
}
```

`description` is up to 500 characters, set by an admin. With `admins_only` true only admins may send messages (see [Update Group Details](#7-update-group-details)). The list from `GET /api/groups` has the same two fields.

#### `404 Not Found`

`"Group not found"`.

### 4. Group Message History

Returns group messages, newest first.

- **URL:** `/api/groups/{id}/messages?before={timestamp}&limit={limit}`
- **Method:** `GET`
- **Authentication Required:** `YES` (member)
- **curl:** `curl "http://HOST:PORT/api/groups/{id}/messages?limit=50" -H "Authorization: Bearer <access_token>"`

| Param | Default | Notes |
|---|---|---|
| `before` | now | RFC3339 timestamp. Returns messages created strictly before it |
| `limit` | `50` | Values outside 1–100 fall back to 50 |

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "id": "<message_id>",
      "sender_id": "<sender_id>",
      "group_id": "<group_id>",
      "content": "<content>",
      "created_at": "<Timestamp>",
      "is_read": false,
      "edited_at": "<Timestamp>",
      "reply_to_message_id": "<message_id>",
      "quoted_message": {
        "id": "<message_id>",
        "sender_id": "<user_id>",
        "content": "<quoted content>"
      }
    }
  ]
}
```

`is_read` is always `false` for group messages. Use the `unread_count` in [Conversations](#3-conversations) to track group read state.

### 5. Group Members

Members are listed admins first, then by join date.

- **URL:** `/api/groups/{id}/members`
- **Method:** `GET`
- **Authentication Required:** `YES` (member)
- **curl:** `curl "http://HOST:PORT/api/groups/{id}/members" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": [
    {
      "user_id": "<user_id>",
      "username": "<username>",
      "display_name": "<Full Name>",
      "role": "admin",
      "joined_at": "<Timestamp>"
    },
    {
      "user_id": "<user_id>",
      "username": "<username>",
      "display_name": "<Full Name>",
      "role": "member",
      "joined_at": "<Timestamp>"
    }
  ]
}
```

`role` is either `admin` or `member`.

### 6. Leave Group

- **URL:** `/api/groups/{id}/leave`
- **Method:** `POST`
- **Authentication Required:** `YES` (member)
- **curl:** `curl -X POST "http://HOST:PORT/api/groups/{id}/leave" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": "You have left the group"
}
```

#### `500 Internal Server Error`

`"Failed to leave the group"`.

### 7. Update Group Details

Changes a group's name, description, and whether only admins may send messages. Send only what to change; at least one is needed.

- **URL:** `/api/groups/{id}`
- **Method:** `PATCH`
- **Authentication Required:** `YES` (admin)
- **curl:** `curl -X PATCH "http://HOST:PORT/api/groups/{id}" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "description": "Weekend rides" }'`

#### Request Body

```json
{
  "name": "<new_group_name>",
  "description": "Weekend rides, every Sunday.",
  "admins_only": true
}
```

- `name`: 1 to 100 characters.
- `description`: up to 500 characters; an empty string clears it.
- `admins_only`: when `true`, only admins may send messages. Members can still react and vote. The server drops a member's message and anyone's message from outside the group, without telling the sender; apps hide the message box instead.

#### `200 OK`

The group, as in [Get Group by ID](#3-get-group-by-id). The group's live members get a `group_updated` WebSocket event (see [Server → Client messages](#3-server-to-client-messages)) and load the details again.

```json
{
  "success": true,
  "data": {
    "id": "<group id>",
    "name": "Sunday Ride",
    "created_by": "<user id>",
    "created_at": "<Timestamp>",
    "description": "Weekend rides, every Sunday.",
    "admins_only": true
  }
}
```

#### `400 Bad Request`

`"Expected a name, a description or admins_only"`, `"A group name has 1 to 100 characters"` or `"A description can be at most 500 characters"`. Nothing is changed.

### 8. Add Member to Group

Adding a user who is already a member is a no-op that still returns `200`.

- **URL:** `/api/groups/{id}/members`
- **Method:** `POST`
- **Authentication Required:** `YES` (admin)
- **curl:** `curl -X POST "http://HOST:PORT/api/groups/{id}/members" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "user_id": "<user_id>" }'`

#### Request Body

```json
{
  "user_id": "<user_id>"
}
```

#### `200 OK`

```json
{
  "success": true,
  "data": "User attached to channel context cleanly"
}
```

#### `400 Bad Request`

`"Missing user target value"`.

#### `403 Forbidden`

The person's [privacy setting](#12-privacy-settings) doesn't allow it: `"This person doesn't allow being added to groups."`, or `"This person only allows people they chat with to add them to groups."`. Adding yourself is always allowed.

#### `500 Internal Server Error`

Returned when the user doesn't exist (or their settings couldn't be checked, with `"Couldn't check whether this person can be added."`):

```json
{
  "success": false,
  "error": "Failed to add member to channel"
}
```

### 9. Remove Member from Group

- **URL:** `/api/groups/{id}/members/{userId}`
- **Method:** `DELETE`
- **Authentication Required:** `YES` (admin)
- **curl:** `curl -X DELETE "http://HOST:PORT/api/groups/{id}/members/{userId}" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": "Member detached from group context cleanly"
}
```

#### `500 Internal Server Error`

```json
{
  "success": false,
  "error": "Failed to drop target user from channel"
}
```

### 10. Clear Group History

"Delete for me" for a group: hides the group's current messages from you only. You stay a member and see new messages as usual. The response has the same `cleared_at` as [deleting a direct conversation](#6-delete-a-direct-conversation).

- **URL:** `/api/groups/{id}/history`
- **Method:** `DELETE`
- **Authentication Required:** `YES` (member)
- **curl:** `curl -X DELETE "http://HOST:PORT/api/groups/{id}/history" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "cleared_at": "<Timestamp>",
    "deleted": 0
  }
}
```

### 11. Delete Group

Deletes the group with all its members and messages, for everyone, and sends the other members a [`group_deleted`](#8-group-deleted) event. Members who only want to stop seeing it can [leave](#6-leave-group) instead.

- **URL:** `/api/groups/{id}`
- **Method:** `DELETE`
- **Authentication Required:** `YES` (admin)
- **curl:** `curl -X DELETE "http://HOST:PORT/api/groups/{id}" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": "Group deleted"
}
```

#### `403 Forbidden`

Returned to members who aren't admins.

### 12. Group Invite Link

Adds people without an admin picking each one. A group has at most one link; its code is 32 random characters, which is the only secret in it. A link is shared as `https://<host>/g/<code>` or, for self-hosted servers, `elephant://g/<code>`.

- **URL:** `/api/groups/{id}/invite`
- **Authentication Required:** `YES` (admin)

#### `GET`

```json
{ "success": true, "data": { "enabled": true, "code": "<32 characters>", "require_approval": false } }
```

With no link: `{ "enabled": false, "require_approval": false }`.

#### `PUT`

Creates the link, or changes it. Send nothing to create it (asking again returns the same code).

```json
{ "require_approval": true, "reset": true }
```

- `require_approval`: when `true`, opening the link asks to join and an admin lets the person in ([join requests](#13-join-requests)). Left out, it stays as it is.
- `reset`: make a new code. The old one stops working at once.

Returns the link as in `GET`.

#### `DELETE`

Turns the link off. Anyone waiting for approval is dropped. `200 OK` with `{ "success": true }`.

### 13. Join Requests

For a group whose link needs approval. Admins only; others get `403`. Each change sends the group's members a [`group_updated`](#11-group-updated) event.

- `GET /api/groups/{id}/requests`: who is waiting, oldest first: `[{ "user_id", "username", "display_name", "requested_at" }]`.
- `POST /api/groups/{id}/requests/{userId}`: lets the person in as a member.
- `DELETE /api/groups/{id}/requests/{userId}`: turns them down.

Both answer `404` (`"No such request"`) if there is none, and `400` for a bad user ID.

### 14. Using an Invite Link

Rate limited: a burst of 10, then one every 5 seconds. A code that is malformed, unknown, reset or turned off gives `404` (`"This invite link doesn't work any more"`).

#### `GET /api/invites/{code}`

What the person sees before joining. It names nobody.

```json
{
  "success": true,
  "data": {
    "group_id": "<id>",
    "name": "Sunday Ride",
    "member_count": 12,
    "require_approval": false,
    "already_member": false,
    "already_requested": false
  }
}
```

#### `POST /api/invites/{code}/join`

```json
{ "success": true, "data": { "status": "joined", "group_id": "<id>" } }
```

`status` is `joined` (a member now, with the role `member`), `requested` (the group needs approval; an admin will answer) or `already_member`. Joining by link is the person's own choice, so [who can add you to groups](#12-privacy-settings) doesn't apply.

---

## E2EE Endpoints

The server is a public-key directory for the [Signal Protocol](https://signal.org/docs/) (X3DH + Double Ratchet). It stores only **public** keys, and private keys never leave the device. All keys are base64-encoded strings. Keys are stored per `(user_id, device_id)`, and the app currently always uses `device_id = "main"`.

### 1. Upload Prekey Bundle

Creates or replaces your device's identity key and signed prekey, and **appends** the supplied one-time prekeys.

If the identity key differs from the one previously stored for this device, every other user's verification of you is reset to unverified.

- **URL:** `/api/e2ee/keys`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/e2ee/keys" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d @bundle.json`

#### Request Body

```json
{
  "device_id": "main",
  "identity_key": "<base64>",
  "signed_prekey": "<base64>",
  "signature": "<base64 signature of signed_prekey>",
  "one_time_prekeys": [
    { "id": 1, "content": "<base64>" },
    { "id": 2, "content": "<base64>" }
  ]
}
```

`device_id` defaults to `main`. `identity_key`, `signed_prekey` and `signature` are required.

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "message": "Prekey cryptographical parameters saved successfully",
    "requires_refill": false
  }
}
```

`requires_refill` is `true` when fewer than 10 one-time prekeys remain for the device.

#### `400 Bad Request`

`"Malformatted JSON configuration payload structure"`.

#### `500 Internal Server Error`

Returned when a required key is missing (`"missing core payload parameters for prekey bundle submission"`) or the database write fails.

### 2. Fetch Prekey Bundle

Returns a user's public keys so that you can start a session with them. Each call **consumes** (deletes) one one-time prekey. When the user has none left, the `one_time_prekey_*` fields are omitted.

- **URL:** `/api/e2ee/bundle/{userId}?device_id=main`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/e2ee/bundle/{userId}?device_id=main" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "user_id": "<user_id>",
    "device_id": "main",
    "identity_key": "<base64>",
    "signed_prekey": "<base64>",
    "signature": "<base64>",
    "one_time_prekey_id": 1,
    "one_time_prekey_body": "<base64>"
  }
}
```

#### `404 Not Found`

Returned when the user hasn't uploaded keys yet:

```json
{
  "success": false,
  "error": "device keys not found for target identity profile"
}
```

### 3. Set Contact Verification

Records whether you have verified a contact's identity key (e.g. by comparing safety numbers or scanning a QR code).

- **URL:** `/api/e2ee/verify`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/e2ee/verify" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "verified_user_id": "<user_id>", "is_verified": true }'`

#### Request Body

```json
{
  "verified_user_id": "<user_id>",
  "is_verified": true
}
```

#### `200 OK`

```json
{
  "success": true,
  "data": { "message": "Contact verification status updated" }
}
```

#### `400 Bad Request`

`"Invalid JSON payload structure"`, `"target verified_user_id is required"` or `"cannot verify own user identity"`.

### 4. Get Contact Verification

- **URL:** `/api/e2ee/verify/{userId}`
- **Method:** `GET`
- **Authentication Required:** `YES`
- **curl:** `curl "http://HOST:PORT/api/e2ee/verify/{userId}" -H "Authorization: Bearer <access_token>"`

#### `200 OK`

`is_verified` is `false` if you never verified this user, or if they have uploaded a new identity key since you did.

```json
{
  "success": true,
  "data": {
    "user_id": "<your user_id>",
    "verified_user_id": "<user_id>",
    "is_verified": true
  }
}
```

### 5. Reset Encryption Keys

Deletes all of your devices, identity keys and one-time prekeys, and marks every other user's verification of you as unverified. Afterwards, generate and [upload](#1-upload-prekey-bundle) a new bundle.

- **URL:** `/api/e2ee/reset`
- **Method:** `POST`
- **Authentication Required:** `YES`
- **curl:** `curl -X POST "http://HOST:PORT/api/e2ee/reset" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "password": "<password>" }'`

#### Request Body

```json
{
  "password": "<your account password>"
}
```

#### `200 OK`

```json
{
  "success": true,
  "data": {
    "message": "All encryption keys wiped successfully. Please re-generate and upload a new prekey bundle."
  }
}
```

#### `401 Unauthorized`

`"password required for re-authentication"`, `"invalid password re-authentication attempt"` or `"user account context not found"`.
