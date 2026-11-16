package services

import (
	"errors"
	"strings"
	"testing"
)

func TestNormalizeDisplayName(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"  Maya Chen  ", "Maya Chen", true},
		{"", "", false},
		{"   \t ", "", false},
		{strings.Repeat("a", 100), strings.Repeat("a", 100), true},
		{strings.Repeat("a", 101), "", false},
		// Counted in characters, not bytes: 100 three-byte characters fit.
		{strings.Repeat("名", 100), strings.Repeat("名", 100), true},
		{strings.Repeat("名", 101), "", false},
	}
	for _, c := range cases {
		got, err := NormalizeDisplayName(c.in)
		if c.ok && (err != nil || got != c.want) {
			t.Errorf("%q: got %q, %v; want %q", c.in, got, err, c.want)
		}
		if !c.ok && !errors.Is(err, ErrInvalidDisplayName) {
			t.Errorf("%q: want ErrInvalidDisplayName, got %v", c.in, err)
		}
	}
}
