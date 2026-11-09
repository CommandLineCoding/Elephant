// Package migrations embeds the SQL migrations so the server binary can apply
// them itself at startup. The same files are used by migrate.sh and Compose.
package migrations

import "embed"

//go:embed *_up.sql
var FS embed.FS
