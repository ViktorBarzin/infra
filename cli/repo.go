package main

import (
	"io"
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

// cryptFlagsFor returns the git-crypt bypass flags for a git-crypt repo that
// cannot use its real filters, else nil. The flags are injected per command and
// never persisted. An unlocked clone gets nil, so its worktrees check out
// plaintext and later plain git commands see no change. With the bypass they
// held ciphertext, which the real clean filter encrypted again on the next
// `git add -A` (infra 2c6fb5d23, cd32e7a06, 99e38e93a).
func cryptFlagsFor(repoRoot string) []string {
	if !isGitCryptRepo(repoRoot) {
		return nil
	}
	if gitCryptFiltersUsable(repoRoot) && !holdsGitCryptCiphertext(repoRoot) {
		return nil
	}
	return gitCryptFlags()
}

// gitCryptFiltersUsable reports whether the clone's smudge and clean filters
// can decrypt in any of its worktrees: both are configured with --key-file
// naming a readable key. Without --key-file, git-crypt 0.7.0 looks for the key
// under a linked worktree's own git dir, finds none, and the checkout fails.
// A locked clone has no filters configured, so it keeps the bypass.
func gitCryptFiltersUsable(repoRoot string) bool {
	for _, name := range []string{"filter.git-crypt.smudge", "filter.git-crypt.clean"} {
		cmd, err := gitOutput(repoRoot, "config", "--get", name)
		if err != nil {
			return false
		}
		key := keyFileArg(cmd)
		if key == "" {
			return false
		}
		f, err := os.Open(key)
		if err != nil {
			return false
		}
		f.Close()
	}
	return true
}

// keyFileArg returns the value of --key-file in a filter command line, or "".
func keyFileArg(cmd string) string {
	fields := strings.Fields(cmd)
	for i, f := range fields {
		f = strings.Trim(f, `"'`)
		if f == "--key-file" && i+1 < len(fields) {
			return strings.Trim(fields[i+1], `"'`)
		}
		if v, ok := strings.CutPrefix(f, "--key-file="); ok {
			return strings.Trim(v, `"'`)
		}
	}
	return ""
}

// gitCryptMagic starts every file git-crypt has encrypted.
const gitCryptMagic = "\x00GITCRYPT\x00"

// holdsGitCryptCiphertext reports whether any git-crypt file in the working
// tree at repoRoot is ciphertext. Worktrees made with the bypass hold it; the
// real filters would show each of those files as modified, so `work land` and
// `work clean` keep the bypass for them.
func holdsGitCryptCiphertext(repoRoot string) bool {
	out, err := gitOutput(repoRoot, "ls-files", "-z", "--", ":(attr:filter=git-crypt)")
	if err != nil {
		return false
	}
	for _, rel := range strings.Split(out, "\x00") {
		if rel == "" {
			continue
		}
		f, err := os.Open(filepath.Join(repoRoot, rel))
		if err != nil {
			continue
		}
		head := make([]byte, len(gitCryptMagic))
		n, _ := io.ReadFull(f, head)
		f.Close()
		if string(head[:n]) == gitCryptMagic {
			return true
		}
	}
	return false
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
