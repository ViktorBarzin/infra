package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A repo can declare its own land checks in .land-verify, and then they run
// whatever --verify-cmd or --no-verify says: in the DRILL R4 re-run
// (2026-10-30) an agent landed a revert with --verify-cmd "test ! -e <file>"
// instead of the repo's checks, although the repo's AGENTS.md named them.
func TestDeclaredLandChecksWin(t *testing.T) {
	dir := t.TempDir()
	write := func(body string) {
		if err := os.WriteFile(filepath.Join(dir, ".land-verify"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		name, file, flag string
		noVerify         bool
		wantCmd          string
		wantSkip         bool
	}{
		{"no file keeps the flag", "", "make test", false, "make test", false},
		{"no file keeps --no-verify", "", "", true, "", true},
		{"file replaces a placeholder flag", "# checks\nscripts/land-checks.sh\n", "test ! -e x", false, "scripts/land-checks.sh", false},
		{"file runs without a flag", "scripts/land-checks.sh\n", "", false, "scripts/land-checks.sh", false},
		{"file overrides --no-verify", "scripts/land-checks.sh\n", "", true, "scripts/land-checks.sh", false},
		{"blank file is ignored", "\n# nothing\n", "make test", false, "make test", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			os.Remove(filepath.Join(dir, ".land-verify"))
			if c.file != "" {
				write(c.file)
			}
			cmd, skip := effectiveVerify(dir, c.flag, c.noVerify)
			if cmd != c.wantCmd || skip != c.wantSkip {
				t.Fatalf("effectiveVerify = (%q, %v), want (%q, %v)", cmd, skip, c.wantCmd, c.wantSkip)
			}
		})
	}
}
