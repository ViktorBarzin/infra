package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// `homelab work start` used to pass the `cat` filter bypass for every repo whose
// .gitattributes mentions git-crypt, so a worktree of an UNLOCKED clone held
// ciphertext. Plain git commands there run the real clean filter, encrypt that
// ciphertext a second time, and `git add -A` committed the result (infra
// 2c6fb5d23, cd32e7a06, 99e38e93a). The bypass is now only for clones that
// cannot decrypt, and for worktrees that already hold ciphertext.
//
// fakecrypt stands in for git-crypt: clean always adds the header (so, like
// git-crypt, it encrypts ciphertext again), and both modes need a readable key.
const fakecrypt = `#!/bin/sh
mode=$1; shift
if [ "$1" != --key-file ] || [ ! -r "$2" ]; then echo "fakecrypt: Unable to open key file" >&2; exit 1; fi
case $mode in
clean) printf '\000GITCRYPT\000'; tr 'A-Za-z' 'N-ZA-Mn-za-m' ;;
smudge) tail -c +11 | tr 'A-Za-z' 'N-ZA-Mn-za-m' ;;
*) exit 1 ;;
esac
`

const secretPlain = "top secret\n"

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git -C %s %v: %v\n%s", dir, args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// gitCryptFixture builds a bare remote and an unlocked clone of it whose
// secret.txt goes through the fake filter. It returns (clone, remote).
func gitCryptFixture(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	script := filepath.Join(root, "fakecrypt")
	if err := os.WriteFile(script, []byte(fakecrypt), 0o755); err != nil {
		t.Fatal(err)
	}
	remote := filepath.Join(root, "remote.git")
	gitIn(t, root, "init", "-q", "--bare", "-b", "master", remote)

	clone := filepath.Join(root, "clone")
	gitIn(t, root, "init", "-q", "-b", "master", clone)
	gitIn(t, clone, "config", "user.email", "t@example.invalid")
	gitIn(t, clone, "config", "user.name", "t")
	key := filepath.Join(clone, ".git", "git-crypt", "keys", "default")
	if err := os.MkdirAll(filepath.Dir(key), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(key, []byte("key"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitIn(t, clone, "config", "filter.git-crypt.smudge", script+" smudge --key-file "+key)
	gitIn(t, clone, "config", "filter.git-crypt.clean", script+" clean --key-file "+key)
	gitIn(t, clone, "config", "filter.git-crypt.required", "true")

	files := map[string]string{
		".gitattributes": "secret.txt filter=git-crypt diff=git-crypt\n",
		"secret.txt":     secretPlain,
		"plain.txt":      "hello\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(clone, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	gitIn(t, clone, "add", ".gitattributes", "secret.txt", "plain.txt")
	gitIn(t, clone, "commit", "-q", "-m", "base")
	gitIn(t, clone, "remote", "add", "origin", remote)
	gitIn(t, clone, "push", "-q", "origin", "master")
	if blob := gitIn(t, clone, "cat-file", "-p", "HEAD:secret.txt"); !strings.HasPrefix(blob, "\x00GITCRYPT") {
		t.Fatalf("fixture: committed secret.txt is not encrypted: %q", blob)
	}
	return clone, remote
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestWorkStartInAnUnlockedGitCryptCloneChecksOutPlaintext(t *testing.T) {
	clone, _ := gitCryptFixture(t)
	t.Setenv("USER", "tester")
	t.Chdir(clone)

	if err := workStart([]string{"topic"}); err != nil {
		t.Fatal(err)
	}

	wt := filepath.Join(clone, ".worktrees", "topic")
	if got := readFile(t, filepath.Join(wt, "secret.txt")); got != secretPlain {
		t.Fatalf("worktree secret.txt = %q, want the plaintext %q", got, secretPlain)
	}
	if st := gitIn(t, wt, "status", "--porcelain"); st != "" {
		t.Fatalf("git status in the new worktree is not clean:\n%s", st)
	}
	// What went wrong three times: plain `git add -A` in the worktree staged a
	// double-encrypted secret. Now it stages nothing.
	gitIn(t, wt, "add", "-A")
	if staged := gitIn(t, wt, "diff", "--cached", "--name-only"); staged != "" {
		t.Fatalf("git add -A staged %q in a fresh worktree", staged)
	}
	if flags := cryptFlagsFor(wt); flags != nil {
		t.Errorf("cryptFlagsFor(decrypted worktree) = %v, want no bypass, so work land merges with the real filters", flags)
	}
}

// work land merges master with the flags cryptFlagsFor gives the worktree. A
// master change to an encrypted file must arrive as plaintext, with no diff.
func TestWorkLandMergeInAnUnlockedWorktreeKeepsSecretsPlaintext(t *testing.T) {
	clone, _ := gitCryptFixture(t)
	t.Setenv("USER", "tester")
	t.Chdir(clone)
	if err := workStart([]string{"topic"}); err != nil {
		t.Fatal(err)
	}
	wt := filepath.Join(clone, ".worktrees", "topic")

	const changed = "new secret\n"
	if err := os.WriteFile(filepath.Join(clone, "secret.txt"), []byte(changed), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, clone, "commit", "-q", "-am", "change secret")
	gitIn(t, clone, "push", "-q", "origin", "master")

	if err := gitStream(wt, cryptFlagsFor(wt), "fetch", "-q", "origin"); err != nil {
		t.Fatal(err)
	}
	if err := gitStream(wt, cryptFlagsFor(wt), "merge", "-q", "--no-edit", "origin/master"); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, filepath.Join(wt, "secret.txt")); got != changed {
		t.Fatalf("after the merge secret.txt = %q, want %q", got, changed)
	}
	if st := gitIn(t, wt, "status", "--porcelain"); st != "" {
		t.Fatalf("git status after the merge is not clean:\n%s", st)
	}
}

// work clean must use flags that match the worktree it removes: the real
// filters for a decrypted one, or `git worktree remove` sees every secret as
// modified and refuses.
func TestWorkCleanRemovesADecryptedWorktree(t *testing.T) {
	clone, _ := gitCryptFixture(t)
	t.Setenv("USER", "tester")
	t.Chdir(clone)
	if err := workStart([]string{"topic"}); err != nil {
		t.Fatal(err)
	}
	if err := workClean([]string{"topic"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(clone, ".worktrees", "topic")); !os.IsNotExist(err) {
		t.Fatalf("worktree still exists after work clean (stat err %v)", err)
	}
}

// A clone of another OS user on the shared devvm has no key and no filter
// config. It keeps the bypass, and its worktrees hold ciphertext as before.
func TestWorkStartInALockedGitCryptCloneKeepsTheBypass(t *testing.T) {
	_, remote := gitCryptFixture(t)
	locked := filepath.Join(t.TempDir(), "locked")
	gitIn(t, filepath.Dir(locked), "clone", "-q", remote, locked)

	if got := cryptFlagsFor(locked); !reflect.DeepEqual(got, gitCryptFlags()) {
		t.Fatalf("cryptFlagsFor(locked clone) = %v, want the bypass", got)
	}

	t.Setenv("USER", "tester")
	t.Chdir(locked)
	if err := workStart([]string{"topic"}); err != nil {
		t.Fatal(err)
	}
	wt := filepath.Join(locked, ".worktrees", "topic")
	if got := readFile(t, filepath.Join(wt, "secret.txt")); !strings.HasPrefix(got, "\x00GITCRYPT") {
		t.Fatalf("locked worktree secret.txt = %q, want ciphertext", got)
	}
	if err := workClean([]string{"topic"}); err != nil {
		t.Fatal(err)
	}
}

func TestCryptFlagsForWithoutAReadableKeyKeepsTheBypass(t *testing.T) {
	clone, _ := gitCryptFixture(t)
	if err := os.Remove(filepath.Join(clone, ".git", "git-crypt", "keys", "default")); err != nil {
		t.Fatal(err)
	}
	if got := cryptFlagsFor(clone); !reflect.DeepEqual(got, gitCryptFlags()) {
		t.Fatalf("cryptFlagsFor(clone without its key) = %v, want the bypass", got)
	}
}

// `git-crypt unlock` writes filters without --key-file, and git-crypt 0.7.0 then
// looks for the key under the linked worktree's own git dir, so a checkout in a
// new worktree would fail. Keep the bypass there too.
func TestCryptFlagsForFiltersWithoutKeyFileKeepTheBypass(t *testing.T) {
	clone, _ := gitCryptFixture(t)
	gitIn(t, clone, "config", "filter.git-crypt.smudge", `"git-crypt" smudge`)
	gitIn(t, clone, "config", "filter.git-crypt.clean", `"git-crypt" clean`)
	if got := cryptFlagsFor(clone); !reflect.DeepEqual(got, gitCryptFlags()) {
		t.Fatalf("cryptFlagsFor(filters without --key-file) = %v, want the bypass", got)
	}
}

// Worktrees made before this change hold ciphertext. Real filters would show
// every secret as modified there, so land and clean keep the bypass for them.
func TestCryptFlagsForAWorktreeHoldingCiphertextKeepsTheBypass(t *testing.T) {
	clone, _ := gitCryptFixture(t)
	t.Setenv("USER", "tester")
	ensureWorktreesIgnored(clone)
	old := filepath.Join(".worktrees", "old")
	args := append(gitCryptFlags(), "-C", clone, "worktree", "add", "-q", old, "-b", "tester/old", "origin/master")
	if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
		t.Fatalf("worktree add with the bypass: %v\n%s", err, out)
	}
	wt := filepath.Join(clone, old)
	if got := readFile(t, filepath.Join(wt, "secret.txt")); !strings.HasPrefix(got, "\x00GITCRYPT") {
		t.Fatalf("fixture: old worktree secret.txt = %q, want ciphertext", got)
	}

	if got := cryptFlagsFor(wt); !reflect.DeepEqual(got, gitCryptFlags()) {
		t.Fatalf("cryptFlagsFor(worktree holding ciphertext) = %v, want the bypass", got)
	}
	t.Chdir(clone)
	if err := workClean([]string{"old"}); err != nil {
		t.Fatal(err)
	}
}

func TestCryptFlagsForARepoWithoutGitCryptIsNil(t *testing.T) {
	if got := cryptFlagsFor(gitRepo(t)); got != nil {
		t.Fatalf("cryptFlagsFor(plain repo) = %v, want nil", got)
	}
}
