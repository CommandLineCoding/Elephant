package controllers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

type SendMessageReq struct {
	ReceiverID       string `json:"receiver_id"`
	Content          string `json:"content"`
	ReplyToMessageID string `json:"reply_to_message_id,omitempty"`
}

func HandleSendMessage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	senderID, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	var req SendMessageReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid json payload structure"})
		return
	}

	if req.ReceiverID == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Receiver identity token required"})
		return
	}

	svc := services.NewMessageService()
	msg, err := svc.SendMessage(r.Context(), senderID, req.ReceiverID, req.Content, req.ReplyToMessageID)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: err.Error()})
		return
	}

	// This path has no live delivery, so a recipient who isn't connected needs
	// a push ping to know to fetch.
	if !services.Hub.IsOnline(req.ReceiverID) {
		services.Push.NotifyUsers([]string{req.ReceiverID})
	}

	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: msg})
}

func HandleGetChatHistory(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	targetUser := r.URL.Query().Get("with")
	beforeStr := r.URL.Query().Get("before")
	limitStr := r.URL.Query().Get("limit")

	if targetUser == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Missing target 'with' user query constraint"})
		return
	}

	limit, _ := strconv.Atoi(limitStr)
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	before := time.Now().Add(time.Minute)
	if beforeStr != "" {
		if t, err := time.Parse(time.RFC3339, beforeStr); err == nil {
			before = t
		}
	}

	repo := repository.NewMessageRepository()
	history, err := repo.GetChatHistory(r.Context(), uid, targetUser, before, limit)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to pull chat logs"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: history})
}

func HandleGetConversations(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	repo := repository.NewMessageRepository()
	list, err := repo.GetConversations(r.Context(), uid)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to compile inbox conversations"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: list})
}

type ReadReceiptReq struct {
	SenderID string `json:"sender_id"`
}

func HandleMarkRead(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)

	var req ReadReceiptReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid payload layout"})
		return
	}

	if req.SenderID == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Sender identification missing"})
		return
	}

	repo := repository.NewMessageRepository()
	if err := repo.MarkAsRead(r.Context(), uid, req.SenderID); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to clear unread receipts"})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: "Target messages marked read successfully"})
}

type EditMessageReq struct {
	Content string `json:"content"`
}

func HandleEditMessage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	uid, ok := r.Context().Value(middlewares.UserIDKey).(string)
	if !ok {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return
	}

	msgID := chi.URLParam(r, "id")
	if msgID == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Message ID required"})
		return
	}

	var req EditMessageReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid json payload structure"})
		return
	}

	content := strings.TrimSpace(req.Content)
	if content == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Content cannot be empty"})
		return
	}

	repo := repository.NewMessageRepository()
	msg, err := repo.GetMessageByID(r.Context(), msgID)
	if err != nil {
		if strings.Contains(err.Error(), "db error") {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: err.Error()})
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Message not found"})
		return
	}

	if msg.SenderID != uid {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "You can only edit your own messages"})
		return
	}

	if time.Since(msg.CreatedAt) > 15*time.Minute {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Message can no longer be edited (15 minute window expired)"})
		return
	}

	updatedMsg, err := repo.UpdateMessage(r.Context(), msgID, content)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to update message"})
		return
	}

	services.Hub.PublishMessageEdit(r.Context(), updatedMsg)

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: updatedMsg})
}
