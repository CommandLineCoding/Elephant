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
| Access token | 15 minutes | HS256 JWT, `sub` = user ID. Send it as a Bearer token, or as `?token=` for the WebSocket |
| Refresh token | 7 days | HS256 JWT. Its hash is stored server-side. Each refresh **rotates** it, so the old refresh token stops working |

### Common error: `401 Unauthorized`

Every route behind the auth guard returns this when the access token is missing, expired or malformed. The sections below don't repeat it.

```json
{
  "success": false,
  "error": "Access token missing, expired or malformed"
}
```

---

## API Overview

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| GET | [/api/health](#health-endpoint) | No | Health check (server + database status) |
| POST | [/api/auth/register](#1-register-user) | No | Register a new user |
| POST | [/api/auth/login](#2-login-user) | No | Log in and receive a token pair |
| POST | [/api/auth/refresh](#3-refresh) | No | Rotate a refresh token for a new token pair |
| GET | [/api/auth/{provider}](#4-oauth-redirect) | No | Start Google / GitHub OAuth sign-in |
| GET | [/api/auth/{provider}/callback](#5-oauth-callback) | No | OAuth callback that hands tokens back to the app |
| GET | [/api/users/me](#1-user-me) | Yes | Get the authenticated user's profile |
| GET | [/api/users/{id}](#2-get-user-by-id) | Yes | Get a user by ID |
| GET | [/api/users/search?q=&page=&limit=](#3-search-users) | Yes | Search users by username or display name (rate limited) |
| GET | [/api/ws?token=](#1-connect-to-websocket) | Yes (query) | WebSocket upgrade endpoint |
| WS | [Client → Server](#2-client-to-server-messages) | — | Events the client sends |
| WS | [Server → Client](#3-server-to-client-messages) | — | Events the server pushes |
| POST | [/api/messages](#1-send-message) | Yes | Send a direct message (REST fallback, no live delivery) |
| GET | [/api/messages?with=&before=&limit=](#2-direct-message-history) | Yes | Paginated direct message history |
| GET | [/api/messages/conversations](#3-conversations) | Yes | Inbox: latest message and unread count per chat |
| PUT | [/api/messages/{id}](#4-edit-message) | Yes | Edit your own message (15-minute window) |
| POST | [/api/messages/read](#5-mark-direct-messages-read) | Yes | Mark a sender's messages as read |
| POST | [/api/groups](#1-create-group) | Yes | Create a group |
| GET | [/api/groups](#2-list-my-groups) | Yes | List the groups you belong to |
| GET | [/api/groups/{id}](#3-get-group-by-id) | Member | Get group details |
| GET | [/api/groups/{id}/messages?before=&limit=](#4-group-message-history) | Member | Paginated group message history |
| GET | [/api/groups/{id}/members](#5-group-members) | Member | List group members |
| POST | [/api/groups/{id}/leave](#6-leave-group) | Member | Leave a group |
| PATCH | [/api/groups/{id}](#7-update-group-details) | Admin | Rename a group |
| POST | [/api/groups/{id}/members](#8-add-member-to-group) | Admin | Add a member |
| DELETE | [/api/groups/{id}/members/{userId}](#9-remove-member-from-group) | Admin | Remove a member |
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
    "timestamp": "<Timestamp>"
  }
}
```

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
  "password": "<password>"
}
```

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
  "password": "<password>"
}
```

The username is trimmed and lowercased before lookup.

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

### 3. Refresh

Exchanges a refresh token for a new access/refresh pair. The submitted refresh token is revoked.

- **URL:** `/api/auth/refresh`
- **Method:** `POST`
- **Authentication Required:** `NO`
- **curl:** `curl -X POST http://HOST:PORT/api/auth/refresh -H "Content-Type: application/json" -d '{ "refresh_token": "<refresh_token>" }' -s`

#### Request Body

```json
{
  "refresh_token": "<refresh_token>"
}
```

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
3. Otherwise, create a new user. The username is `<alphanumeric email handle>.<4 digits>` and the display name comes from the provider. OAuth-only accounts have no usable password.

GitHub sign-in requires a verified primary email on the GitHub account.

#### `200 OK` (HTML)

Returns an HTML handoff page that opens the app with the token pair:

```
elephant://oauth-callback?access_token=<access_token>&refresh_token=<refresh_token>
```

On Android, the page first tries an `intent://…#Intent;scheme=elephant;package=in.commandlinecoding.elephant;end;` URL, then falls back to the custom scheme.

#### `401 Unauthorized` (HTML)

An "Authentication Failed" HTML page is returned when the state cookie doesn't match, the provider exchange fails, or the account can't be created.

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
    "created_at": "<Timestamp>"
  }
}
```

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
    "created_at": "<Timestamp>"
  }
}
```

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
| `q` | `""` | An empty query matches every user |
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

---

## WebSocket Endpoints

### 1. Connect to WebSocket

- **URL:** `/api/ws?token={access_token}`
- **Method:** `GET` (WebSocket upgrade)
- **Authentication Required:** `YES` (access token in the `token` query parameter)
- **wscat:** `wscat -c "ws://HOST:PORT/api/ws?token={access_token}"`

#### `101 Switching Protocols`

The connection is open. All other connected users receive a `user_status` event with `online: true`.

#### `401 Unauthorized`

Returned (with no body) when `token` is missing, expired or invalid.

```
error: Unexpected server response: 401
```

#### Connection behaviour

- The server sends a WebSocket ping every 54 seconds. A connection that hasn't sent a pong (or any message) within 60 seconds is closed.
- The maximum inbound frame size is **4096 bytes**. Larger frames close the connection, so keep encrypted payloads small.
- Each user has one live connection. A new connection for the same user replaces the previous one in the hub.
- Unknown `type` values (e.g. an application-level `ping`) and malformed JSON are ignored.
- The server never echoes a sent event back to the sender.

### Direct vs. group targeting

Every event targets **either** a user (`receiver_id`) **or** a group (`group_id`), never both. For group events, the server fans the event out to every member of the group except the sender.

### Message content format (E2EE)

The server stores and relays `content` as an opaque string. The Elephant app sends a JSON-encoded envelope:

```json
"{\"type\": <int>, \"ciphertext\": \"<base64 or text>\"}"
```

- **Direct messages:** `ciphertext` is a base64-encoded Signal Protocol message, and `type` is the libsignal ciphertext message type. The first message to a new contact is a PreKey message built from the contact's [prekey bundle](#2-fetch-prekey-bundle).
- **Group messages:** currently sent with `type: 0`, and `ciphertext` holds the **plaintext** message. Group messages are not yet end-to-end encrypted.

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
- For a group, send `group_id` instead of `receiver_id`.

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

The server replies directly with a [`user_status`](#5-user-status) event.

#### 4. Typing Indicator

```json
{
  "type": "typing",
  "receiver_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  "content": "true"
}
```

`content` is relayed as-is. The app sends `"true"` when typing starts and `"false"` when it stops. Use `group_id` for groups.

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

Broadcast to every connected client when a user connects or disconnects. Also sent directly in response to `request_status`.

```json
{
  "type": "user_status",
  "user_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "online": true
}
```

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
  "reply_to_message_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
  "quoted_message": {
    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "sender_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "content": "<quoted content>"
  }
}
```

`receiver_id`, `group_id`, `edited_at`, `reply_to_message_id` and `quoted_message` are omitted when empty.

### 1. Send Message

REST fallback for direct messages. The message is stored but **not** pushed over the WebSocket.

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
      "unread_count": 3
    }
  ]
}
```

- `type` is `direct` or `group`.
- **Direct:** `is_read` is the read flag of the last message, and `unread_count` counts unread messages sent to you.
- **Group:** `is_read` is true if the last message is no newer than your `last_read_at`, and `unread_count` counts other members' messages since then.

#### `500 Internal Server Error`

`"Failed to compile inbox conversations"`.

### 4. Edit Message

Replaces the content of a message you sent. Edits are only allowed within **15 minutes** of `created_at`, and they are not broadcast over the WebSocket. For E2EE direct messages, the client must send newly encrypted content.

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
    "created_at": "<Timestamp>"
  }
}
```

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

- **URL:** `/api/groups/{id}`
- **Method:** `PATCH`
- **Authentication Required:** `YES` (admin)
- **curl:** `curl -X PATCH "http://HOST:PORT/api/groups/{id}" -H "Content-Type: application/json" -H "Authorization: Bearer <access_token>" -d '{ "name": "<new_group_name>" }'`

#### Request Body

```json
{
  "name": "<new_group_name>"
}
```

#### `200 OK`

```json
{
  "success": true,
  "data": "Group details updated successfully"
}
```

#### `400 Bad Request`

`"Invalid group name"`.

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

#### `500 Internal Server Error`

Returned when the user doesn't exist:

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
