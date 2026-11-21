package services

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

type AuthService struct {
	repo *repository.UserRepository
}

func NewAuthService() *AuthService {
	return &AuthService{repo: repository.NewUserRepository()}
}

// MaxDeviceNameLength is the longest device name kept; longer ones are cut.
const MaxDeviceNameLength = 60

// CleanDeviceName trims a device name sent by an app and cuts it to length. It
// is only shown back to the same person, but still comes from the client.
func CleanDeviceName(name string) string {
	name = strings.Join(strings.Fields(name), " ")
	if r := []rune(name); len(r) > MaxDeviceNameLength {
		name = string(r[:MaxDeviceNameLength])
	}
	return name
}

// StartSession issues tokens for a new signed-in device and records it.
func (s *AuthService) StartSession(ctx context.Context, userID, deviceName string) (*TokenPair, error) {
	pairs, err := GenerateTokenPair(userID)
	if err != nil {
		return nil, errors.New("failed to issue tokens")
	}
	expiry := time.Now().Add(7 * 24 * time.Hour)
	if err := repository.NewRefreshTokenRepository().StoreSessionToken(
		ctx, userID, pairs.SessionID, CleanDeviceName(deviceName), HashToken(pairs.RefreshToken), expiry,
	); err != nil {
		return nil, errors.New("failed to securely record login token metrics")
	}
	return pairs, nil
}

func (s *AuthService) Login(ctx context.Context, username, password, deviceName string) (*models.User, *TokenPair, error) {
	username = strings.ToLower(strings.TrimSpace(username))

	user, err := s.repo.FindByUsername(ctx, username)
	if err != nil {
		return nil, nil, errors.New("invalid username or password credentials")
	}

	match, err := VerifyPassword(password, user.PasswordHash)
	if errors.Is(err, ErrServerBusy) {
		return nil, nil, err
	}
	if err != nil || !match {
		return nil, nil, errors.New("invalid username or password credentials")
	}

	pairs, err := s.StartSession(ctx, user.ID, deviceName)
	if err != nil {
		return nil, nil, err
	}
	return user, pairs, nil
}

func (s *AuthService) Refresh(ctx context.Context, oldRefreshToken, deviceName string) (*TokenPair, error) {
	uid, err := VerifyAccessToken(oldRefreshToken)
	if err != nil {
		return nil, errors.New("invalid or altered refresh token payload")
	}

	tokenRepo := repository.NewRefreshTokenRepository()
	oldHash := HashToken(oldRefreshToken)

	dbUID, sessionID, err := tokenRepo.GetValidToken(ctx, oldHash)
	if err != nil || dbUID != uid {
		return nil, errors.New("refresh token expired or revoked")
	}

	// The database knows the session, even for a token issued before
	// sessions existed.
	newPairs, err := GenerateSessionTokens(uid, sessionID)
	if err != nil {
		return nil, errors.New("failed to regenerate token chain")
	}

	newHash := HashToken(newPairs.RefreshToken)
	newExpiry := time.Now().Add(7 * 24 * time.Hour)
	ok, err := tokenRepo.Rotate(ctx, oldHash, newHash, newExpiry, CleanDeviceName(deviceName))
	if err != nil {
		return nil, errors.New("failed to process rotated token registration")
	}
	if !ok {
		// Signed out, or used a second time, between the check and now.
		return nil, errors.New("refresh token expired or revoked")
	}

	return newPairs, nil
}
