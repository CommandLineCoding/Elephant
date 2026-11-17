package controllers

import (
	"net/http"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
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
