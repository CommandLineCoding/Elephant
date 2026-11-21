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
}
