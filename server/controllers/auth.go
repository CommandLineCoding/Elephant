package controllers

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/go-chi/chi/v5"
)

type RegisterReq struct {
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
	Password    string `json:"password"`
}

func HandleRegister(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	var req RegisterReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid payload syntax"})
		return
	}

	svc := services.NewUserService()
	user, err := svc.Register(r.Context(), req.Username, req.DisplayName, req.Password)
	if errors.Is(err, services.ErrRegistrationClosed) {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Registration is closed on this server"})
		return
	}
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: err.Error()})
		return
	}

	tokens, err := services.GenerateTokenPair(user.ID)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Token generation failure"})
		return
	}

	tokenRepo := repository.NewRefreshTokenRepository()
	hashedRt := services.HashToken(tokens.RefreshToken)
	expiry := time.Now().Add(7 * 24 * time.Hour)

	if err := tokenRepo.StoreToken(r.Context(), user.ID, hashedRt, expiry); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Failed to securely record registration token metrics"})
		return
	}

	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(models.JSONResponse{
		Success: true,
		Data: map[string]interface{}{
			"user":   user,
			"tokens": tokens,
		},
	})
}

type LoginReq struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func HandleLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	var req LoginReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid json payload structure"})
		return
	}

	svc := services.NewAuthService()
	user, tokens, err := svc.Login(r.Context(), req.Username, req.Password)
	if err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: err.Error()})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{
		Success: true,
		Data: map[string]interface{}{
			"user":   user,
			"tokens": tokens,
		},
	})
}

type RefreshReq struct {
	RefreshToken string `json:"refresh_token"`
}

func HandleRefresh(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	var req RefreshReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Invalid json payload structure"})
		return
	}

	if req.RefreshToken == "" {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Refresh token parameter missing"})
		return
	}

	svc := services.NewAuthService()
	tokens, err := svc.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: err.Error()})
		return
	}

	_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: true, Data: tokens})
}

func HandleOAuthRedirect(w http.ResponseWriter, r *http.Request) {
	provider := chi.URLParam(r, "provider")
	state := services.GenerateStateToken()

	cookie := &http.Cookie{
		Name:     "oauth_state",
		Value:    state,
		Path:     "/",
		HttpOnly: true,
		Secure:   false,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   300,
	}
	http.SetCookie(w, cookie)

	var urlStr string
	switch provider {
	case "google":
		urlStr = config.GoogleConfig.AuthCodeURL(state)
	case "github":
		urlStr = config.GithubConfig.AuthCodeURL(state)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(models.JSONResponse{Success: false, Error: "Unsupported OAuth provider context"})
		return
	}

	http.Redirect(w, r, urlStr, http.StatusTemporaryRedirect)
}

