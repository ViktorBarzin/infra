package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// `homelab work start` makes sure .worktrees/ is ignored before it creates one.
// It used to append the line to the repo's .gitignore, which left the main
// checkout with an uncommitted change: every later `pull --ff-only` and every
// "is the checkout clean?" check then tripped over it. The ignore now goes in
// .git/info/exclude, which git honours the same way and never shows as a change.

func gitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{{"init", "-q"}, {"config", "user.email", "t@example.invalid"}, {"config", "user.name", "t"}} {
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	return dir
}

func ignored(t *testing.T, dir string) bool {
	t.Helper()
	return exec.Command("git", "-C", dir, "check-ignore", "-q", ".worktrees/").Run() == nil
}

func TestEnsureWorktreesIgnoredUsesInfoExcludeNotGitignore(t *testing.T) {
	dir := gitRepo(t)

	ensureWorktreesIgnored(dir)

	if !ignored(t, dir) {
		t.Fatal(".worktrees is not ignored afterwards")
	}
	if _, err := os.Stat(filepath.Join(dir, ".gitignore")); !os.IsNotExist(err) {
		t.Error("a .gitignore was written; the main checkout must stay clean")
	}
	out, err := exec.Command("git", "-C", dir, "status", "--porcelain").Output()
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(out)) != "" {
		t.Errorf("git status shows changes after ensureWorktreesIgnored: %q", out)
	}
}

func TestEnsureWorktreesIgnoredIsIdempotent(t *testing.T) {
	dir := gitRepo(t)
	ensureWorktreesIgnored(dir)
	ensureWorktreesIgnored(dir)

	b, err := os.ReadFile(filepath.Join(dir, ".git", "info", "exclude"))
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(b), ".worktrees/"); n != 1 {
		t.Errorf(".worktrees/ appears %d times in info/exclude, want 1", n)
	}
}

func TestEnsureWorktreesIgnoredLeavesAnExistingRuleAlone(t *testing.T) {
	dir := gitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(".worktrees/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(dir, ".git", "info", "exclude"))

	ensureWorktreesIgnored(dir)

	after, _ := os.ReadFile(filepath.Join(dir, ".git", "info", "exclude"))
	if string(before) != string(after) {
		t.Error("info/exclude changed although .gitignore already ignores .worktrees/")
	}
}

// From inside a linked worktree the exclude file that counts is the shared one
// in the main repository's git directory, not one under .git/worktrees/<name>.
func TestEnsureWorktreesIgnoredFromALinkedWorktreeWritesTheSharedExclude(t *testing.T) {
	dir := gitRepo(t)
	if out, err := exec.Command("git", "-C", dir, "commit", "-q", "--allow-empty", "-m", "base").CombinedOutput(); err != nil {
		t.Fatalf("commit: %v %s", err, out)
	}
	wt := filepath.Join(t.TempDir(), "wt")
	if out, err := exec.Command("git", "-C", dir, "worktree", "add", "-q", wt).CombinedOutput(); err != nil {
		t.Fatalf("worktree add: %v %s", err, out)
	}

	ensureWorktreesIgnored(wt)

	b, err := os.ReadFile(filepath.Join(dir, ".git", "info", "exclude"))
	if err != nil || !strings.Contains(string(b), ".worktrees/") {
		t.Errorf("the main repository's info/exclude lacks .worktrees/ (err %v)", err)
	}
}
