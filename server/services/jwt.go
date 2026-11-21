package services

import (
	"crypto/rand"
	"fmt"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/golang-jwt/jwt/v5"
)

type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`

	// SessionID is the signed-in device the tokens belong to. It is also in
	// both tokens, as "sid".
	SessionID string `json:"-"`
}

// NewSessionID makes the ID of a new signed-in device (a random UUID).
func NewSessionID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err) // the system's random source failing is not recoverable
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// GenerateTokenPair issues tokens for a new session.
func GenerateTokenPair(uid string) (*TokenPair, error) {
	return GenerateSessionTokens(uid, NewSessionID())
}

// GenerateSessionTokens issues tokens for an existing session, which is how a
// refresh keeps the same device.
func GenerateSessionTokens(uid, sessionID string) (*TokenPair, error) {
	// Access Token - 15 Minute Window
	atkClaims := jwt.MapClaims{
		"sub": uid,
		"sid": sessionID,
		"exp": time.Now().Add(15 * time.Minute).Unix(),
		"iat": time.Now().Unix(),
	}
	atk := jwt.NewWithClaims(jwt.SigningMethodHS256, atkClaims)
	atkStr, err := atk.SignedString([]byte(env.JWT_SECRET))
	if err != nil {
		return nil, err
	}

	// Refresh Token - 7 Day Lifespan
	// jti makes every refresh token different, even two issued in the same
	// second. Without it a rotated token could equal the one it replaces.
	rtkClaims := jwt.MapClaims{
		"sub": uid,
		"sid": sessionID,
		"jti": NewSessionID(),
		"exp": time.Now().Add(7 * 24 * time.Hour).Unix(),
		"iat": time.Now().Unix(),
	}
	rtk := jwt.NewWithClaims(jwt.SigningMethodHS256, rtkClaims)
	rtkStr, err := rtk.SignedString([]byte(env.JWT_SECRET))
	if err != nil {
		return nil, err
	}

	return &TokenPair{
		AccessToken:  atkStr,
		RefreshToken: rtkStr,
		SessionID:    sessionID,
	}, nil
}

// VerifyAccessToken returns the user a token was issued to.
func VerifyAccessToken(tokenStr string) (string, error) {
	uid, _, err := ParseToken(tokenStr)
	return uid, err
}

// ParseToken checks a token and returns its user and its session. The session
// is empty for a token issued before sessions existed.
func ParseToken(tokenStr string) (uid, sessionID string, err error) {
	token, err := jwt.Parse(tokenStr, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(env.JWT_SECRET), nil
	})

	if err != nil {
		return "", "", err
	}

	if claims, ok := token.Claims.(jwt.MapClaims); ok && token.Valid {
		uid, ok := claims["sub"].(string)
		if !ok {
			return "", "", fmt.Errorf("invalid token claim structure")
		}
		// A token made for another purpose (the step between a password and a
		// two-step code) is not a sign-in.
		if _, special := claims["purpose"]; special {
			return "", "", fmt.Errorf("invalid token claim structure")
		}
		sid, _ := claims["sid"].(string)
		return uid, sid, nil
	}

	return "", "", fmt.Errorf("invalid token status")
}
