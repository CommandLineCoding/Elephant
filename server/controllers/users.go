package controllers

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

func HandleUserSearch(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	q := r.URL.Query().Get("q")
	pageStr := r.URL.Query().Get("page")
	limitStr := r.URL.Query().Get("limit")

	page, _ := strconv.Atoi(pageStr)
	limit, _ := strconv.Atoi(limitStr)

	svc := services.NewUserService()
	users, err := svc.Search(r.Context(), q, page, limit)
	if errors.Is(err, services.ErrSearchQueryTooShort) {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{
			Success: false,
			Error:   fmt.Sprintf("Search needs at least %d characters", services.MinSearchQueryLength),
		})
		return
	}
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{
			Success: false,
			Error:   "Failed to execute user directory search operations",
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{
		Success: true,
		Data:    users,
	})
}

func HandleGetMe(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	repo := repository.NewUserRepository()
	user, err := repo.FindByID(r.Context(), uid)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "User profile not found"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: user})
}

func HandleDeleteMe(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	repo := repository.NewUserRepository()
	if err := repo.DeleteUser(r.Context(), uid); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "User profile not found"})
			return
		}
		log.Printf("delete account %s: %v", uid, err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to delete account"})
		return
	}

	services.Hub.Disconnect(uid)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true})
}

func HandleGetUserByID(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	id := chi.URLParam(r, "id")
	repo := repository.NewUserRepository()
	user, err := repo.FindByID(r.Context(), id)

	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Requested profile does not exist"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: user})
}

// UpdateMeReq is the body of PATCH /api/users/me.
type UpdateMeReq struct {
	DisplayName *string `json:"display_name"`
}

// HandleUpdateMe handles PATCH /api/users/me: change your display name.
func HandleUpdateMe(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	var req UpdateMeReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DisplayName == nil {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Expected a display_name"})
		return
	}

	user, err := services.NewUserService().UpdateDisplayName(r.Context(), uid, *req.DisplayName)
	switch {
	case errors.Is(err, services.ErrInvalidDisplayName):
		msg := strings.TrimPrefix(err.Error(), services.ErrInvalidDisplayName.Error()+": ")
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: msg})
	case errors.Is(err, pgx.ErrNoRows):
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User profile not found"})
	case err != nil:
		log.Printf("Couldn't update a display name: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't update your profile"})
	default:
		writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: user})
	}
}
