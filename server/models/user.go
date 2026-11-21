package models

import "time"

type User struct {
	ID           string    `json:"id"`
	Username     string    `json:"username"`
	Email        string    `json:"email,omitempty"`
	DisplayName  string    `json:"display_name"`
	PasswordHash string    `json:"-"`
	GoogleID     string    `json:"google_id,omitempty"`
	GithubID     string    `json:"github_id,omitempty"`
	CreatedAt    time.Time `json:"created_at"`

	// UsernameChangedAt is when the username was last changed. It is only
	// sent to the person themselves.
	UsernameChangedAt *time.Time `json:"username_changed_at,omitempty"`

	// Bio is the person's "about" text, up to 140 characters.
	Bio string `json:"bio"`

	// Status is their custom status, if they have one that hasn't expired.
	Status *UserStatus `json:"status,omitempty"`
}

// UserStatus is a custom status: an emoji and a few words, until ExpiresAt if
// that is set.
type UserStatus struct {
	Emoji     string     `json:"emoji"`
	Text      string     `json:"text"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
}
