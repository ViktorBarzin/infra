package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func workCommands() []Command {
	return []Command{
		{Path: []string{"work", "start"}, Tier: TierWrite,
			Summary: "create a worktree + branch for a task (enter it with EnterWorktree)", Run: workStart},
		{Path: []string{"work", "land"}, Tier: TierWrite,
			Summary: "merge master in, verify, push HEAD:master (run from the worktree)", Run: workLand},
		{Path: []string{"work", "clean"}, Tier: TierWrite,
			Summary: "remove a task's worktree + branch (run from the main checkout)", Run: workClean},
	}
}

// flagValue extracts `--name value` or `--name=value` from args.
func flagValue(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
		if strings.HasPrefix(a, name+"=") {
			return strings.TrimPrefix(a, name+"=")
		}
	}
	return ""
}

func remotesOrEmpty(repoRoot string) []string {
	r, _ := gitRemotes(repoRoot)
	return r
}

// workStart creates .worktrees/<topic> on branch <user>/<topic> off <remote>/master.
func workStart(args []string) error {
	topic, _ := firstPositional(args)
	if topic == "" {
		return fmt.Errorf("usage: homelab work start <topic>")
	}
	cwd, _ := os.Getwd()
	repoRoot, err := gitRepoRoot(cwd)
	if err != nil {
		return fmt.Errorf("not in a git repository: %w", err)
	}
	remote := preferRemote(remotesOrEmpty(repoRoot))
	if remote == "" {
		return fmt.Errorf("no git remote configured in %s", repoRoot)
	}
	flags := cryptFlagsFor(repoRoot)
	branch := currentUser() + "/" + topic
	wtRel := filepath.Join(".worktrees", topic)

	ensureWorktreesIgnored(repoRoot)
	if err := gitStream(repoRoot, flags, "fetch", remote); err != nil {
		return fmt.Errorf("fetch %s failed: %w", remote, err)
	}
	if err := gitStream(repoRoot, flags, "worktree", "add", wtRel, "-b", branch, remote+"/master"); err != nil {
		return fmt.Errorf("worktree add failed: %w", err)
	}
	wtPath := filepath.Join(repoRoot, wtRel)
	fmt.Printf("homelab: created worktree %s (branch %s off %s/master)\n", wtPath, branch, remote)
	fmt.Printf("homelab: enter it with the native tool: EnterWorktree(path=%q)\n", wtPath)
	return nil
}

// workLand integrates the current branch into master: fetch, merge master in,
// verify, push HEAD:master (retrying on non-fast-forward), with a feature-branch
// fallback when the direct push is rejected (e.g. branch protection).
func workLand(args []string) error {
	verifyCmd := flagValue(args, "--verify-cmd")
	cwd, _ := os.Getwd()
	repoRoot, err := gitRepoRoot(cwd)
	if err != nil {
		return fmt.Errorf("not in a git repository: %w", err)
	}
	branch, err := gitOutput(repoRoot, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return err
	}
	if branch == "master" || branch == "main" {
		return fmt.Errorf("refusing to land: already on %s", branch)
	}
	remote := preferRemote(remotesOrEmpty(repoRoot))
	if remote == "" {
		return fmt.Errorf("no git remote configured in %s", repoRoot)
	}
	flags := cryptFlagsFor(repoRoot)

	if err := gitStream(repoRoot, flags, "fetch", remote); err != nil {
		return fmt.Errorf("fetch failed: %w", err)
	}
	if err := gitStream(repoRoot, flags, "merge", "--no-edit", remote+"/master"); err != nil {
		return fmt.Errorf("merging %s/master failed — resolve conflicts then re-run `homelab work land`: %w", remote, err)
	}
	if err := runVerify(repoRoot, verifyCmd, containsArg(args, "--no-verify")); err != nil {
		return fmt.Errorf("not landing: %w", err)
	}
	if err := pushWithRetry(repoRoot, flags, remote, 3); err != nil {
		return landFallback(repoRoot, flags, remote, branch, err)
	}
	fmt.Printf("homelab: landed %s -> %s/master.\n", branch, remote)
	fmt.Println("homelab: CI was triggered by the push — watch it to completion before calling the work done")
	fmt.Println("         (the ci/deploy watch verbs arrive in a later version; for now follow the pipeline manually).")
	return nil
}

