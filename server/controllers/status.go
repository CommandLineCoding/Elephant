package controllers

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

const (
	// A status is posted with one copy per person, so there can be many.
	maxStatusCopies = 200
	// One encrypted copy: 700 characters of text and its styling, with the
	// encryption's overhead, fits comfortably.
	maxStatusCopyBytes = 8 << 10
	// What one person can post in a day.
	maxStatusesPerDay = 20
	// Statuses listed at once.
	maxStatusesListed = 500
)

type statusReq struct {
	Copies []repository.StatusCopy `json:"copies"`
}

// HandlePostStatus handles POST /api/status: a status, already encrypted for
// each person who should see it. Only the author's contacts get one; the rest
// are reported back as skipped.
func HandlePostStatus(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	var req statusReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
		return
	}
	if len(req.Copies) == 0 || len(req.Copies) > maxStatusCopies {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Send a copy for 1 to 200 people"})
		return
	}

	contacts, err := repository.NewContactRepository().GetContactIDs(r.Context(), uid)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to post the status"})
		return
	}
	mine := make(map[string]struct{}, len(contacts))
	for _, id := range contacts {
		mine[strings.ToLower(id)] = struct{}{}
	}

	var copies []repository.StatusCopy
	skipped := []string{}
	seen := map[string]struct{}{}
	for _, c := range req.Copies {
		id := strings.ToLower(c.RecipientID)
		if !uuidPattern.MatchString(id) {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid recipient ID"})
			return
		}
		if c.Content == "" || len(c.Content) > maxStatusCopyBytes {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "A copy is empty or too long"})
			return
		}
		if _, dup := seen[id]; dup {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "A person appears twice"})
			return
		}
		seen[id] = struct{}{}
		if _, ok := mine[id]; !ok || id == strings.ToLower(uid) {
			skipped = append(skipped, id)
			continue
		}
		copies = append(copies, repository.StatusCopy{RecipientID: id, Content: c.Content})
	}
	if len(copies) == 0 {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "None of those people can receive your status"})
		return
	}

	repo := repository.NewStatusRepository()
	today, err := repo.CountSince(r.Context(), uid, time.Now().Add(-24*time.Hour))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to post the status"})
		return
	}
	if today >= maxStatusesPerDay {
		writeJSON(w, http.StatusTooManyRequests, models.JSONResponse{Success: false, Error: "You can post 20 statuses a day"})
		return
	}

	posted, err := repo.Create(r.Context(), uid, copies)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to post the status"})
		return
	}
	recipients := make([]string, len(copies))
	for i, c := range copies {
		recipients[i] = c.RecipientID
	}
	services.Hub.PublishStatusPosted(uid, posted, recipients)

	writeJSON(w, http.StatusCreated, models.JSONResponse{Success: true, Data: map[string]interface{}{
		"id":         posted.ID,
		"created_at": posted.CreatedAt,
		"expires_at": posted.ExpiresAt,
		"recipients": len(copies),
		"skipped":    skipped,
	}})
}

// HandleListStatuses handles GET /api/status: the statuses posted for you.
func HandleListStatuses(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	list, err := repository.NewStatusRepository().ListFor(r.Context(), uid, maxStatusesListed)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to load statuses"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: list})
}

// HandleListOwnStatuses handles GET /api/status/mine: your statuses, and who
// has seen them.
func HandleListOwnStatuses(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	list, err := repository.NewStatusRepository().ListOwn(r.Context(), uid)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to load your statuses"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: list})
}

// HandleDeleteStatus handles DELETE /api/status/{id}: removes your status for
// everyone before it runs out.
func HandleDeleteStatus(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	id := chi.URLParam(r, "id")
	if !uuidPattern.MatchString(id) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid status ID"})
		return
	}
	deleted, err := repository.NewStatusRepository().Delete(r.Context(), uid, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to delete the status"})
		return
	}
	if !deleted {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "Status not found"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]string{"id": id}})
}

// HandleViewStatus handles POST /api/status/{id}/view: you saw a status. Its
// author is told, if you allow read receipts.
func HandleViewStatus(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	id := chi.URLParam(r, "id")
	if !uuidPattern.MatchString(id) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid status ID"})
		return
	}
	author, first, found, err := repository.NewStatusRepository().MarkViewed(r.Context(), uid, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to record the view"})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "Status not found"})
		return
	}
	if first {
		services.Hub.PublishStatusViewed(r.Context(), id, author, uid, time.Now())
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]string{"id": id}})
}
