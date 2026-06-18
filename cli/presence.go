package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// validPresenceKinds is the fixed label taxonomy accepted by the presence board.
var validPresenceKinds = []string{"node", "host", "stack", "service", "db", "pvc", "infra"}

// presenceScript locates the presence CLI — homelab WRAPS it, it does not
// reimplement it. Override with HOMELAB_PRESENCE; defaults to ~/code/scripts/presence.
func presenceScript() string {
	if p := os.Getenv("HOMELAB_PRESENCE"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "presence"
	}
	return filepath.Join(home, "code", "scripts", "presence")
}

// validateLabel checks a presence label is <kind>:<name> with a known kind.
func validateLabel(label string) error {
	parts := strings.SplitN(label, ":", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return fmt.Errorf("label must be <kind>:<name> (e.g. stack:vault), got %q", label)
	}
	for _, k := range validPresenceKinds {
		if parts[0] == k {
			return nil
		}
	}
	return fmt.Errorf("invalid label kind %q; valid kinds: %s", parts[0], strings.Join(validPresenceKinds, ", "))
}

// presenceClaim claims label on the board with a purpose note.
func presenceClaim(label, purpose string) error {
	if err := validateLabel(label); err != nil {
		return err
	}
	args := []string{"claim", label}
	if purpose != "" {
		args = append(args, "--purpose", purpose)
	}
	return runStreaming(presenceScript(), args...)
}

// presenceRelease releases a prior claim on label.
func presenceRelease(label string) error {
	if err := validateLabel(label); err != nil {
		return err
	}
	return runStreaming(presenceScript(), "release", label)
}
