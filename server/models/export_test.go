package models

import (
	"encoding/base64"
	"errors"
	"net/url"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

// Columns that would let whoever holds an export act as the person. None of
// them may become a field of the export, at any depth.
var exportSecrets = []string{
	"password", "password_hash",
	"token", "token_hash", "refresh_token", "access_token",
	"secret", "secret_enc", "code_hash", "recovery_codes", "last_used_step",
	"endpoint", "code", "invite_code",
	"private_key", "identity_key_pair",
}

// jsonKeys lists every JSON key t can produce, with its path.
func jsonKeys(t reflect.Type, path string, seen map[reflect.Type]bool, out map[string]string) {
	for t.Kind() == reflect.Pointer || t.Kind() == reflect.Slice {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct || seen[t] {
		return
	}
	seen[t] = true
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
		if name == "-" || !f.IsExported() {
			continue
		}
		if name == "" {
			name = f.Name
		}
		out[name] = path + "." + name
		jsonKeys(f.Type, path+"."+name, seen, out)
	}
}

func TestTheAccountExportHasNoSecretFields(t *testing.T) {
	keys := map[string]string{}
	jsonKeys(reflect.TypeOf(AccountExport{}), "data", map[reflect.Type]bool{}, keys)
	jsonKeys(reflect.TypeOf(ExportMessagePage{}), "page", map[reflect.Type]bool{}, keys)
	for _, secret := range exportSecrets {
		if path, ok := keys[secret]; ok {
			t.Errorf("the export has %s", path)
		}
	}
	// Go field names count too: a field without a json tag is sent by name.
	for key, path := range keys {
		lower := strings.ToLower(key)
		if strings.Contains(lower, "password") || strings.Contains(lower, "secret") || strings.Contains(lower, "hash") {
			t.Errorf("the export has %s", path)
		}
	}
}

// exportFields is every field each part of the export may have. A new field
// fails this test until it is added here, so someone decides on purpose that
// it is the person's to take, and not a secret or someone else's. The
// sections are the ones docs/API_CONTRACTS.md describes.
var exportFields = map[string][]string{
	"AccountExport": {"app", "format", "exported_at", "account", "settings", "two_factor", "sessions", "devices",
		"push_endpoints", "blocked_users", "verified_contacts", "message_requests", "groups",
		"group_join_requests", "messages", "messages_next", "messages_truncated", "cleared_chats", "statuses",
		"received_statuses", "reports"},
	"ExportAccount": {"id", "username", "display_name", "email", "google_id", "github_id", "created_at",
		"username_changed_at", "bio", "status_emoji", "status_text", "status_expires_at"},
	"ExportSettings":       {"online_status", "read_receipts", "group_adds"},
	"ExportTwoFactor":      {"enabled", "created_at", "recovery_codes_left"},
	"ExportSession":        {"id", "device_name", "started_at", "last_used_at", "expires_at"},
	"ExportDevice":         {"device_id", "identity_key", "signed_prekey", "signed_prekey_signature", "one_time_prekeys", "updated_at"},
	"ExportPush":           {"created_at", "updated_at", "failures"},
	"ExportBlock":          {"user_id", "blocked_at"},
	"ExportVerification":   {"user_id", "is_verified", "updated_at"},
	"ExportRequest":        {"sender_id", "created_at"},
	"ExportGroup":          {"id", "name", "description", "admins_only", "created_by", "created_at", "role", "joined_at", "last_read_at"},
	"ExportJoinRequest":    {"group_id", "requested_at"},
	"ExportMessage":        {"id", "sender_id", "receiver_id", "group_id", "content", "created_at", "is_read", "delivered_at", "edited_at", "deleted_at", "expires_at", "reply_to_message_id", "silent", "hidden"},
	"ExportMessagePage":    {"messages", "messages_next"},
	"ExportCleared":        {"peer_id", "group_id", "cleared_at"},
	"ExportStatus":         {"id", "created_at", "expires_at", "recipients"},
	"ExportReceivedStatus": {"id", "author_id", "content", "created_at", "expires_at", "viewed_at"},
	"ExportReport":         {"id", "reported_user_id", "reason", "note", "messages", "created_at"},
}

// structFields maps each struct reachable from t (by value, pointer or slice)
// to the JSON keys it produces. time.Time is a value, not a part.
func structFields(t reflect.Type, out map[string][]string) {
	for t.Kind() == reflect.Pointer || t.Kind() == reflect.Slice {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct || t == reflect.TypeOf(time.Time{}) {
		return
	}
	if _, done := out[t.Name()]; done {
		return
	}
	out[t.Name()] = []string{}
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
		if name == "-" || !f.IsExported() {
			continue
		}
		if name == "" {
			name = f.Name
		}
		out[t.Name()] = append(out[t.Name()], name)
		structFields(f.Type, out)
	}
}

func TestTheAccountExportHasOnlyTheFieldsChosenForIt(t *testing.T) {
	got := map[string][]string{}
	structFields(reflect.TypeOf(AccountExport{}), got)
	structFields(reflect.TypeOf(ExportMessagePage{}), got)
	for name, keys := range got {
		want, ok := exportFields[name]
		if !ok {
			t.Errorf("%s is part of the export but not in exportFields: decide what it may hold", name)
			continue
		}
		if !slices.Equal(keys, want) {
			t.Errorf("%s has %v, want %v: decide whether the new field belongs in an export", name, keys, want)
		}
	}
	for name := range exportFields {
		if _, ok := got[name]; !ok {
			t.Errorf("exportFields lists %s, which is no longer in the export", name)
		}
	}
}

func TestAnExportCursorComesBackAsItWent(t *testing.T) {
	want := ExportCursor{
		// Postgres keeps microseconds, so the cursor must keep them too.
		CreatedAt: time.Date(2026, 11, 27, 10, 30, 0, 123456000, time.UTC),
		ID:        "0b6c3f1e-8a2d-4c5e-9f10-1a2b3c4d5e6f",
	}
	got, err := ParseExportCursor(want.String())
	if err != nil {
		t.Fatal(err)
	}
	if !got.CreatedAt.Equal(want.CreatedAt) || got.ID != want.ID {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestABadExportCursorIsRefused(t *testing.T) {
	enc := base64.RawURLEncoding.EncodeToString
	for name, s := range map[string]string{
		"not base64":     "%%%",
		"no id":          enc([]byte("2026-11-27T10:30:00Z")),
		"not a uuid":     enc([]byte("2026-11-27T10:30:00Z x'); DROP TABLE messages; --")),
		"uppercase uuid": enc([]byte("2026-11-27T10:30:00Z 0B6C3F1E-8A2D-4C5E-9F10-1A2B3C4D5E6F")),
		"not a time":     enc([]byte("yesterday 0b6c3f1e-8a2d-4c5e-9f10-1a2b3c4d5e6f")),
	} {
		if _, err := ParseExportCursor(s); !errors.Is(err, ErrExportCursor) {
			t.Errorf("%s: %v, want ErrExportCursor", name, err)
		}
	}
}

func TestTheExportMessageQueryHasDefaultsAndBounds(t *testing.T) {
	cursor := ExportCursor{CreatedAt: time.Date(2026, 11, 27, 0, 0, 0, 0, time.UTC), ID: "0b6c3f1e-8a2d-4c5e-9f10-1a2b3c4d5e6f"}.String()
	ok := []struct {
		query  string
		limit  int
		direct bool
		after  bool
	}{
		{"", ExportMessagesDefault, false, false},
		{"limit=1", 1, false, false},
		{"limit=2000", ExportMessagesMax, false, false},
		{"include=direct_messages", ExportMessagesDefault, true, false},
		{"include=direct_messages,&limit=10", 10, true, false},
		{"after=" + cursor, ExportMessagesDefault, false, true},
	}
	for _, c := range ok {
		q, _ := url.ParseQuery(c.query)
		got, err := ParseExportMessageQuery(q)
		if err != nil {
			t.Errorf("%q: %v", c.query, err)
			continue
		}
		if got.Limit != c.limit || got.DirectMessages != c.direct || (got.After != nil) != c.after {
			t.Errorf("%q: %+v", c.query, got)
		}
	}

	bad := map[string]error{
		"limit=0":                        ErrExportLimit,
		"limit=-5":                       ErrExportLimit,
		"limit=2001":                     ErrExportLimit,
		"limit=ten":                      ErrExportLimit,
		"limit=1.5":                      ErrExportLimit,
		"include=photos":                 ErrExportInclude,
		"include=direct_messages,photos": ErrExportInclude,
		"after=nope":                     ErrExportCursor,
	}
	for query, want := range bad {
		q, _ := url.ParseQuery(query)
		if _, err := ParseExportMessageQuery(q); !errors.Is(err, want) {
			t.Errorf("%q: %v, want %v", query, err, want)
		}
	}
}
