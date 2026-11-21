package controllers

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

type CreateGroupReq struct {
	Name string `json:"name"`
}

func HandleCreateGroup(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	var req CreateGroupReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid payload group name configuration"})
		return
	}

	repo := repository.NewGroupRepository()
	group, err := repo.Create(r.Context(), req.Name, uid)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to create group channel"})
		return
	}

	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: group})
}

func HandleListMyGroups(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	repo := repository.NewGroupRepository()
	groups, err := repo.ListByUser(r.Context(), uid)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to pull your joined channels list"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: groups})
}

type GroupMemberReq struct {
	UserID string `json:"user_id"`
}

func HandleAddMember(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")

	var req GroupMemberReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Missing user target value"})
		return
	}

	if reason := whoMayAdd(r.Context(), requesterID(r), req.UserID); reason != "" {
		status := http.StatusForbidden
		if reason == errAddCheckFailed {
			status = http.StatusInternalServerError
		}
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: reason})
		return
	}

	repo := repository.NewGroupRepository()
	if err := repo.AddMember(r.Context(), groupID, req.UserID); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to add member to channel"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: "User attached to channel context cleanly"})
}

func HandleRemoveMember(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")
	targetUserID := chi.URLParam(r, "userId")

	if targetUserID == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Missing path target user selection identifier"})
		return
	}

	repo := repository.NewGroupRepository()
	if err := repo.RemoveMember(r.Context(), groupID, targetUserID); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to drop target user from channel"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: "Member detached from group context cleanly"})
}

func HandleGetGroupMessages(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")
	beforeStr := r.URL.Query().Get("before")
	limitStr := r.URL.Query().Get("limit")

	limit, _ := strconv.Atoi(limitStr)
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	before := time.Now()
	if beforeStr != "" {
		if t, err := time.Parse(time.RFC3339, beforeStr); err == nil {
			before = t
		}
	}

	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	repo := repository.NewGroupRepository()
	history, err := repo.GetGroupMessages(r.Context(), groupID, uid, before, limit)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to pull channel message history stream"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: history})
}

func HandleListGroupMembers(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")

	repo := repository.NewGroupRepository()
	members, err := repo.GetMembersDetails(r.Context(), groupID)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to retrieve group members roster"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: members})
}

func HandleLeaveGroup(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	repo := repository.NewGroupRepository()

	if err := repo.RemoveMember(r.Context(), groupID, uid); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to leave the group"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: "You have left the group"})
}

func HandleGetGroupDetails(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")

	repo := repository.NewGroupRepository()
	group, err := repo.GetByID(r.Context(), groupID)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Group not found"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: group})
}

// UpdateGroupReq is the body of PATCH /api/groups/{id}. Send what to change.
type UpdateGroupReq struct {
	Name        *string `json:"name"`
	Description *string `json:"description"`
	AdminsOnly  *bool   `json:"admins_only"`
}

const (
	maxGroupName        = 100
	maxGroupDescription = 500
)

// HandleUpdateGroup handles PATCH /api/groups/{id} (admins): the group's name,
// description, and whether only admins may send messages.
func HandleUpdateGroup(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")

	var req UpdateGroupReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil ||
		(req.Name == nil && req.Description == nil && req.AdminsOnly == nil) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Expected a name, a description or admins_only"})
		return
	}
	if req.Name != nil {
		name := strings.TrimSpace(*req.Name)
		if name == "" || utf8.RuneCountInString(name) > maxGroupName {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "A group name has 1 to 100 characters"})
			return
		}
		req.Name = &name
	}
	if req.Description != nil {
		desc := strings.TrimSpace(*req.Description)
		if utf8.RuneCountInString(desc) > maxGroupDescription {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "A description can be at most 500 characters"})
			return
		}
		req.Description = &desc
	}

	group, err := repository.NewGroupRepository().Update(r.Context(), groupID, repository.GroupChanges{
		Name: req.Name, Description: req.Description, AdminsOnly: req.AdminsOnly,
	})
	if err != nil {
		log.Printf("groups: could not update: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Failed to update the group"})
		return
	}
	// The other members' apps load the new details.
	go services.Hub.GroupUpdated(groupID)
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: group})
}
