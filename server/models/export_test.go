package models

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
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

// The sections are the ones docs/API_CONTRACTS.md describes, so a new one
// isn't added without saying what it holds.
func TestTheAccountExportNamesEverySection(t *testing.T) {
	raw, err := json.Marshal(AccountExport{})
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{
		"app", "format", "exported_at", "account", "settings", "two_factor", "sessions", "devices",
		"push_endpoints", "blocked_users", "verified_contacts", "message_requests", "groups",
		"group_join_requests", "messages", "hidden_messages", "cleared_chats", "statuses",
		"received_statuses", "reports",
	} {
		if _, ok := top[key]; !ok {
			t.Errorf("no %q in the export", key)
		}
	}
	if len(top) != 20 {
		t.Errorf("%d sections, want 20: update this test and docs/API_CONTRACTS.md together", len(top))
	}
}
