package models

import "time"

type Group struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`

	// Description is what admins say the group is for, up to 500 characters.
	Description string `json:"description"`

	// AdminsOnly means only admins may send messages (members can still react
	// and vote).
	AdminsOnly bool `json:"admins_only"`
}

type GroupMember struct {
	GroupID  string    `json:"group_id"`
	UserID   string    `json:"user_id"`
	Role     string    `json:"role"`
	JoinedAt time.Time `json:"joined_at"`
}

type GroupMemberDetail struct {
	UserID      string    `json:"user_id"`
	Username    string    `json:"username"`
	DisplayName string    `json:"display_name"`
	Role        string    `json:"role"`
	JoinedAt    time.Time `json:"joined_at"`
}
