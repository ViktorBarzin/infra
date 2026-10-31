package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// On 2026-10-31 a release started from a worktree died when `homelab work
// clean` removed that worktree mid-run: git, started from a cwd that no
// longer exists, stops with "Unable to read current working directory".
func TestReleaseOutlivesTheDirectoryItWasStartedFrom(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	dir := t.TempDir()
	repo := filepath.Join(dir, "repo")
	for _, args := range [][]string{
		{"init", "--quiet", repo},
		{"-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--allow-empty", "-m", "one"},
	} {
		if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	worktree := filepath.Join(dir, "worktree")
	if err := os.Mkdir(worktree, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(worktree)

	if err := leaveStartingDir(); err != nil {
		t.Fatal(err)
	}
	// The worktree is cleaned while the release runs.
	if err := os.RemoveAll(worktree); err != nil {
		t.Fatal(err)
	}
	// As checkout clones: borrowing objects from a local clone, then
	// repacking them, which is where git reads the cwd.
	clone := exec.Command("git", "clone", "--quiet", "--no-checkout", "--reference-if-able", repo, "--dissociate",
		"file://"+repo, filepath.Join(dir, "src"))
	if out, err := clone.CombinedOutput(); err != nil {
		t.Fatalf("git clone after the starting directory went: %v %s", err, out)
	}
}
