package controllers

import (
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/jackc/pgx/v5"
)

// HandleExportMe handles GET /api/users/me/export: everything the server
// keeps about the signed-in user, as one JSON document they can save.
func HandleExportMe(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	if uid == "" {
		writeJSON(w, http.StatusUnauthorized, models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	export, err := repository.NewExportRepository().Export(r.Context(), uid, time.Now())
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User profile not found"})
		return
	}
	if err != nil {
		log.Printf("export: could not gather %s: %v", uid, err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to export your data"})
		return
	}

	// It is personal data, so no cache along the way should keep a copy.
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: export})
}
