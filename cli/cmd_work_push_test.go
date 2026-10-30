package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// landRig is a bare "remote", a worktree-like clone on a feature branch, and a
// second clone that moves master underneath it, which is what another agent
// landing during our verify step looks like.
type landRig struct {
	remote, mine, theirs string
}

func gitT(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func writeT(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func newLandRig(t *testing.T) landRig {
	t.Helper()
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@example.invalid")
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	root := t.TempDir()
	r := landRig{
		remote: filepath.Join(root, "remote.git"),
		mine:   filepath.Join(root, "mine"),
		theirs: filepath.Join(root, "theirs"),
	}
	gitT(t, root, "init", "-q", "--bare", "-b", "master", r.remote)
	gitT(t, root, "clone", "-q", r.remote, r.mine)
	writeT(t, filepath.Join(r.mine, "shared.txt"), "one\ntwo\nthree\n")
	gitT(t, r.mine, "add", "shared.txt")
	gitT(t, r.mine, "commit", "-q", "-m", "base")
	gitT(t, r.mine, "push", "-q", "origin", "HEAD:master")
	gitT(t, root, "clone", "-q", r.remote, r.theirs)
	gitT(t, r.mine, "checkout", "-q", "-b", "me/topic")
	return r
}

// theirsLands commits a change in the other clone and pushes it to master.
func (r landRig) theirsLands(t *testing.T, file, body string) {
	t.Helper()
	writeT(t, filepath.Join(r.theirs, file), body)
	gitT(t, r.theirs, "add", file)
	gitT(t, r.theirs, "commit", "-q", "-m", "theirs: "+file)
	gitT(t, r.theirs, "push", "-q", "origin", "HEAD:master")
}

func (r landRig) mineCommits(t *testing.T, file, body string) string {
	t.Helper()
	writeT(t, filepath.Join(r.mine, file), body)
	gitT(t, r.mine, "add", file)
	gitT(t, r.mine, "commit", "-q", "-m", "mine: "+file)
	return gitT(t, r.mine, "rev-parse", "HEAD")
}

func (r landRig) remoteMaster(t *testing.T) string {
	return gitT(t, r.remote, "rev-parse", "master")
}

func (r landRig) onRemoteMaster(t *testing.T, sha string) bool {
	t.Helper()
	cmd := exec.Command("git", "-C", r.remote, "merge-base", "--is-ancestor", sha, "master")
	return cmd.Run() == nil
}

func TestPushRetryReverifiesTheMergeBeforePushing(t *testing.T) {
	r := newLandRig(t)
	mine := r.mineCommits(t, "mine.txt", "mine\n")
	r.theirsLands(t, "theirs.txt", "theirs\n") // master moved during our verify

	var verified []string
	reverify := func() error {
		head := gitT(t, r.mine, "rev-parse", "HEAD")
		verified = append(verified, head)
		return nil
	}
	if err := pushWithRetry(r.mine, nil, "origin", 3, reverify); err != nil {
		t.Fatalf("pushWithRetry: %v", err)
	}
	if len(verified) != 1 {
		t.Fatalf("the retry merge must be verified exactly once before its push, got %d runs", len(verified))
	}
	if got := r.remoteMaster(t); got != verified[0] {
		t.Fatalf("master holds %s, but the verified commit was %s", got, verified[0])
	}
	if !r.onRemoteMaster(t, mine) {
		t.Fatal("my commit should be on master after the retry")
	}
}

func TestPushRetryDoesNotPushAMergeThatFailsVerify(t *testing.T) {
	r := newLandRig(t)
	mine := r.mineCommits(t, "mine.txt", "mine\n")
	r.theirsLands(t, "theirs.txt", "theirs\n")
	before := r.remoteMaster(t)

	err := pushWithRetry(r.mine, nil, "origin", 3, func() error { return errors.New("checks red") })
	if err == nil {
		t.Fatal("a merge that fails verify must not be pushed")
	}
	var refused *pushRefusedError
	if errors.As(err, &refused) {
		t.Fatalf("a failed re-verify is not a refused push (that would trigger the PR fallback): %v", err)
	}
	if got := r.remoteMaster(t); got != before {
		t.Fatalf("master moved to %s after a failed re-verify", got)
	}
	if r.onRemoteMaster(t, mine) {
		t.Fatal("my commit reached master without passing verify")
	}
}

func TestPushRetryConflictStopsWithoutFallback(t *testing.T) {
	r := newLandRig(t)
	r.mineCommits(t, "shared.txt", "one\nTWO (mine)\nthree\n")
	r.theirsLands(t, "shared.txt", "one\nTWO (theirs)\nthree\n")
	before := r.remoteMaster(t)

	called := false
	err := pushWithRetry(r.mine, nil, "origin", 3, func() error { called = true; return nil })
	if err == nil {
		t.Fatal("a conflicting retry merge must fail the land")
	}
	var conflict *mergeConflictError
	if !errors.As(err, &conflict) {
		t.Fatalf("want a mergeConflictError, got %T: %v", err, err)
	}
	if !strings.Contains(conflict.Error(), "shared.txt") {
		t.Fatalf("the conflict error should name the conflicted file, got %q", conflict.Error())
	}
	if called {
		t.Fatal("verify must not run on a conflicted tree")
	}
	if got := r.remoteMaster(t); got != before {
		t.Fatal("nothing may be pushed after a conflict")
	}
}

func TestPushRefusedByTheServerIsReportedAsRefused(t *testing.T) {
	r := newLandRig(t)
	r.mineCommits(t, "mine.txt", "mine\n")
	hook := filepath.Join(r.remote, "hooks", "pre-receive")
	writeT(t, hook, "#!/bin/sh\necho 'protected branch: master' >&2\nexit 1\n")
	if err := os.Chmod(hook, 0o755); err != nil {
		t.Fatal(err)
	}
	err := pushWithRetry(r.mine, nil, "origin", 3, func() error { return nil })
	var refused *pushRefusedError
	if !errors.As(err, &refused) {
		t.Fatalf("a server-side refusal should be a pushRefusedError, got %T: %v", err, err)
	}
}

func TestLandFallbackSaysNotLanded(t *testing.T) {
	r := newLandRig(t)
	r.mineCommits(t, "mine.txt", "mine\n")
	err := landFallback(r.mine, nil, "origin", "me/topic", errors.New("refused"))
	if err == nil {
		t.Fatal("the PR fallback did not land anything, so it must not exit 0")
	}
	if !strings.Contains(err.Error(), "not landed") {
		t.Fatalf("the fallback error should say the change was not landed, got %q", err.Error())
	}
	gitT(t, r.remote, "rev-parse", "--verify", "me/topic") // the branch is saved for a PR
}

func TestIsNonFastForward(t *testing.T) {
	cases := []struct {
		stderr string
		want   bool
	}{
		{" ! [rejected]        HEAD -> master (non-fast-forward)\n", true},
		{" ! [rejected]        HEAD -> master (fetch first)\n", true},
		{" ! [remote rejected] HEAD -> master (pre-receive hook declined)\n", false},
		{"remote: protected branch\n ! [remote rejected] HEAD -> master (protected branch hook declined)\n", false},
		{"fatal: unable to access 'https://x/': Could not resolve host\n", false},
	}
	for _, c := range cases {
		if got := isNonFastForward(c.stderr); got != c.want {
			t.Errorf("isNonFastForward(%q) = %v, want %v", c.stderr, got, c.want)
		}
	}
}

// Several worktrees of one clone share refs/remotes/<remote>/*, so two lands
// fetching in the same second race for the ref lock and one fails with
// "cannot lock ref" (DRILL R8 re-run, 2026-10-30). The fetch is retried.
func TestFetchRetriesWhenAnotherFetchHoldsTheRefLock(t *testing.T) {
	r := newLandRig(t)
	gitT(t, r.mine, "fetch", "-q", "origin")
	r.theirsLands(t, "theirs.txt", "theirs\n")
	lock := filepath.Join(r.mine, ".git", "refs", "remotes", "origin", "master.lock")
	if err := os.MkdirAll(filepath.Dir(lock), 0o755); err != nil {
		t.Fatal(err)
	}
	writeT(t, lock, "")
	done := make(chan struct{})
	go func() {
		time.Sleep(400 * time.Millisecond)
		os.Remove(lock)
		close(done)
	}()
	if err := gitFetchRetry(r.mine, nil, "origin", 5, 200*time.Millisecond); err != nil {
		t.Fatalf("fetch should succeed once the other fetch's lock is gone: %v", err)
	}
	<-done
	if got, want := gitT(t, r.mine, "rev-parse", "origin/master"), r.remoteMaster(t); got != want {
		t.Fatalf("origin/master = %s, want %s", got, want)
	}
}