// runVerify runs the explicit --verify-cmd, else auto-detects (go test). If
// neither is available it REFUSES (returns an error) unless allowSkip is set —
// landing to master unverified must be a deliberate choice (--no-verify).
func runVerify(repoRoot, verifyCmd string, allowSkip bool) error {
	if verifyCmd != "" {
		fmt.Fprintf(os.Stderr, "homelab: verify: %s\n", verifyCmd)
		return runStreamingIn(repoRoot, "sh", "-c", verifyCmd)
	}
	if isFile(filepath.Join(repoRoot, "go.mod")) {
		fmt.Fprintln(os.Stderr, "homelab: verify: go test ./...")
		return runStreamingIn(repoRoot, "go", "test", "./...")
	}
	if allowSkip {
		fmt.Fprintln(os.Stderr, "homelab: WARNING: --no-verify set — landing without verification")
		return nil
	}
	return fmt.Errorf("no verification configured for this repo — pass --verify-cmd \"...\" or --no-verify to land without verifying")
}

// pushWithRetry pushes HEAD:master, recovering from non-fast-forward rejections
// by fetching + merging master and retrying.
func pushWithRetry(repoRoot string, flags []string, remote string, attempts int) error {
	var lastErr error
	for i := 0; i < attempts; i++ {
		if err := gitStream(repoRoot, flags, "push", remote, "HEAD:master"); err == nil {
			return nil
		} else {
			lastErr = err
		}
		if i < attempts-1 {
			fmt.Fprintln(os.Stderr, "homelab: push rejected — fetching + merging master, then retrying")
			if err := gitStream(repoRoot, flags, "fetch", remote); err != nil {
				return err
			}
			if err := gitStream(repoRoot, flags, "merge", "--no-edit", remote+"/master"); err != nil {
				return err
			}
		}
	}
	return fmt.Errorf("push to %s/master failed after %d attempts: %w", remote, attempts, lastErr)
}

// landFallback pushes the feature branch when the direct master push is rejected
// (e.g. branch protection), so the work isn't lost and a PR can be opened.
func landFallback(repoRoot string, flags []string, remote, branch string, pushErr error) error {
	fmt.Fprintf(os.Stderr, "homelab: direct push to master failed (%v)\n", pushErr)
	fmt.Fprintf(os.Stderr, "homelab: falling back to pushing the feature branch %q for a PR\n", branch)
	if err := gitStream(repoRoot, flags, "push", "-u", remote, branch); err != nil {
		return fmt.Errorf("fallback branch push also failed: %w", err)
	}
	fmt.Printf("homelab: pushed %s to %s. Open a PR to land it (branch protection blocked the direct push).\n", branch, remote)
	return nil
}

// workClean removes a task's worktree and branch. Run from the main checkout.
func workClean(args []string) error {
	topic, _ := firstPositional(args)
	if topic == "" {
		return fmt.Errorf("usage: homelab work clean <topic>  (run from the main checkout)")
	}
	cwd, _ := os.Getwd()
	repoRoot, err := gitRepoRoot(cwd)
	if err != nil {
		return fmt.Errorf("not in a git repository: %w", err)
	}
	flags := cryptFlagsFor(repoRoot)
	wtRel := filepath.Join(".worktrees", topic)
	branch := currentUser() + "/" + topic

	if err := gitStream(repoRoot, flags, "worktree", "remove", wtRel); err != nil {
		return fmt.Errorf("worktree remove failed (uncommitted changes? run from the main checkout, not the worktree): %w", err)
	}
	if err := gitStream(repoRoot, flags, "branch", "-d", branch); err != nil {
		fmt.Fprintf(os.Stderr, "homelab: note: could not delete branch %s (unmerged — use `git branch -D` if intended): %v\n", branch, err)
	}
	fmt.Printf("homelab: removed worktree %s and branch %s\n", wtRel, branch)
	return nil
}

// ensureWorktreesIgnored appends .worktrees/ to .gitignore if not already ignored.
func ensureWorktreesIgnored(repoRoot string) {
	if _, err := gitOutput(repoRoot, "check-ignore", ".worktrees"); err == nil {
		return
	}
	gi := filepath.Join(repoRoot, ".gitignore")
	f, err := os.OpenFile(gi, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.WriteString("\n.worktrees/\n"); err == nil {
		fmt.Fprintln(os.Stderr, "homelab: added .worktrees/ to .gitignore")
	}
}
