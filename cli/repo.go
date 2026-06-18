package main

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
)

// preferRemote picks the canonical remote: forgejo if present, else origin,
// else the first listed. (For infra, origin and forgejo both point at Forgejo.)
func preferRemote(remotes []string) string {
	has := map[string]bool{}
	for _, r := range remotes {
		has[r] = true
	}
	switch {
	case has["forgejo"]:
		return "forgejo"
	case has["origin"]:
		return "origin"
	case len(remotes) > 0:
		return remotes[0]
	default:
		return ""
	}
}

// hasGitCryptAttr reports whether .gitattributes content enables git-crypt.
func hasGitCryptAttr(gitattributes string) bool {
	return strings.Contains(gitattributes, "filter=git-crypt")
}

// gitCryptFlags are the per-command flags that disable smudge/clean so git
// operations in a git-crypt repo don't try to decrypt (NEVER persisted to config).
func gitCryptFlags() []string {
	return []string{
		"-c", "filter.git-crypt.smudge=cat",
		"-c", "filter.git-crypt.clean=cat",
		"-c", "filter.git-crypt.required=false",
	}
}

// gitOutput runs `git -C dir <args>` and returns trimmed stdout.
func gitOutput(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func gitRepoRoot(dir string) (string, error) {
	return gitOutput(dir, "rev-parse", "--show-toplevel")
}

// gitRemotes lists configured remote names for the repo at dir.
func gitRemotes(dir string) ([]string, error) {
	out, err := gitOutput(dir, "remote")
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}
	return strings.Split(out, "\n"), nil
}

// isGitCryptRepo reports whether the repo at repoRoot uses git-crypt.
func isGitCryptRepo(repoRoot string) bool {
	b, err := os.ReadFile(filepath.Join(repoRoot, ".gitattributes"))
	if err != nil {
		return false
	}
	return hasGitCryptAttr(string(b))
}

// cryptFlagsFor returns the git-crypt filter flags when repoRoot is encrypted,
// else nil. These are injected per-command and never persisted.
func cryptFlagsFor(repoRoot string) []string {
	if isGitCryptRepo(repoRoot) {
		return gitCryptFlags()
	}
	return nil
}

// gitStream runs `git [cryptFlags] -C repoRoot <args>` with live output.
func gitStream(repoRoot string, cryptFlags []string, args ...string) error {
	full := append(append([]string{}, cryptFlags...), append([]string{"-C", repoRoot}, args...)...)
	return runStreamingIn("", "git", full...)
}

// currentUser returns the OS username for branch naming (<user>/<topic>).
func currentUser() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	return "user"
}
