package controllers

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

func settingsUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	w.Header().Set("Content-Type", "application/json")
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	if uid == "" {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unauthorized context"})
		return "", false
	}
	return uid, true
}

// HandleGetSettings returns the signed-in user's privacy settings.
func HandleGetSettings(w http.ResponseWriter, r *http.Request) {
	uid, ok := settingsUser(w, r)
	if !ok {
		return
	}
	s, err := repository.NewUserSettingsRepository().Get(r.Context(), uid)
	if err != nil {
		log.Printf("settings: could not load: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to load your settings"})
		return
	}
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: s})
}

// HandleUpdateSettings changes some of the signed-in user's privacy settings
// and returns all of them. Fields that aren't sent stay as they are.
func HandleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	uid, ok := settingsUser(w, r)
	if !ok {
		return
	}

	var patch repository.UserSettingsPatch
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&patch); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
		return
	}
	for name, v := range map[string]*string{"online_status": patch.OnlineStatus, "group_adds": patch.GroupAdds} {
		if v != nil && !repository.ValidAudience(*v) {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(models.JSONResponse{
				Success: false,
				Error:   name + " must be \"everyone\", \"contacts\" or \"nobody\"",
			})
			return
		}
	}

	s, err := repository.NewUserSettingsRepository().Update(r.Context(), uid, patch)
	if err != nil {
		log.Printf("settings: could not save: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to save your settings"})
		return
	}
	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: s})
}
