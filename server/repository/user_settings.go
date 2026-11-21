package repository

import (
	"context"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/jackc/pgx/v5"
)

// Who may do or see something.
const (
	AudienceEveryone = "everyone"
	AudienceContacts = "contacts"
	AudienceNobody   = "nobody"
)

// UserSettings is what a person lets others see and do.
type UserSettings struct {
	OnlineStatus string `json:"online_status"`
	ReadReceipts bool   `json:"read_receipts"`
	GroupAdds    string `json:"group_adds"`
}

// DefaultUserSettings is what a person who never changed anything has. It is
// how the server behaved before there were settings.
func DefaultUserSettings() UserSettings {
	return UserSettings{
		OnlineStatus: AudienceContacts,
		ReadReceipts: true,
		GroupAdds:    AudienceEveryone,
	}
}

// ValidAudience reports whether v is one of the three audiences.
func ValidAudience(v string) bool {
	return v == AudienceEveryone || v == AudienceContacts || v == AudienceNobody
}

// UserSettingsPatch is a change to some settings. Nil fields stay as they are.
type UserSettingsPatch struct {
	OnlineStatus *string `json:"online_status"`
	ReadReceipts *bool   `json:"read_receipts"`
	GroupAdds    *string `json:"group_adds"`
}

type UserSettingsRepository struct{}

func NewUserSettingsRepository() *UserSettingsRepository { return &UserSettingsRepository{} }

// Get returns a person's settings, or the defaults if they never saved any.
func (r *UserSettingsRepository) Get(ctx context.Context, userID string) (UserSettings, error) {
	s := DefaultUserSettings()
	err := config.DB.QueryRow(ctx, `
		SELECT online_status, read_receipts, group_adds
		FROM user_settings WHERE user_id = $1::uuid;
	`, userID).Scan(&s.OnlineStatus, &s.ReadReceipts, &s.GroupAdds)
	if err == pgx.ErrNoRows {
		return DefaultUserSettings(), nil
	}
	return s, err
}

// Update applies a patch and returns the settings after it. The caller has
// already checked the values.
func (r *UserSettingsRepository) Update(ctx context.Context, userID string, p UserSettingsPatch) (UserSettings, error) {
	d := DefaultUserSettings()
	var s UserSettings
	err := config.DB.QueryRow(ctx, `
		INSERT INTO user_settings (user_id, online_status, read_receipts, group_adds)
		VALUES ($1::uuid, COALESCE($2::text, $5::text), COALESCE($3::boolean, $6::boolean), COALESCE($4::text, $7::text))
		ON CONFLICT (user_id) DO UPDATE SET
			online_status = COALESCE($2::text, user_settings.online_status),
			read_receipts = COALESCE($3::boolean, user_settings.read_receipts),
			group_adds    = COALESCE($4::text, user_settings.group_adds),
			updated_at    = NOW()
		RETURNING online_status, read_receipts, group_adds;
	`, userID, p.OnlineStatus, p.ReadReceipts, p.GroupAdds,
		d.OnlineStatus, d.ReadReceipts, d.GroupAdds).Scan(&s.OnlineStatus, &s.ReadReceipts, &s.GroupAdds)
	return s, err
}
