package services

import (
	"context"
	"errors"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/commandlinecoding/elephant/server/repository"
)

type E2EEService struct {
	repo *repository.E2EERepository
}

func NewE2EEService() *E2EEService {
	return &E2EEService{repo: repository.NewE2EERepository()}
}

func (s *E2EEService) UploadKeys(ctx context.Context, uid string, req models.UploadKeysReq) error {
	if req.DeviceID == "" || req.IdentityKey == "" || req.SignedPrekey == "" || req.Signature == "" {
		return errors.New("missing core payload parameters for prekey bundle submission")
	}
	return s.repo.SaveDeviceKeys(ctx, uid, req)
}

func (s *E2EEService) GetBundle(ctx context.Context, targetUID, deviceID string) (*models.PrekeyBundle, error) {
	if deviceID == "" {
		deviceID = "main"
	}
	return s.repo.FetchBundle(ctx, targetUID, deviceID)
}

func (s *E2EEService) CheckKeysExhaustion(ctx context.Context, uid string, deviceID string) (int, bool, error) {
	count, err := s.repo.GetOTPCount(ctx, uid, deviceID)
	if err != nil {
		return 0, false, err
	}
	return count, count < 10, nil
}

func (s *E2EEService) SetVerification(ctx context.Context, uid string, req models.VerifyContactReq) error {
	if req.VerifiedUserID == "" {
		return errors.New("target verified_user_id is required")
	}
	if uid == req.VerifiedUserID {
		return errors.New("cannot verify own user identity")
	}
	return s.repo.SetVerificationStatus(ctx, uid, req.VerifiedUserID, req.IsVerified)
}

func (s *E2EEService) GetVerification(ctx context.Context, uid, targetUID string) (*models.VerificationStatusResp, error) {
	if targetUID == "" {
		return nil, errors.New("target user_id is required")
	}
	isVerified, err := s.repo.GetVerificationStatus(ctx, uid, targetUID)
	if err != nil {
		return nil, err
	}

	return &models.VerificationStatusResp{
		UserID:         uid,
		VerifiedUserID: targetUID,
		IsVerified:     isVerified,
	}, nil
}

func (s *E2EEService) ResetKeys(ctx context.Context, uid string, password string) error {

	var passwordHash string
	query := `SELECT password_hash FROM users WHERE id = $1::uuid;`
	err := config.DB.QueryRow(ctx, query, uid).Scan(&passwordHash)
	if err != nil {
		return errors.New("user account context not found")
	}

	if passwordHash != "" {
		if password == "" {
			return errors.New("password required for re-authentication")
		}

		match, err := VerifyPassword(password, passwordHash)
		if errors.Is(err, ErrServerBusy) {
			return err
		}
		if err != nil || !match {
			return errors.New("invalid password re-authentication attempt")
		}
	}

	return s.repo.ResetUserKeys(ctx, uid)
}
