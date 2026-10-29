package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// validPresenceKinds is the fixed label taxonomy accepted by the presence board.
var validPresenceKinds = []string{"node", "host", "stack", "service", "db", "pvc", "infra"}

// machinePresence is where playbooks/devvm.yml installs presence for every user.
const machinePresence = "/usr/local/bin/presence"

// presenceScript locates the presence CLI — homelab WRAPS it, it does not
// reimplement it. Override with HOMELAB_PRESENCE; otherwise the machine-wide
// install, falling back to the old ~/code/scripts/presence monorepo copy.
func presenceScript() string {
	home, _ := os.UserHomeDir()
	return resolvePresence(os.Getenv("HOMELAB_PRESENCE"), isExecutable, home)
}

func resolvePresence(override string, exists func(string) bool, home string) string {
	if override != "" {
		return override
	}
	if exists(machinePresence) {
		return machinePresence
	}
	if home == "" {
		return "presence"
	}
	return filepath.Join(home, "code", "scripts", "presence")
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
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
