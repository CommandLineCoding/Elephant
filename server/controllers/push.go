package controllers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
)

type pushEndpointReq struct {
	Endpoint string `json:"endpoint"`
}

// HandlePushRegister stores a UnifiedPush endpoint for the signed-in user.
// Registering the same endpoint again just refreshes it.
func HandlePushRegister(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	var req pushEndpointReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
		return
	}

	if err := services.Push.ValidateEndpoint(req.Endpoint); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		msg := "Invalid push endpoint"
		if errors.Is(err, services.ErrInvalidPushEndpoint) {
			msg = err.Error()
		}
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: msg})
		return
	}

	if err := repository.NewPushRepository().Upsert(r.Context(), uid, req.Endpoint, services.MaxPushEndpointsPerUser); err != nil {
		log.Printf("push: could not store an endpoint: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to save push endpoint"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true})
}

// HandlePushUnregister removes one of the signed-in user's endpoints. It
// succeeds even if the endpoint wasn't stored, so clients can call it freely
// on sign-out.
func HandlePushUnregister(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	var req pushEndpointReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil || req.Endpoint == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
		return
	}

	if _, err := repository.NewPushRepository().Delete(r.Context(), uid, req.Endpoint); err != nil {
		log.Printf("push: could not remove an endpoint: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to remove push endpoint"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true})
}