func HandleOAuthCallback(w http.ResponseWriter, r *http.Request) {
	provider := chi.URLParam(r, "provider")
	code := r.URL.Query().Get("code")
	state := r.URL.Query().Get("state")

	cookie, err := r.Cookie("oauth_state")
	if err != nil || cookie.Value != state {
		renderHandoffError(w, "State token match validation failed.")
		return
	}

	profile, err := services.ProcessCallback(r.Context(), provider, code)
	if err != nil {
		renderHandoffError(w, fmt.Sprintf("OAuth processing error: %s", err.Error()))
		return
	}

	userRepo := repository.NewUserRepository()
	u, err := userRepo.FindByProviderID(r.Context(), provider, profile.ID)
	if err != nil {
		u, err = userRepo.FindByEmail(r.Context(), profile.Email)
		if err == nil {
			_ = userRepo.LinkProviderAccount(r.Context(), u.ID, provider, profile.ID)
		} else {
			if services.RegistrationClosed() {
				renderHandoffError(w, "Registration is closed on this server.")
				return
			}
			emailHandle := strings.Split(profile.Email, "@")[0]
			baseUsername := cleanAlphanumeric(emailHandle)

			var username string
			for {
				randomDigits := generateRandom4Digits()
				username = fmt.Sprintf("%s.%s", baseUsername, randomDigits)

				exists, err := userRepo.UsernameExists(r.Context(), username)
				if err == nil && !exists {
					break
				}
			}

			u, err = userRepo.CreateOAuthUser(r.Context(), username, profile.Email, profile.Name, provider, profile.ID)
			if err != nil {
				renderHandoffError(w, "Failed to allocate user account credentials.")
				return
			}
		}
	}

	tokens, err := services.GenerateTokenPair(u.ID)
	if err != nil {
		renderHandoffError(w, "Token generation failure.")
		return
	}

	tokenRepo := repository.NewRefreshTokenRepository()
	hashedRt := services.HashToken(tokens.RefreshToken)
	expiry := time.Now().Add(7 * 24 * time.Hour)
	_ = tokenRepo.StoreToken(r.Context(), u.ID, hashedRt, expiry)

	customSchemeURL := fmt.Sprintf(
		"elephant://oauth-callback?access_token=%s&refresh_token=%s",
		url.QueryEscape(tokens.AccessToken),
		url.QueryEscape(tokens.RefreshToken),
	)

	intentURL := fmt.Sprintf(
		"intent://oauth-callback?access_token=%s&refresh_token=%s#Intent;scheme=elephant;package=in.commandlinecoding.elephant;end;",
		url.QueryEscape(tokens.AccessToken),
		url.QueryEscape(tokens.RefreshToken),
	)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)

	htmlPage := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Elephant Authentication</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: #0d1117;
            color: #c9d1d9;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }
        .card {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 16px;
            padding: 32px 24px;
            max-width: 400px;
            width: 100%%;
            text-align: center;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.5);
        }
        .icon {
            font-size: 48px;
            margin-bottom: 16px;
        }
        h2 {
            margin: 0 0 8px 0;
            color: #58a6ff;
            font-size: 20px;
        }
        p {
            margin: 0 0 24px 0;
            font-size: 14px;
            color: #8b949e;
        }
        .btn {
            display: block;
            width: 100%%;
            background-color: #238636;
            color: #ffffff;
            text-decoration: none;
            font-weight: 600;
            font-size: 15px;
            padding: 12px 20px;
            border-radius: 8px;
            border: none;
            cursor: pointer;
            transition: background-color 0.2s;
        }
        .btn:hover { background-color: #2ea043; }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon">🐘</div>
        <h2>Sign In Successful</h2>
        <p>Redirecting back to the Elephant application...</p>
        <a id="launch-btn" href="%s" class="btn">Open Elephant App</a>
    </div>
    <script>
        const intentUri = "%s";
        const customScheme = "%s";

        function triggerRedirect() {
            window.location.href = intentUri;

            setTimeout(function() {
                window.location.href = customScheme;
            }, 400);
        }

        document.getElementById('launch-btn').addEventListener('click', function(e) {
            triggerRedirect();
        });

        window.onload = function() {
            triggerRedirect();
        };
    </script>
</body>
</html>`, customSchemeURL, intentURL, customSchemeURL)

	_, _ = w.Write([]byte(htmlPage))
}

func renderHandoffError(w http.ResponseWriter, message string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)

	htmlError := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Authentication Error</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background-color: #0d1117;
            color: #f85149;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }
        .card {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 16px;
            padding: 32px 24px;
            max-width: 400px;
            width: 100%%;
            text-align: center;
        }
        h2 { margin-top: 0; }
        p { color: #8b949e; font-size: 14px; }
    </style>
</head>
<body>
    <div class="card">
        <h2>Authentication Failed</h2>
        <p>%s</p>
    </div>
</body>
</html>`, message)

	_, _ = w.Write([]byte(htmlError))
}

func cleanAlphanumeric(s string) string {
	reg := regexp.MustCompile("[^a-zA-Z0-9]")
	processed := reg.ReplaceAllString(s, "")
	if processed == "" {
		return "user"
	}
	return processed
}

func generateRandom4Digits() string {
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		return "1729"
	}
	return fmt.Sprintf("%04d", n.Int64())
}
