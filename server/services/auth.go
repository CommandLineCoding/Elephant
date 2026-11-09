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

func (s *AuthService) Login(ctx context.Context, username, password string) (*models.User, *TokenPair, error) {
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

	pairs, err := GenerateTokenPair(user.ID)
	if err != nil {
		return nil, nil, errors.New("failed to issue tokens")
	}

	tokenRepo := repository.NewRefreshTokenRepository()
	oldHash := HashToken(pairs.RefreshToken)
	expiry := time.Now().Add(7 * 24 * time.Hour)

	if err := tokenRepo.StoreToken(ctx, user.ID, oldHash, expiry); err != nil {
		return nil, nil, errors.New("failed to securely record login token metrics")
	}

	return user, pairs, nil
}

func (s *AuthService) Refresh(ctx context.Context, oldRefreshToken string) (*TokenPair, error) {
	uid, err := VerifyAccessToken(oldRefreshToken)
	if err != nil {
		return nil, errors.New("invalid or altered refresh token payload")
	}

	tokenRepo := repository.NewRefreshTokenRepository()
	oldHash := HashToken(oldRefreshToken)

	dbUID, err := tokenRepo.GetValidTokenUser(ctx, oldHash)
	if err != nil || dbUID != uid {
		return nil, errors.New("refresh token expired or revoked")
	}
	_ = tokenRepo.DeleteToken(ctx, oldHash)

	newPairs, err := GenerateTokenPair(uid)
	if err != nil {
		return nil, errors.New("failed to regenerate token chain")
	}

	newHash := HashToken(newPairs.RefreshToken)
	newExpiry := time.Now().Add(7 * 24 * time.Hour)
	if err := tokenRepo.StoreToken(ctx, uid, newHash, newExpiry); err != nil {
		return nil, errors.New("failed to process rotated token registration")
	}

	return newPairs, nil
}