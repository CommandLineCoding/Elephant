package controllers

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
)

// twoFactorFailure answers an error from a two-step step: a wrong code is 401,
// too many are 429 with when to try again, and a sign-in step that ran out
// is 401 too.
func twoFactorFailure(w http.ResponseWriter, err error) {
	var locked *services.TwoFactorLockedError
	switch {
	case errors.As(err, &locked):
		w.Header().Set("Retry-After", strconv.Itoa(int(time.Until(locked.Until).Seconds())+1))
		writeJSON(w, http.StatusTooManyRequests, models.JSONResponse{Success: false, Error: locked.Error()})
	case errors.Is(err, services.ErrTwoFactorInvalid), errors.Is(err, services.ErrChallengeInvalid):
		writeJSON(w, http.StatusUnauthorized, models.JSONResponse{Success: false, Error: err.Error()})
	case errors.Is(err, services.ErrTwoFactorNotAvailable), errors.Is(err, services.ErrTwoFactorNotStarted):
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: err.Error()})
	case errors.Is(err, services.ErrTwoFactorAlreadyOn):
		writeJSON(w, http.StatusConflict, models.JSONResponse{Success: false, Error: err.Error()})
	case errors.Is(err, services.ErrServerBusy):
		respondIfBusy(w, err)
	default:
		log.Printf("two-step sign-in: %v", err)
		writeJSON(w, http.StatusInternalServerError, models.JSONResponse{Success: false, Error: "Something went wrong with two-step sign-in"})
	}
}

type twoFactorLoginReq struct {
	Challenge  string `json:"challenge"`
	Code       string `json:"code"`
	DeviceName string `json:"device_name"`
}

// HandleLoginTwoFactor handles POST /api/auth/login/2fa: the code that follows
// a right password for an account with two-step sign-in.
func HandleLoginTwoFactor(w http.ResponseWriter, r *http.Request) {
	var req twoFactorLoginReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil || req.Challenge == "" || req.Code == "" {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Expected a challenge and a code"})
		return
	}
	user, tokens, err := services.NewAuthService().CompleteTwoFactor(r.Context(), req.Challenge, req.Code, req.DeviceName)
	if err != nil {
		twoFactorFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]interface{}{
		"user":   user,
		"tokens": tokens,
	}})
}

func twoFactorUser(r *http.Request) string {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	return uid
}

// HandleTwoFactorStatus handles GET /api/users/me/2fa.
func HandleTwoFactorStatus(w http.ResponseWriter, r *http.Request) {
	enabled, left, err := services.NewAuthService().TwoFactorStatus(r.Context(), twoFactorUser(r))
	if err != nil {
		twoFactorFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]interface{}{
		"enabled":             enabled,
		"recovery_codes_left": left,
	}})
}

// HandleTwoFactorSetup handles POST /api/users/me/2fa/setup: a secret for the
// person's authenticator app. It isn't on until a code is confirmed.
func HandleTwoFactorSetup(w http.ResponseWriter, r *http.Request) {
	uid := twoFactorUser(r)
	username := ""
	if u, err := repository.NewUserRepository().FindByID(r.Context(), uid); err == nil {
		username = u.Username
	}
	secret, uri, err := services.NewAuthService().BeginTwoFactor(r.Context(), uid, username)
	if err != nil {
		twoFactorFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]string{
		"secret":      secret,
		"otpauth_uri": uri,
	}})
}

type codeReq struct {
	Code     string `json:"code"`
	Password string `json:"password"`
}

// HandleTwoFactorEnable handles POST /api/users/me/2fa/enable: confirms a code
// from the authenticator app, turns two-step sign-in on and returns the
// recovery codes, which are shown only this once.
func HandleTwoFactorEnable(w http.ResponseWriter, r *http.Request) {
	var req codeReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<10)).Decode(&req); err != nil || req.Code == "" {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Expected a code"})
		return
	}
	codes, err := services.NewAuthService().EnableTwoFactor(r.Context(), twoFactorUser(r), req.Code)
	if err != nil {
		twoFactorFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true, Data: map[string]interface{}{
		"recovery_codes": codes,
	}})
}

// HandleTwoFactorDisable handles POST /api/users/me/2fa/disable: turns it off,
// with the password and a code (or a recovery code).
func HandleTwoFactorDisable(w http.ResponseWriter, r *http.Request) {
	var req codeReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<10)).Decode(&req); err != nil || req.Code == "" || req.Password == "" {
		writeJSON(w, http.StatusBadRequest, models.JSONResponse{Success: false, Error: "Expected your password and a code"})
		return
	}
	if err := services.NewAuthService().DisableTwoFactor(r.Context(), twoFactorUser(r), req.Password, req.Code); err != nil {
		if err.Error() == "invalid password" {
			writeJSON(w, http.StatusUnauthorized, models.JSONResponse{Success: false, Error: "That password isn't right"})
			return
		}
		twoFactorFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, models.JSONResponse{Success: true})
}
