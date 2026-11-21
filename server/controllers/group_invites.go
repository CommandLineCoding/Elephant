package controllers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

// inviteCodePattern is what an invite code looks like: 32 base64url characters.
var inviteCodePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{32}$`)

// inviteView is a group's invite as admins see it.
type inviteView struct {
	Enabled         bool   `json:"enabled"`
	Code            string `json:"code,omitempty"`
	RequireApproval bool   `json:"require_approval"`
}

func viewOf(inv *repository.Invite) inviteView {
	if inv == nil {
		return inviteView{}
	}
	return inviteView{Enabled: true, Code: inv.Code, RequireApproval: inv.RequireApproval}
}

// HandleGetInvite handles GET /api/groups/{id}/invite (admins).
func HandleGetInvite(w http.ResponseWriter, r *http.Request) {
	inv, err := repository.NewGroupInviteRepository().Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		log.Printf("invites: could not load: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't load the invite link"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: viewOf(inv)})
}

type setInviteReq struct {
	RequireApproval *bool `json:"require_approval"`

	// Reset makes a new code; the old one stops working at once.
	Reset bool `json:"reset"`
}

// HandleSetInvite handles PUT /api/groups/{id}/invite (admins): create the
// link, reset it, or change whether joining needs an admin.
func HandleSetInvite(w http.ResponseWriter, r *http.Request) {
	var req setInviteReq
	if r.ContentLength != 0 {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
			return
		}
	}
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	inv, err := repository.NewGroupInviteRepository().Set(r.Context(), chi.URLParam(r, "id"), uid, req.RequireApproval, req.Reset)
	if err != nil {
		log.Printf("invites: could not save: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't save the invite link"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: viewOf(inv)})
}

// HandleDeleteInvite handles DELETE /api/groups/{id}/invite (admins): turn the
// link off. Anyone waiting for approval is dropped.
func HandleDeleteInvite(w http.ResponseWriter, r *http.Request) {
	groupID := chi.URLParam(r, "id")
	if err := repository.NewGroupInviteRepository().Delete(r.Context(), groupID); err != nil {
		log.Printf("invites: could not delete: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't turn the invite link off"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true})
}

// HandlePreviewInvite handles GET /api/invites/{code}: the group's name and
// how many people are in it, for the screen that asks "Join?". It names no one.
func HandlePreviewInvite(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	code := chi.URLParam(r, "code")
	if !inviteCodePattern.MatchString(code) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "This invite link doesn't work any more"})
		return
	}
	p, err := repository.NewGroupInviteRepository().Preview(r.Context(), code, uid)
	if errors.Is(err, repository.ErrNoInvite) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "This invite link doesn't work any more"})
		return
	}
	if err != nil {
		log.Printf("invites: could not preview: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't open the invite link"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: p})
}

// HandleJoinInvite handles POST /api/invites/{code}/join: becomes a member, or,
// if the group wants approval, asks to.
func HandleJoinInvite(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	code := chi.URLParam(r, "code")
	if !inviteCodePattern.MatchString(code) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "This invite link doesn't work any more"})
		return
	}
	status, groupID, err := repository.NewGroupInviteRepository().Join(r.Context(), code, uid)
	if errors.Is(err, repository.ErrNoInvite) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "This invite link doesn't work any more"})
		return
	}
	if err != nil {
		log.Printf("invites: could not join: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't join the group"})
		return
	}
	if status != "already_member" {
		// Members load the new member list; for a request, the admins see it.
		go services.Hub.GroupUpdated(groupID)
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]string{"status": status, "group_id": groupID}})
}

// HandleListJoinRequests handles GET /api/groups/{id}/requests (admins).
func HandleListJoinRequests(w http.ResponseWriter, r *http.Request) {
	list, err := repository.NewGroupInviteRepository().Requests(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		log.Printf("invites: could not list requests: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't load join requests"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: list})
}

func decideRequest(w http.ResponseWriter, r *http.Request, approve bool) {
	groupID, userID := chi.URLParam(r, "id"), chi.URLParam(r, "userId")
	if !uuidPattern.MatchString(userID) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid user ID"})
		return
	}
	found, err := repository.NewGroupInviteRepository().Decide(r.Context(), groupID, userID, approve)
	if err != nil {
		log.Printf("invites: could not decide: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't answer the request"})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "No such request"})
		return
	}
	go services.Hub.GroupUpdated(groupID)
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true})
}

// HandleApproveJoinRequest handles POST /api/groups/{id}/requests/{userId}.
func HandleApproveJoinRequest(w http.ResponseWriter, r *http.Request) { decideRequest(w, r, true) }

// HandleDenyJoinRequest handles DELETE /api/groups/{id}/requests/{userId}.
func HandleDenyJoinRequest(w http.ResponseWriter, r *http.Request) { decideRequest(w, r, false) }
