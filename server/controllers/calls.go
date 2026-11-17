package controllers

import (
	"net/http"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
)

// HandleICEServers handles GET /api/calls/ice-servers: the STUN and TURN
// servers for a call, with TURN credentials that expire after ttl seconds.
// The app asks for them each time a call starts.
func HandleICEServers(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]interface{}{
		"ice_servers": services.ICEServers(r.Context(), uid),
		"ttl":         int(services.ICECredentialTTL.Seconds()),
	}})
}

// HandlePendingCall handles GET /api/calls/pending: the call ringing for you,
// if any. The app asks when a push wakes it, to show who is calling before it
// has connected. With no call ringing, data is absent.
func HandlePendingCall(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	callID, callerID, ok := services.PendingCall(uid)
	if !ok {
		writeJSON(w, http.StatusOK, models.JSONResponse{Success: true})
		return
	}
	name := ""
	if caller, err := repository.NewUserRepository().FindByID(r.Context(), callerID); err == nil && caller != nil {
		name = caller.DisplayName
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]string{
		"call_id":             callID,
		"caller_id":           callerID,
		"caller_display_name": name,
	}})
}
