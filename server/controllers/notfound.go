package controllers

import (
	"encoding/json"
	"net/http"

	"github.com/commandlinecoding/elephant/server/models"
)

// HandleNotFound answers requests for unknown routes with the usual JSON
// envelope instead of chi's plain-text "404 page not found".
func HandleNotFound(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Route not found"})
}

// HandleMethodNotAllowed does the same for a known path with the wrong method.
func HandleMethodNotAllowed(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusMethodNotAllowed)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Method not allowed"})
}
