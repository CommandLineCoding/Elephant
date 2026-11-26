package models

import (
	"encoding/json"
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

	Messages []ExportMessage `json:"messages"`
	Hidden   []ExportHidden  `json:"hidden_messages"`
	Cleared  []ExportCleared `json:"cleared_chats"`

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
}

// ExportHidden is a message the person deleted for themselves only.
type ExportHidden struct {
	MessageID string `json:"message_id"`
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
