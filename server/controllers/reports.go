package controllers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

const (
	maxReportNote        = 500
	maxReportMessages    = 10
	maxReportMessageText = 1000
	// One person can send this many reports a day, so the admin's list can't
	// be flooded from one account.
	maxReportsPerDay = 20
)

type reportReq struct {
	UserID   string                       `json:"user_id"`
	Reason   string                       `json:"reason"`
	Note     string                       `json:"note"`
	Messages []repository.ReportedMessage `json:"messages"`
}

// HandleCreateReport handles POST /api/reports: a report of spam or abuse for
// the server's admin. Direct messages are end-to-end encrypted, so it can only
// include messages the reporter's phone chose to attach as plain text.
func HandleCreateReport(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	var req reportReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
		return
	}
	if !uuidPattern.MatchString(req.UserID) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid user ID"})
		return
	}
	if strings.EqualFold(req.UserID, uid) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "You can't report yourself"})
		return
	}
	if !repository.ValidReportReason(req.Reason) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: `reason must be "spam", "harassment" or "other"`})
		return
	}
	note := strings.TrimSpace(req.Note)
	if utf8.RuneCountInString(note) > maxReportNote {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "The note can be at most 500 characters"})
		return
	}
	if len(req.Messages) > maxReportMessages {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Attach at most 10 messages"})
		return
	}
	for i := range req.Messages {
		m := &req.Messages[i]
		m.Text = strings.TrimSpace(m.Text)
		if utf8.RuneCountInString(m.Text) > maxReportMessageText {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "An attached message is too long"})
			return
		}
	}

	repo := repository.NewReportRepository()
	recent, err := repo.CountSince(r.Context(), uid, time.Now().Add(-24*time.Hour))
	if err != nil {
		log.Printf("reports: could not count: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't send the report"})
		return
	}
	if recent >= maxReportsPerDay {
		writeJSON(w, http.StatusTooManyRequests, models.JSONResponse{Success: false, Error: "You have sent a lot of reports today. Try again tomorrow."})
		return
	}

	id, err := repo.Create(r.Context(), repository.NewReport{
		ReporterID:     uid,
		ReportedUserID: req.UserID,
		Reason:         req.Reason,
		Note:           note,
		Messages:       req.Messages,
	})
	if errors.Is(err, repository.ErrUnknownPeer) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User not found"})
		return
	}
	if err != nil {
		log.Printf("reports: could not store: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't send the report"})
		return
	}
	writeJSON(w, http.StatusCreated, models.JSONResponse{Success: true, Data: map[string]int64{"id": id}})
}

// HandleAdminListReports handles GET /api/admin/reports?limit=&before=. Admins
// only (see ADMIN_USER_IDS).
func HandleAdminListReports(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	var before int64
	if v, err := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64); err == nil && v > 0 {
		before = v
	}
	reports, err := repository.NewReportRepository().List(r.Context(), limit, before)
	if err != nil {
		log.Printf("reports: could not list: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't load reports"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: reports})
}
