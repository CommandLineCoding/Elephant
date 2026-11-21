package repository

import (
	"context"
	"encoding/json"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
)

// Why someone was reported.
const (
	ReportSpam       = "spam"
	ReportHarassment = "harassment"
	ReportOther      = "other"
)

// ValidReportReason reports whether v is one of the reasons.
func ValidReportReason(v string) bool {
	return v == ReportSpam || v == ReportHarassment || v == ReportOther
}

// ReportedMessage is one message a reporter chose to send with a report, as
// plain text.
type ReportedMessage struct {
	FromReported bool      `json:"from_reported"`
	Text         string    `json:"text"`
	At           time.Time `json:"at"`
}

// NewReport is what a person sends.
type NewReport struct {
	ReporterID     string
	ReportedUserID string
	Reason         string
	Note           string
	Messages       []ReportedMessage
}

// Report is a stored report with the names of both people.
type Report struct {
	ID               int64             `json:"id"`
	ReporterID       string            `json:"reporter_id"`
	ReporterName     string            `json:"reporter_username"`
	ReportedUserID   string            `json:"reported_user_id"`
	ReportedUsername string            `json:"reported_username"`
	Reason           string            `json:"reason"`
	Note             string            `json:"note"`
	Messages         []ReportedMessage `json:"messages"`
	CreatedAt        time.Time         `json:"created_at"`
}

type ReportRepository struct{}

func NewReportRepository() *ReportRepository { return &ReportRepository{} }

// Create stores a report. It returns ErrUnknownPeer if the reported person
// doesn't exist.
func (r *ReportRepository) Create(ctx context.Context, n NewReport) (int64, error) {
	msgs, err := json.Marshal(n.Messages)
	if err != nil {
		return 0, err
	}
	if n.Messages == nil {
		msgs = []byte("[]")
	}
	var id int64
	err = config.DB.QueryRow(ctx, `
		INSERT INTO reports (reporter_id, reported_user_id, reason, note, messages)
		VALUES ($1::uuid, $2::uuid, $3, $4, $5::jsonb)
		RETURNING id;
	`, n.ReporterID, n.ReportedUserID, n.Reason, n.Note, string(msgs)).Scan(&id)
	return id, foreignKeyAsUnknownPeer(err)
}

// CountSince is how many reports a person made since t.
func (r *ReportRepository) CountSince(ctx context.Context, reporterID string, t time.Time) (int, error) {
	var n int
	err := config.DB.QueryRow(ctx,
		`SELECT count(*) FROM reports WHERE reporter_id = $1::uuid AND created_at >= $2;`,
		reporterID, t).Scan(&n)
	return n, err
}

// List returns reports, newest first. beforeID, if not zero, continues after
// a page that ended at that report.
func (r *ReportRepository) List(ctx context.Context, limit int, beforeID int64) ([]Report, error) {
	rows, err := config.DB.Query(ctx, `
		SELECT r.id, r.reporter_id::text, COALESCE(a.username, ''), r.reported_user_id::text,
		       COALESCE(b.username, ''), r.reason, r.note, r.messages, r.created_at
		FROM reports r
		LEFT JOIN users a ON a.id = r.reporter_id
		LEFT JOIN users b ON b.id = r.reported_user_id
		WHERE ($2::bigint = 0 OR r.id < $2)
		ORDER BY r.id DESC
		LIMIT $1;
	`, limit, beforeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []Report{}
	for rows.Next() {
		var rep Report
		var raw []byte
		if err := rows.Scan(&rep.ID, &rep.ReporterID, &rep.ReporterName, &rep.ReportedUserID,
			&rep.ReportedUsername, &rep.Reason, &rep.Note, &raw, &rep.CreatedAt); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(raw, &rep.Messages); err != nil || rep.Messages == nil {
			rep.Messages = []ReportedMessage{}
		}
		out = append(out, rep)
	}
	return out, rows.Err()
}
