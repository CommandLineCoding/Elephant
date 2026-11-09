package services

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

type UserService struct {
	repo *repository.UserRepository
}

func NewUserService() *UserService {
	return &UserService{repo: repository.NewUserRepository()}
}

func (s *UserService) Register(ctx context.Context, requestedName, dn, passwd string) (*models.User, error) {
	if RegistrationClosed() {
		return nil, ErrRegistrationClosed
	}

	requestedName = strings.ToLower(strings.TrimSpace(requestedName))
	dn = strings.TrimSpace(dn)

	if len(requestedName) < 3 || len(requestedName) > 25 {
		return nil, errors.New("username prefix must be between 3 and 25 characters")
	}

	isAlphanumeric := regexp.MustCompile(`^[a-z0-9]+$`).MatchString
	if !isAlphanumeric(requestedName) {
		return nil, errors.New("username prefix must contain only alphanumeric characters")
	}

	if len(passwd) < 8 {
		return nil, errors.New("password must be at least 8 characters long")
	}
	if dn == "" {
		return nil, errors.New("display name cannot be empty")
	}

	// Generate format: {userdefinedunique}.{4digitrandomnumber}
	var finalUsername string
	maxRetries := 5
	resolved := false

	for i := 0; i < maxRetries; i++ {
		nBig, err := rand.Int(rand.Reader, big.NewInt(9000))
		if err != nil {
			return nil, errors.New("failed to generate secure user discriminator")
		}
		discriminator := nBig.Int64() + 1000 // forces range [1000, 9999]

		candidate := fmt.Sprintf("%s.%d", requestedName, discriminator)

		exists, err := s.repo.UsernameExists(ctx, candidate)
		if err != nil {
			return nil, err
		}
		if !exists {
			finalUsername = candidate
			resolved = true
			break
		}
	}

	if !resolved {
		return nil, errors.New("username namespace collision; please try again")
	}

	hash, err := HashPassword(passwd)
	if err != nil {
		return nil, err
	}

	return s.repo.CreateUser(ctx, finalUsername, dn, hash)
}

// ErrRegistrationClosed is returned when the server doesn't accept new accounts.
var ErrRegistrationClosed = errors.New("registration is closed on this server")

// RegistrationClosed reports whether REGISTRATION=closed. Existing users can
// still sign in; only creating new accounts is refused.
func RegistrationClosed() bool {
	return strings.EqualFold(strings.TrimSpace(env.REGISTRATION), "closed")
}

// MinSearchQueryLength is the shortest user search the server accepts, in
// characters. The app enforces the same limit before it sends a request.
const MinSearchQueryLength = 2

// ErrSearchQueryTooShort is returned by Search for queries under MinSearchQueryLength.
var ErrSearchQueryTooShort = errors.New("search query too short")

func (s *UserService) Search(ctx context.Context, query string, page, limit int) ([]models.User, error) {
	query = strings.TrimSpace(query)
	if utf8.RuneCountInString(query) < MinSearchQueryLength {
		return nil, ErrSearchQueryTooShort
	}

	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	offset := (page - 1) * limit

	return s.repo.SearchUsers(ctx, query, limit, offset)
}
