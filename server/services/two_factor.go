package services

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/golang-jwt/jwt/v5"
)

// challengeLifetime is how long someone has to enter their code after the
// password was right.
const challengeLifetime = 5 * time.Minute

var (
	// ErrTwoFactorInvalid is a wrong or already used code. It says no more.
	ErrTwoFactorInvalid = errors.New("that code didn't work")

	// ErrTwoFactorNotAvailable is for an account with no password to protect.
	ErrTwoFactorNotAvailable = errors.New("two-step sign-in is for accounts that sign in with a password")

	// ErrTwoFactorAlreadyOn means setup was asked for while it is on.
	ErrTwoFactorAlreadyOn = errors.New("two-step sign-in is already on")

	// ErrTwoFactorNotStarted means a code came before setup was started.
	ErrTwoFactorNotStarted = errors.New("start setting up two-step sign-in first")

	// ErrChallengeInvalid is a missing, altered or expired sign-in step.
	ErrChallengeInvalid = errors.New("your sign-in took too long. Start again")
)

// TwoFactorRequiredError is what a correct password gets when the account has
// two-step sign-in on: no tokens yet, but a short lived challenge to answer
// with a code.
type TwoFactorRequiredError struct{ Challenge string }

func (e *TwoFactorRequiredError) Error() string {
	return "a code from your authenticator app is needed"
}

// TwoFactorLockedError means too many wrong codes: code entry is closed until
// Until.
type TwoFactorLockedError struct{ Until time.Time }

func (e *TwoFactorLockedError) Error() string {
	return "too many wrong codes. Try again after " + e.Until.UTC().Format("15:04 UTC")
}

func newChallenge(userID string) (string, error) {
	claims := jwt.MapClaims{
		"sub":     userID,
		"purpose": "2fa",
		"exp":     TOTPNow().Add(challengeLifetime).Unix(),
		"iat":     TOTPNow().Unix(),
		"jti":     NewSessionID(),
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(env.JWT_SECRET))
}

// challengeUser checks a sign-in step and returns who it is for.
func challengeUser(challenge string) (string, error) {
	token, err := jwt.Parse(challenge, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return []byte(env.JWT_SECRET), nil
	}, jwt.WithTimeFunc(TOTPNow))
	if err != nil || !token.Valid {
		return "", ErrChallengeInvalid
	}
	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok || claims["purpose"] != "2fa" {
		return "", ErrChallengeInvalid
	}
	uid, _ := claims["sub"].(string)
	if uid == "" {
		return "", ErrChallengeInvalid
	}
	return uid, nil
}

// checkTwoFactorCode accepts an authenticator code or a recovery code for the
// person. Wrong codes are counted, and too many in a row lock code entry.
func (s *AuthService) checkTwoFactorCode(ctx context.Context, userID, code string) error {
	repo := repository.NewTwoFactorRepository()
	tf, err := repo.Get(ctx, userID)
	if err != nil {
		return err
	}
	if tf == nil || !tf.Enabled {
		return ErrTwoFactorInvalid
	}
	now := TOTPNow()
	if tf.Locked(now) {
		return &TwoFactorLockedError{Until: *tf.LockedUntil}
	}

	secret, err := DecryptTOTPSecret(tf.SecretEnc, userID)
	if err != nil {
		return err
	}
	if step, ok := VerifyTOTP(secret, code, tf.LastUsedStep); ok {
		return repo.RecordSuccess(ctx, userID, step)
	}
	// A recovery code looks different (letters and digits, 8 long) from an
	// authenticator code (6 digits), so it is only tried if it is the shape.
	if n := NormalizeRecoveryCode(code); len(n) == 8 {
		used, err := repo.UseRecoveryCode(ctx, userID, HashRecoveryCode(n))
		if err != nil {
			return err
		}
		if used {
			return repo.RecordSuccess(ctx, userID, 0)
		}
	}

	locked, err := repo.RecordFailure(ctx, userID, now)
	if err != nil {
		return err
	}
	if locked {
		return &TwoFactorLockedError{Until: now.Add(repository.TwoFactorLockFor)}
	}
	return ErrTwoFactorInvalid
}

