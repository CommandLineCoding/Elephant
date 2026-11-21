package controllers

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

type sessionView struct {
	repository.Session
	// Current is true for the device that is asking.
	Current bool `json:"current"`
}

func sessionContext(w http.ResponseWriter, r *http.Request) (uid, sid string, ok bool) {
	w.Header().Set("Content-Type", "application/json")
	uid, _ = r.Context().Value(middlewares.UserIDKey).(string)
	sid, _ = r.Context().Value(middlewares.SessionIDKey).(string)
	if uid == "" {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return "", "", false
	}
	return uid, sid, true
}

// HandleListSessions lists the devices the signed-in user is signed in on.
func HandleListSessions(w http.ResponseWriter, r *http.Request) {
	uid, sid, ok := sessionContext(w, r)
	if !ok {
		return
	}

	sessions, err := repository.NewRefreshTokenRepository().ListSessions(r.Context(), uid)
	if err != nil {
		log.Printf("sessions: could not list: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to load your devices"})
		return
	}

	out := make([]sessionView, 0, len(sessions))
	for _, s := range sessions {
		out = append(out, sessionView{Session: s, Current: s.ID == sid})
	}
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: out})
}

// HandleDeleteSession signs one of the user's devices out and closes its
// connection. Signing out the device you are on works too.
func HandleDeleteSession(w http.ResponseWriter, r *http.Request) {
	uid, _, ok := sessionContext(w, r)
	if !ok {
		return
	}

	id := chi.URLParam(r, "id")
	if !uuidPattern.MatchString(id) {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid device ID"})
		return
	}

	found, err := repository.NewRefreshTokenRepository().DeleteSession(r.Context(), uid, id)
	if err != nil {
		log.Printf("sessions: could not sign out: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to sign out that device"})
		return
	}
	if !found {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "No such device"})
		return
	}

	services.Hub.DisconnectSession(uid, id)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true})
}

// HandleDeleteOtherSessions signs out every device but the one asking.
func HandleDeleteOtherSessions(w http.ResponseWriter, r *http.Request) {
	uid, sid, ok := sessionContext(w, r)
	if !ok {
		return
	}
	if sid == "" {
		// A token from before sessions doesn't say which device is "this one",
		// and guessing would sign the person out of the one they are using.
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Sign in again to use this"})
		return
	}

	ended, err := repository.NewRefreshTokenRepository().DeleteOtherSessions(r.Context(), uid, sid)
	if err != nil {
		log.Printf("sessions: could not sign out the others: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to sign out your other devices"})
		return
	}
	for _, id := range ended {
		services.Hub.DisconnectSession(uid, id)
	}
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: map[string]int{"signed_out": len(ended)}})
}
