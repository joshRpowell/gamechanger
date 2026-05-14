package gcerr

import (
	"errors"
	"testing"
)

func TestSentinelClassification(t *testing.T) {
	cases := []struct {
		name     string
		err      error
		sentinel error
	}{
		{"auth", Authf("bad creds %d", 1), ErrAuth},
		{"network", Networkf("timeout"), ErrNetwork},
		{"config", Configf("missing"), ErrConfig},
		{"api shape", APIShapef("unexpected"), ErrAPIShape},
		{"storage", Storagef("locked"), ErrStorage},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if !errors.Is(tc.err, tc.sentinel) {
				t.Fatalf("errors.Is(%v, %v) = false; want true", tc.err, tc.sentinel)
			}
		})
	}
}

func TestMessageFormatting(t *testing.T) {
	err := Authf("bad creds %d", 42)
	if got, want := err.Error(), "bad creds 42"; got != want {
		t.Fatalf("Error() = %q; want %q", got, want)
	}
}