// CompleteTwoFactor finishes a sign-in that asked for a code.
func (s *AuthService) CompleteTwoFactor(ctx context.Context, challenge, code, deviceName string) (*models.User, *TokenPair, error) {
	uid, err := challengeUser(challenge)
	if err != nil {
		return nil, nil, err
	}
	if err := s.checkTwoFactorCode(ctx, uid, code); err != nil {
		return nil, nil, err
	}
	user, err := s.repo.FindByID(ctx, uid)
	if err != nil {
		return nil, nil, ErrChallengeInvalid
	}
	pairs, err := s.StartSession(ctx, uid, deviceName)
	if err != nil {
		return nil, nil, err
	}
	return user, pairs, nil
}

// hasPassword says whether the account signs in with a password. Accounts made
// with Google or GitHub don't, and two-step sign-in has nothing to protect.
func (s *AuthService) hasPassword(ctx context.Context, userID string) (bool, error) {
	hash, err := s.repo.PasswordHash(ctx, userID)
	if err != nil {
		return false, err
	}
	return strings.HasPrefix(hash, "$"), nil
}

// TwoFactorStatus says whether two-step sign-in is on, and how many recovery
// codes are left.
func (s *AuthService) TwoFactorStatus(ctx context.Context, userID string) (enabled bool, codesLeft int, err error) {
	repo := repository.NewTwoFactorRepository()
	enabled, err = repo.Enabled(ctx, userID)
	if err != nil || !enabled {
		return false, 0, err
	}
	codesLeft, err = repo.RecoveryCodesLeft(ctx, userID)
	return true, codesLeft, err
}

// BeginTwoFactor makes a secret for the person's authenticator app. It isn't
// on until a code from it is confirmed with EnableTwoFactor.
func (s *AuthService) BeginTwoFactor(ctx context.Context, userID, username string) (secret, uri string, err error) {
	if ok, err := s.hasPassword(ctx, userID); err != nil {
		return "", "", err
	} else if !ok {
		return "", "", ErrTwoFactorNotAvailable
	}
	raw, err := NewTOTPSecret()
	if err != nil {
		return "", "", err
	}
	sealed, err := EncryptTOTPSecret(raw, userID)
	if err != nil {
		return "", "", err
	}
	started, err := repository.NewTwoFactorRepository().StartSetup(ctx, userID, sealed)
	if err != nil {
		return "", "", err
	}
	if !started {
		return "", "", ErrTwoFactorAlreadyOn
	}
	return TOTPSecretText(raw), TOTPURI(raw, username), nil
}

// EnableTwoFactor turns it on once the person has shown their app works, and
// returns the recovery codes. This is the only time they are shown.
func (s *AuthService) EnableTwoFactor(ctx context.Context, userID, code string) ([]string, error) {
	repo := repository.NewTwoFactorRepository()
	tf, err := repo.Get(ctx, userID)
	if err != nil {
		return nil, err
	}
	if tf == nil {
		return nil, ErrTwoFactorNotStarted
	}
	if tf.Enabled {
		return nil, ErrTwoFactorAlreadyOn
	}
	secret, err := DecryptTOTPSecret(tf.SecretEnc, userID)
	if err != nil {
		return nil, err
	}
	step, ok := VerifyTOTP(secret, code, 0)
	if !ok {
		return nil, ErrTwoFactorInvalid
	}
	codes, err := NewRecoveryCodes()
	if err != nil {
		return nil, err
	}
	hashes := make([]string, len(codes))
	for i, c := range codes {
		hashes[i] = HashRecoveryCode(c)
	}
	if err := repo.Enable(ctx, userID, step, hashes); err != nil {
		return nil, err
	}
	return codes, nil
}

// DisableTwoFactor turns it off. It needs the password and a code, so
// someone holding an unlocked phone can't switch it off.
func (s *AuthService) DisableTwoFactor(ctx context.Context, userID, password, code string) error {
	hash, err := s.repo.PasswordHash(ctx, userID)
	if err != nil {
		return err
	}
	match, err := VerifyPassword(password, hash)
	if errors.Is(err, ErrServerBusy) {
		return err
	}
	if err != nil || !match {
		return errors.New("invalid password")
	}
	if err := s.checkTwoFactorCode(ctx, userID, code); err != nil {
		return err
	}
	return repository.NewTwoFactorRepository().Disable(ctx, userID)
}
