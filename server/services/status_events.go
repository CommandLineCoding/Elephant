package services

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/commandlinecoding/elephant/server/repository"
)

// PublishStatusPosted tells connected recipients that someone posted a status,
// so the app can fetch it. The event carries no content, and nobody is woken
// by a push ping for a status: the person sees it next time they open the app.
func (h *WSHub) PublishStatusPosted(authorID string, s repository.PostedStatus, recipients []string) {
	bytes, _ := json.Marshal(map[string]interface{}{
		"type":       "status_posted",
		"status_id":  s.ID,
		"author_id":  authorID,
		"created_at": s.CreatedAt,
		"expires_at": s.ExpiresAt,
	})
	h.sendToUsers(recipients, authorID, bytes)
}

// PublishStatusViewed tells a status's author that someone saw it, unless that
// person has turned read receipts off. If their setting can't be loaded,
// nothing is sent.
func (h *WSHub) PublishStatusViewed(ctx context.Context, statusID, authorID, viewerID string, at time.Time) {
	settings, err := h.settingsOf(ctx, viewerID)
	if err != nil {
		log.Printf("Status view not shared, couldn't load settings: %v", err)
		return
	}
	if !settings.ReadReceipts {
		return
	}
	bytes, _ := json.Marshal(map[string]interface{}{
		"type":      "status_viewed",
		"status_id": statusID,
		"viewer_id": viewerID,
		"viewed_at": at,
	})
	h.sendToUser(authorID, bytes)
}
