package services

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/commandlinecoding/elephant/server/config"
	"golang.org/x/crypto/argon2"
)

// HashPassword generation
func HashPassword(password string) (string, error) {
	salt := make([]byte, config.Argon.SaltLength)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}

	if err := passwordGate.acquire(); err != nil {
		return "", err
	}
	hash := argon2.IDKey(
		[]byte(password),
		salt,
		config.Argon.Iterations,
		config.Argon.Memory,
		config.Argon.Parallelism,
		config.Argon.KeyLength,
	)
	passwordGate.release()

	b64Salt := base64.RawStdEncoding.EncodeToString(salt)
	b64Hash := base64.RawStdEncoding.EncodeToString(hash)

	encoded := fmt.Sprintf(
		"$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version,
		config.Argon.Memory,
		config.Argon.Iterations,
		config.Argon.Parallelism,
		b64Salt,
		b64Hash,
	)

	return encoded, nil
}

// VerifyPassword
func VerifyPassword(password, encodedHash string) (bool, error) {
	parts := strings.Split(encodedHash, "$")
	if len(parts) != 6 {
		return false, fmt.Errorf("invalid hash format structure")
	}

	var version int
	_, err := fmt.Sscanf(parts[2], "v=%d", &version)
	if err != nil {
		return false, err
	}
	if version != argon2.Version {
		return false, fmt.Errorf("incompatible argon2 version engine")
	}

	var memory, iterations, parallelism uint32
	_, err = fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &iterations, &parallelism)
	if err != nil {
		return false, err
	}

	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false, err
	}

	expectedHash, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false, err
	}

	if err := passwordGate.acquire(); err != nil {
		return false, err
	}
	actualHash := argon2.IDKey(
		[]byte(password),
		salt,
		iterations,
		memory,
		uint8(parallelism),
		uint32(len(expectedHash)),
	)
	passwordGate.release()

	if subtle.ConstantTimeCompare(expectedHash, actualHash) == 1 {
		return true, nil
	}

	return false, nil
}


func HashToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return fmt.Sprintf("%x", hash)
}