package models

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ExportFormat is the version of the account export. It goes up when a field
// changes meaning; new fields can be added without it.
const ExportFormat = 1

// AccountExport is everything the server keeps about one person, as GET
// /api/users/me/export returns it (see "Account export" in
// docs/API_CONTRACTS.md). Secrets are left out on purpose: the password hash,
// refresh token hashes, the two-step secret and recovery code hashes, push
// endpoint URLs and group invite codes. Each would let whoever holds the file
// act as the person, and none of it says anything they don't already know.
type AccountExport struct {
	App        string    `json:"app"`
	Format     int       `json:"format"`
	ExportedAt time.Time `json:"exported_at"`

	Account   ExportAccount   `json:"account"`
	Settings  ExportSettings  `json:"settings"`
	TwoFactor ExportTwoFactor `json:"two_factor"`
	Sessions  []ExportSession `json:"sessions"`
	Devices   []ExportDevice  `json:"devices"`
	Push      []ExportPush    `json:"push_endpoints"`

	Blocked       []ExportBlock        `json:"blocked_users"`
	Verifications []ExportVerification `json:"verified_contacts"`
	Requests      []ExportRequest      `json:"message_requests"`

	Groups       []ExportGroup       `json:"groups"`
	JoinRequests []ExportJoinRequest `json:"group_join_requests"`

	// Messages is the first page only; MessagesNext is the cursor for
	// GET /api/users/me/export/messages, or nil when there is no more.
	Messages          []ExportMessage `json:"messages"`
	MessagesNext      *string         `json:"messages_next"`
	MessagesTruncated bool            `json:"messages_truncated"`
	Cleared           []ExportCleared `json:"cleared_chats"`

	Statuses         []ExportStatus         `json:"statuses"`
	ReceivedStatuses []ExportReceivedStatus `json:"received_statuses"`
	Reports          []ExportReport         `json:"reports"`
}

// ExportAccount is the row in users, without the password hash.
type ExportAccount struct {
	ID                string     `json:"id"`
	Username          string     `json:"username"`
	DisplayName       string     `json:"display_name"`
	Email             *string    `json:"email"`
	GoogleID          *string    `json:"google_id"`
	GithubID          *string    `json:"github_id"`
	CreatedAt         time.Time  `json:"created_at"`
	UsernameChangedAt *time.Time `json:"username_changed_at"`
	Bio               string     `json:"bio"`
	StatusEmoji       string     `json:"status_emoji"`
	StatusText        string     `json:"status_text"`
	StatusExpiresAt   *time.Time `json:"status_expires_at"`
}

// ExportSettings is the privacy settings, or the defaults if the person never
// changed them.
type ExportSettings struct {
	OnlineStatus string `json:"online_status"`
	ReadReceipts bool   `json:"read_receipts"`
	GroupAdds    string `json:"group_adds"`
}

// ExportTwoFactor says whether two-step sign-in is on. The secret and the
// recovery codes are not in the export.
type ExportTwoFactor struct {
	Enabled           bool       `json:"enabled"`
	CreatedAt         *time.Time `json:"created_at"`
	RecoveryCodesLeft int        `json:"recovery_codes_left"`
}

// ExportSession is one signed-in device. The refresh token is not in the
// export.
type ExportSession struct {
	ID         string    `json:"id"`
	DeviceName string    `json:"device_name"`
	StartedAt  time.Time `json:"started_at"`
	LastUsedAt time.Time `json:"last_used_at"`
	ExpiresAt  time.Time `json:"expires_at"`
}

// ExportDevice is one device's public encryption keys, as anyone who starts a
// chat with the person can fetch them. The private keys never reach the
// server.
type ExportDevice struct {
	DeviceID              string     `json:"device_id"`
	IdentityKey           string     `json:"identity_key"`
	SignedPrekey          string     `json:"signed_prekey"`
	SignedPrekeySignature string     `json:"signed_prekey_signature"`
	OneTimePrekeys        int        `json:"one_time_prekeys"`
	UpdatedAt             *time.Time `json:"updated_at"`
}

// ExportPush is one push registration. The endpoint URL itself is left out:
// anyone who has it can send pings to the phone.
type ExportPush struct {
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	Failures  int       `json:"failures"`
}

// ExportBlock is someone the person blocked.
type ExportBlock struct {
	UserID    string    `json:"user_id"`
	BlockedAt time.Time `json:"blocked_at"`
}

// ExportVerification is a contact whose safety number the person marked.
type ExportVerification struct {
	UserID     string     `json:"user_id"`
	IsVerified bool       `json:"is_verified"`
	UpdatedAt  *time.Time `json:"updated_at"`
}

// ExportRequest is a message request waiting for the person to accept it.
type ExportRequest struct {
	SenderID  string    `json:"sender_id"`
	CreatedAt time.Time `json:"created_at"`
}

// ExportGroup is a group the person is in, with their place in it.
type ExportGroup struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Description string     `json:"description"`
	AdminsOnly  bool       `json:"admins_only"`
	CreatedBy   *string    `json:"created_by"`
	CreatedAt   *time.Time `json:"created_at"`
	Role        string     `json:"role"`
	JoinedAt    *time.Time `json:"joined_at"`
	LastReadAt  *time.Time `json:"last_read_at"`
}

// ExportJoinRequest is a request to join a group through its invite link that
// an admin hasn't answered yet.
type ExportJoinRequest struct {
	GroupID     string    `json:"group_id"`
	RequestedAt time.Time `json:"requested_at"`
}

