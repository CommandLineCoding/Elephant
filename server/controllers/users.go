package controllers

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

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

	// Only the person themselves is told when they last changed it.
	if at, err := repo.UsernameChangedAt(r.Context(), uid); err == nil {
		user.UsernameChangedAt = at
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

// UpdateMeReq is the body of PATCH /api/users/me. Send what to change.
type UpdateMeReq struct {
	DisplayName *string `json:"display_name"`

	// Username is the part before the dot, as when signing up; the server
	// picks a new four digit number. Once every 30 days.
	Username *string `json:"username"`
}

// HandleUpdateMe handles PATCH /api/users/me: change your display name,
// your username, or both.
func HandleUpdateMe(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	var req UpdateMeReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || (req.DisplayName == nil && req.Username == nil) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Expected a display_name or a username"})
		return
	}

	svc := services.NewUserService()
	var user *models.User
	var err error

	// The username goes first: it can be refused, and then nothing changes.
	if req.Username != nil {
		user, err = svc.ChangeUsername(r.Context(), uid, *req.Username)
		var recent repository.ErrUsernameChangedRecently
		switch {
		case errors.As(err, &recent):
			w.Header().Set("Retry-After", strconv.Itoa(int(time.Until(recent.Next).Seconds())+1))
			writeJSON(w, http.StatusTooManyRequests, models.JSONResponse{
				Success: false,
				Error:   "You can change your username once every 30 days. Try again after " + recent.Next.UTC().Format("2 January 2006") + ".",
			})
			return
		case errors.Is(err, services.ErrSameUsername), isUsernameRuleError(err):
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: err.Error()})
			return
		case errors.Is(err, repository.ErrUsernameTaken):
			writeJSON(w, http.StatusConflict, models.JSONResponse{Success: false, Error: err.Error()})
			return
		case errors.Is(err, pgx.ErrNoRows):
			writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User profile not found"})
			return
		case err != nil:
			log.Printf("Couldn't change a username: %v", err)
			writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't update your profile"})
			return
		}
	}

	if req.DisplayName != nil {
		user, err = svc.UpdateDisplayName(r.Context(), uid, *req.DisplayName)
		switch {
		case errors.Is(err, services.ErrInvalidDisplayName):
			msg := strings.TrimPrefix(err.Error(), services.ErrInvalidDisplayName.Error()+": ")
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: msg})
			return
		case errors.Is(err, pgx.ErrNoRows):
			writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User profile not found"})
			return
		case err != nil:
			log.Printf("Couldn't update a display name: %v", err)
			writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't update your profile"})
			return
		}
		if at, aerr := repository.NewUserRepository().UsernameChangedAt(r.Context(), uid); aerr == nil {
			user.UsernameChangedAt = at
		}
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: user})
}

// isUsernameRuleError reports whether err is a complaint about the username's
// length or characters.
func isUsernameRuleError(err error) bool {
	return err != nil && strings.HasPrefix(err.Error(), "username prefix must")
}
