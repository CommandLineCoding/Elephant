package services

import (
	"testing"

	"github.com/commandlinecoding/elephant/server/env"
)

func TestRegistrationClosed(t *testing.T) {
	cases := map[string]bool{
		"closed":   true,
		"CLOSED":   true,
		" Closed ": true,
		"open":     false,
		"":         false,
		"anything": false, // main.go refuses to start with values like this
	}
	for value, want := range cases {
		old := env.REGISTRATION
		env.REGISTRATION = value
		if got := RegistrationClosed(); got != want {
			t.Errorf("REGISTRATION=%q: got %v, want %v", value, got, want)
		}
		env.REGISTRATION = old
	}
}
