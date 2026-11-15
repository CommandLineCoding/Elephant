package controllers

import (
	"errors"
	"log"
	"net/http"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/go-chi/chi/v5"
)

// blockTarget reads and checks the {id} of a block or unblock request. It
// writes the error response and returns ok=false if the request is invalid.
func blockTarget(w http.ResponseWriter, r *http.Request) (uid, target string, ok bool) {
	uid, _ = r.Context().Value(middlewares.UserIDKey).(string)
	target = chi.URLParam(r, "id")
	if !uuidPattern.MatchString(target) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid user ID"})
		return "", "", false
	}
	if target == uid {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "You can't block yourself"})
		return "", "", false
	}
	return uid, target, true
}

// HandleBlockUser handles POST /api/users/{id}/block. The blocked person
// isn't told; their direct messages, typing and read receipts stop reaching
// the caller, and neither sees the other's online status.
func HandleBlockUser(w http.ResponseWriter, r *http.Request) {
	uid, target, ok := blockTarget(w, r)
	if !ok {
		return
	}
	err := repository.NewBlockRepository().Block(r.Context(), uid, target)
	if errors.Is(err, repository.ErrUnknownPeer) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User not found"})
		return
	}
	if err != nil {
		log.Printf("Couldn't block a user: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't block the user"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: "User blocked"})
}

// HandleUnblockUser handles DELETE /api/users/{id}/block.
func HandleUnblockUser(w http.ResponseWriter, r *http.Request) {
	uid, target, ok := blockTarget(w, r)
	if !ok {
		return
	}
	if err := repository.NewBlockRepository().Unblock(r.Context(), uid, target); err != nil {
		log.Printf("Couldn't unblock a user: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't unblock the user"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: "User unblocked"})
}

// HandleListBlocked handles GET /api/users/me/blocked.
func HandleListBlocked(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	list, err := repository.NewBlockRepository().ListBlocked(r.Context(), uid)
	if err != nil {
		log.Printf("Couldn't list blocked users: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't load blocked users"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: list})
}
