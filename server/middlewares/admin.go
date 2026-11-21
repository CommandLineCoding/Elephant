package middlewares

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/models"
)

// IsAdmin reports whether userID is listed in ADMIN_USER_IDS.
func IsAdmin(userID string) bool {
	if userID == "" {
		return false
	}
	for _, id := range strings.Split(env.ADMIN_USER_IDS, ",") {
		if strings.EqualFold(strings.TrimSpace(id), userID) {
			return true
		}
	}
	return false
}

// AdminGuard lets only the server's admins through. Put it after AuthGuard.
func AdminGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		uid, _ := r.Context().Value(UserIDKey).(string)
		if !IsAdmin(uid) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Admins only"})
			return
		}
		next.ServeHTTP(w, r)
	})
}