// ExportMessage is a message as the server stores it. Content is what the
// sending phone uploaded: Signal ciphertext for direct messages, which only
// the phones can read, and a plaintext envelope for group messages.
type ExportMessage struct {
	ID               string     `json:"id"`
	SenderID         string     `json:"sender_id"`
	ReceiverID       *string    `json:"receiver_id"`
	GroupID          *string    `json:"group_id"`
	Content          string     `json:"content"`
	CreatedAt        time.Time  `json:"created_at"`
	IsRead           bool       `json:"is_read"`
	DeliveredAt      *time.Time `json:"delivered_at"`
	EditedAt         *time.Time `json:"edited_at"`
	DeletedAt        *time.Time `json:"deleted_at"`
	ExpiresAt        *time.Time `json:"expires_at"`
	ReplyToMessageID *string    `json:"reply_to_message_id"`
	Silent           bool       `json:"silent"`
	Hidden           bool       `json:"hidden"`
}

// ExportMessagePage is one page of GET /api/users/me/export/messages. Next is
// the cursor for the page after it, or nil on the last one.
type ExportMessagePage struct {
	Messages []ExportMessage `json:"messages"`
	Next     *string         `json:"next"`
}

// One request reads at most ExportMessagesMax messages, so its memory stays
// the same whatever the size of the account. A message is at most 4 KB, so a
// full page is around 10 MB of JSON.
const (
	ExportMessagesDefault = 1000
	ExportMessagesMax     = 2000
)

// ExportMessageQuery is which page of messages to export.
type ExportMessageQuery struct {
	// After is where the previous page ended, or nil for the first page.
	After *ExportCursor
	Limit int
	// DirectMessages adds the direct messages, sent and received. They are
	// ciphertext only the phones can read, so they are left out by default.
	DirectMessages bool
}

var (
	ErrExportLimit   = errors.New("limit must be a whole number from 1 to " + strconv.Itoa(ExportMessagesMax))
	ErrExportInclude = errors.New("include can only be direct_messages")
	ErrExportCursor  = errors.New("after is not a cursor from a previous page")
)

// ParseExportMessageQuery reads limit, include and after from q. An empty or
// missing value takes the default; anything else that isn't valid is an
// error, so a client never gets a different page than it asked for.
func ParseExportMessageQuery(q url.Values) (ExportMessageQuery, error) {
	out := ExportMessageQuery{Limit: ExportMessagesDefault}
	if s := q.Get("limit"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > ExportMessagesMax {
			return out, ErrExportLimit
		}
		out.Limit = n
	}
	for _, list := range q["include"] {
		for _, v := range strings.Split(list, ",") {
			switch strings.TrimSpace(v) {
			case "":
			case "direct_messages":
				out.DirectMessages = true
			default:
				return out, ErrExportInclude
			}
		}
	}
	if s := q.Get("after"); s != "" {
		c, err := ParseExportCursor(s)
		if err != nil {
			return out, err
		}
		out.After = &c
	}
	return out, nil
}

// ExportCursor is the last message of a page: the next page starts after it
// in (created_at, id) order.
type ExportCursor struct {
	CreatedAt time.Time
	ID        string
}

// String is the cursor as the client gets it. Clients should treat it as
// opaque.
func (c ExportCursor) String() string {
	return base64.RawURLEncoding.EncodeToString([]byte(c.CreatedAt.UTC().Format(time.RFC3339Nano) + " " + c.ID))
}

// ParseExportCursor reads a cursor made by String.
func ParseExportCursor(s string) (ExportCursor, error) {
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return ExportCursor{}, ErrExportCursor
	}
	at, id, ok := strings.Cut(string(raw), " ")
	if !ok || !isUUID(id) {
		return ExportCursor{}, ErrExportCursor
	}
	t, err := time.Parse(time.RFC3339Nano, at)
	if err != nil {
		return ExportCursor{}, ErrExportCursor
	}
	return ExportCursor{CreatedAt: t, ID: id}, nil
}

// isUUID reports whether s is a UUID in its usual lowercase text form.
func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if r != '-' {
				return false
			}
		case (r < '0' || r > '9') && (r < 'a' || r > 'f'):
			return false
		}
	}
	return true
}

// ExportCleared is a chat the person cleared: they no longer see what came
// before ClearedAt.
type ExportCleared struct {
	PeerID    *string   `json:"peer_id"`
	GroupID   *string   `json:"group_id"`
	ClearedAt time.Time `json:"cleared_at"`
}

// ExportStatus is a status the person posted. The server keeps one encrypted
// copy per recipient; only how many is exported.
type ExportStatus struct {
	ID         string    `json:"id"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	Recipients int       `json:"recipients"`
}

// ExportReceivedStatus is the copy of someone's status that was encrypted for
// the person.
type ExportReceivedStatus struct {
	ID        string     `json:"id"`
	AuthorID  string     `json:"author_id"`
	Content   string     `json:"content"`
	CreatedAt time.Time  `json:"created_at"`
	ExpiresAt time.Time  `json:"expires_at"`
	ViewedAt  *time.Time `json:"viewed_at"`
}

// ExportReport is a report the person sent, with the messages they chose to
// attach.
type ExportReport struct {
	ID             int64           `json:"id"`
	ReportedUserID string          `json:"reported_user_id"`
	Reason         string          `json:"reason"`
	Note           string          `json:"note"`
	Messages       json.RawMessage `json:"messages"`
	CreatedAt      time.Time       `json:"created_at"`
}
