package controllers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"time"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// ConversationDeleted is the response to deleting or clearing a conversation.
// The app removes its local copies of messages up to ClearedAt.
type ConversationDeleted struct {
	ClearedAt time.Time `json:"cleared_at"`
	// Deleted is how many of your messages were removed for both people
	// (only for "delete for everyone").
	Deleted int64 `json:"deleted"`
}

func writeJSON(w http.ResponseWriter, status int, resp models.JSONResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(resp)
}

// HandleDeleteDirectConversation handles
// DELETE /api/messages/conversations/{userId}?for=me|everyone.
//
//   - for=me (the default) hides the conversation's current messages from the
//     caller only. It reappears when a new message arrives.
//   - for=everyone also deletes every message the caller sent in it, for both
//     people, and tells the other person's app. Their own messages are kept.
func HandleDeleteDirectConversation(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	peerID := chi.URLParam(r, "userId")
	scope := r.URL.Query().Get("for")

	if !uuidPattern.MatchString(peerID) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid user ID"})
		return
	}
	if peerID == uid {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "You can't have a conversation with yourself"})
		return
	}

	repo := repository.NewMessageRepository()
	var result ConversationDeleted
	var err error
	switch scope {
	case "", "me":
		result.ClearedAt, err = repo.ClearDirect(r.Context(), uid, peerID)
	case "everyone":
		result.Deleted, result.ClearedAt, err = repo.DeleteOwnDirectMessages(r.Context(), uid, peerID)
	default:
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "'for' must be 'me' or 'everyone'"})
		return
	}

	if errors.Is(err, repository.ErrUnknownPeer) {
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "User not found"})
		return
	}
	if err != nil {
		log.Printf("Couldn't delete a conversation: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't delete the conversation"})
		return
	}

	if scope == "everyone" {
		services.Hub.PublishMessagesDeleted(uid, peerID, result.ClearedAt)
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: result})
}

// HandleClearGroupHistory handles DELETE /api/groups/{id}/history: "delete for
// me" in a group. The caller stays a member; only their view is cleared.
func HandleClearGroupHistory(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	groupID := chi.URLParam(r, "id")

	clearedAt, err := repository.NewGroupRepository().ClearGroup(r.Context(), uid, groupID)
	if err != nil {
		log.Printf("Couldn't clear a group's history: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't clear the group's history"})
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: ConversationDeleted{ClearedAt: clearedAt}})
}

// HandleDeleteGroup handles DELETE /api/groups/{id} (admins only): deletes
// the group, its members and its messages, and tells the members' apps.
func HandleDeleteGroup(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	groupID := chi.URLParam(r, "id")
	repo := repository.NewGroupRepository()

	// Read the members first: they're gone once the group is.
	members, err := repo.GetGroupMembers(r.Context(), groupID)
	if err != nil {
		log.Printf("Couldn't list members of a group being deleted: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't delete the group"})
		return
	}
	if err := repo.Delete(r.Context(), groupID); err != nil {
		log.Printf("Couldn't delete a group: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't delete the group"})
		return
	}

	services.Hub.PublishGroupDeleted(groupID, uid, members)
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: "Group deleted"})
}

// HandleDeleteMessage handles DELETE /api/messages/{id}?for=me|everyone.
//
//   - for=me (the default) hides the message from the caller only.
//   - for=everyone deletes a message the caller sent, for everyone in the
//     chat, at any time. The message stays as "This message was deleted", and
//     the other people's apps are told.
func HandleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	messageID := chi.URLParam(r, "id")
	scope := r.URL.Query().Get("for")

	if !uuidPattern.MatchString(messageID) {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Invalid message ID"})
		return
	}
	if scope != "" && scope != "me" && scope != "everyone" {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "'for' must be 'me' or 'everyone'"})
		return
	}

	repo := repository.NewMessageRepository()
	if scope == "everyone" {
		msg, err := repo.DeleteForEveryone(r.Context(), uid, messageID)
		switch {
		case errors.Is(err, repository.ErrMessageNotFound):
			writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "Message not found"})
		case errors.Is(err, repository.ErrNotYourMessage):
			writeJSON(w, http.StatusForbidden, models.JSONResponse{Success: false, Error: "You can only delete your own messages for everyone"})
		case err != nil:
			log.Printf("Couldn't delete a message for everyone: %v", err)
			writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't delete the message"})
		default:
			services.Hub.PublishMessageDeleted(r.Context(), msg)
			writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]interface{}{
				"id":         msg.ID,
				"deleted_at": msg.DeletedAt,
			}})
		}
		return
	}

	err := repo.HideForMe(r.Context(), uid, messageID)
	switch {
	case errors.Is(err, repository.ErrMessageNotFound):
		writeJSON(w, http.StatusNotFound, models.JSONResponse{Success: false, Error: "Message not found"})
	case err != nil:
		log.Printf("Couldn't hide a message: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Couldn't delete the message"})
	default:
		writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]string{"id": messageID}})
	}
}
