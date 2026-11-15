package controllers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
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

type UpdateGroupReq struct {
	Name string `json:"name"`
}

func HandleUpdateGroup(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	groupID := chi.URLParam(r, "id")

	var req UpdateGroupReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid group name"})
		return
	}

	repo := repository.NewGroupRepository()
	if err := repo.UpdateName(r.Context(), groupID, req.Name); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to update group name"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: "Group details updated successfully"})
}
