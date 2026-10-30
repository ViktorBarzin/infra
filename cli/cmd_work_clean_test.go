package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// `homelab work clean` printed "removed worktree ... and branch ..." even when
// `git branch -d` had just refused to delete an unmerged branch, so the last
// line claimed the opposite of what happened. These run the verb against a
// real repository and check the summary against what git has afterwards.

func workCleanRepo(t *testing.T, topic string, unlanded bool) (repo, branch string) {
	t.Helper()
	repo = gitRepo(t)
	run := func(dir string, args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	run(repo, "commit", "-q", "--allow-empty", "-m", "base")
	t.Setenv("USER", "tester")
	branch = "tester/" + topic
	wt := filepath.Join(repo, ".worktrees", topic)
	run(repo, "worktree", "add", "-q", "-b", branch, wt)
	if unlanded {
		run(wt, "commit", "-q", "--allow-empty", "-m", "not landed")
	}
	return repo, branch
}

func runWorkClean(t *testing.T, repo, topic string) string {
	t.Helper()
	old, _ := os.Getwd()
	if err := os.Chdir(repo); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)
	out, err := captureStdout(t, func() error { return workClean([]string{topic}) })
	if err != nil {
		t.Fatalf("workClean: %v", err)
	}
	return out
}

func branchExists(repo, branch string) bool {
	return exec.Command("git", "-C", repo, "rev-parse", "--verify", "-q", "refs/heads/"+branch).Run() == nil
}

func TestWorkCleanReportsBothRemovedWhenTheBranchIsMerged(t *testing.T) {
	repo, branch := workCleanRepo(t, "done", false)
	out := runWorkClean(t, repo, "done")
	if branchExists(repo, branch) {
		t.Fatalf("branch %s should be gone", branch)
	}
	if !strings.Contains(out, "removed worktree .worktrees/done and branch "+branch) {
		t.Fatalf("summary = %q", out)
	}
}

func TestWorkCleanDoesNotClaimItRemovedAnUnmergedBranch(t *testing.T) {
	repo, branch := workCleanRepo(t, "wip", true)
	out := runWorkClean(t, repo, "wip")
	if !branchExists(repo, branch) {
		t.Fatalf("branch %s should still exist (git branch -d refuses unmerged work)", branch)
	}
	if strings.Contains(out, "and branch") {
		t.Fatalf("summary claims the branch was removed: %q", out)
	}
	if !strings.Contains(out, "removed worktree .worktrees/wip") || !strings.Contains(out, "kept branch "+branch) {
		t.Fatalf("summary = %q", out)
	}
}
