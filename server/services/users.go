package services

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"
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

	requestedName, err := NormalizeUsernamePrefix(requestedName)
	if err != nil {
		return nil, err
	}
	dn = strings.TrimSpace(dn)

	if len(passwd) < 8 {
		return nil, errors.New("password must be at least 8 characters long")
	}
	if dn == "" {
		return nil, errors.New("display name cannot be empty")
	}

	// Generate format: {userdefinedunique}.{4digitrandomnumber}
	var finalUsername string
	resolved := false

	for i := 0; i < 5; i++ {
		candidate, err := randomUsername(requestedName)
		if err != nil {
			return nil, err
		}
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

// MaxDisplayNameLength is the most characters a display name may have (the
// users.display_name column is VARCHAR(100)).
const MaxDisplayNameLength = 100

// ErrInvalidDisplayName is wrapped by every display name validation failure.
var ErrInvalidDisplayName = errors.New("invalid display name")

// NormalizeDisplayName trims a display name and checks it has 1 to
// MaxDisplayNameLength characters.
func NormalizeDisplayName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("%w: display name cannot be empty", ErrInvalidDisplayName)
	}
	if utf8.RuneCountInString(name) > MaxDisplayNameLength {
		return "", fmt.Errorf("%w: display name must be at most %d characters", ErrInvalidDisplayName, MaxDisplayNameLength)
	}
	return name, nil
}

// UpdateDisplayName changes the user's display name. Other people see it the
// next time their app loads the user's profile.
func (s *UserService) UpdateDisplayName(ctx context.Context, userID, name string) (*models.User, error) {
	name, err := NormalizeDisplayName(name)
	if err != nil {
		return nil, err
	}
	return s.repo.UpdateDisplayName(ctx, userID, name)
}

var usernamePrefixPattern = regexp.MustCompile(`^[a-z0-9]+$`)

// NormalizeUsernamePrefix trims and lowercases the part of a username a person
// chooses, and checks it: 3 to 25 letters and digits. The same rules apply
// when signing up and when changing it.
func NormalizeUsernamePrefix(prefix string) (string, error) {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if len(prefix) < 3 || len(prefix) > 25 {
		return "", errors.New("username prefix must be between 3 and 25 characters")
	}
	if !usernamePrefixPattern.MatchString(prefix) {
		return "", errors.New("username prefix must contain only alphanumeric characters")
	}
	return prefix, nil
}

// randomUsername is prefix, a dot and a random four digit number.
func randomUsername(prefix string) (string, error) {
	nBig, err := rand.Int(rand.Reader, big.NewInt(9000))
	if err != nil {
		return "", errors.New("failed to generate secure user discriminator")
	}
	return fmt.Sprintf("%s.%d", prefix, nBig.Int64()+1000), nil // [1000, 9999]
}

// ErrSameUsername means the new username's prefix is the one already in use.
var ErrSameUsername = errors.New("that is already your username")

// ChangeUsername gives the user a new username built from prefix, with a new
// four digit number. It can be done once every 30 days.
func (s *UserService) ChangeUsername(ctx context.Context, userID, prefix string) (*models.User, error) {
	prefix, err := NormalizeUsernamePrefix(prefix)
	if err != nil {
		return nil, err
	}
	current, err := s.repo.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(current.Username, prefix+".") && strings.Count(current.Username, ".") == 1 {
		return nil, ErrSameUsername
	}
	return s.repo.ChangeUsername(ctx, userID, prefix, time.Now(), randomUsername)
}

// MaxBioLength and the status limits are in characters, not bytes.
const (
	MaxBioLength        = 140
	MaxStatusEmoji      = 16
	MaxStatusText       = 60
	MinStatusExpirySecs = 60
	MaxStatusExpirySecs = 7 * 24 * 3600
)

// ErrInvalidProfile wraps what is wrong with a bio or status.
var ErrInvalidProfile = errors.New("invalid profile")

// NormalizeBio trims a bio and checks its length.
func NormalizeBio(bio string) (string, error) {
	bio = strings.TrimSpace(bio)
	if utf8.RuneCountInString(bio) > MaxBioLength {
		return "", fmt.Errorf("%w: your about text can be at most %d characters", ErrInvalidProfile, MaxBioLength)
	}
	return bio, nil
}

// StatusInput is a custom status as a person sends it. ExpiresIn is how many
// seconds it lasts; nil or 0 means until they change it.
type StatusInput struct {
	Emoji     string `json:"emoji"`
	Text      string `json:"text"`
	ExpiresIn *int   `json:"expires_in"`
}

// NormalizeStatus checks a status and works out when it ends. A status with
// no emoji and no text clears the status.
func NormalizeStatus(in StatusInput, now time.Time) (*models.UserStatus, error) {
	emoji := strings.TrimSpace(in.Emoji)
	text := strings.TrimSpace(in.Text)
	if utf8.RuneCountInString(emoji) > MaxStatusEmoji {
		return nil, fmt.Errorf("%w: the status emoji is too long", ErrInvalidProfile)
	}
	if utf8.RuneCountInString(text) > MaxStatusText {
		return nil, fmt.Errorf("%w: your status can be at most %d characters", ErrInvalidProfile, MaxStatusText)
	}
	status := &models.UserStatus{Emoji: emoji, Text: text}
	if emoji == "" && text == "" {
		return status, nil
	}
	if in.ExpiresIn != nil && *in.ExpiresIn != 0 {
		secs := *in.ExpiresIn
		if secs < MinStatusExpirySecs || secs > MaxStatusExpirySecs {
			return nil, fmt.Errorf("%w: a status lasts from a minute to a week", ErrInvalidProfile)
		}
		end := now.Add(time.Duration(secs) * time.Second)
		status.ExpiresAt = &end
	}
	return status, nil
}
