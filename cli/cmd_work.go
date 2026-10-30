package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func workCommands() []Command {
	return []Command{
		{Path: []string{"work"}, Tier: TierRead,
			Summary: "worktree lifecycle for a task: work start|land|clean (run `homelab work` for help)", Run: workHelp},
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
	if err := gitFetchRetry(repoRoot, flags, remote, 3, 2*time.Second); err != nil {
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

	if err := gitFetchRetry(repoRoot, flags, remote, 3, 2*time.Second); err != nil {
		return fmt.Errorf("fetch failed: %w", err)
	}
	if err := gitStream(repoRoot, flags, "merge", "--no-edit", remote+"/master"); err != nil {
		return fmt.Errorf("merging %s/master failed — resolve conflicts then re-run `homelab work land`: %w", remote, err)
	}
	// Read on every run, from the merged tree, so a retry merge that brings a
	// newer .land-verify uses it.
	verify := func() error {
		cmd, skip := effectiveVerify(repoRoot, verifyCmd, containsArg(args, "--no-verify"))
		return runVerify(repoRoot, cmd, skip)
	}
	if err := verify(); err != nil {
		return fmt.Errorf("not landing: %w", err)
	}
	// Each retry merge is a new tree that nobody has checked yet, so it goes
	// through the same verify step before it is pushed (2026-10-30 drills: two
	// conflict-free merges reached master unverified).
	reverify := func() error {
		fmt.Fprintln(os.Stderr, "homelab: re-verifying the merged tree before pushing it")
		return verify()
	}
	// Take turns with other lands of this repo on this machine for the push,
	// so a land waits for its turn instead of losing push races.
	remoteURL, _ := gitOutput(repoRoot, "remote", "get-url", remote)
	release, err := acquireLandLock(landLockKey(remoteURL), currentUser()+" "+branch, 60*time.Minute, 5*time.Second)
	if err != nil {
		return fmt.Errorf("not landed: %w", err)
	}
	err = pushWithRetry(repoRoot, flags, remote, 3, reverify)
	release()
	if err != nil {
		var refused *pushRefusedError
		if errors.As(err, &refused) {
			return landFallback(repoRoot, flags, remote, branch, err)
		}
		return fmt.Errorf("not landed: %w", err)
	}
	fmt.Printf("homelab: landed %s -> %s/master.\n", branch, remote)
	if containsArg(args, "--no-ci-watch") {
		fmt.Println("homelab: --no-ci-watch set; not waiting for CI.")
		return nil
	}
	landed, _ := gitOutput(repoRoot, "rev-parse", "HEAD")
	fmt.Fprintln(os.Stderr, "homelab: watching CI for the landed commit...")
	note, fatal := landCIOutcome(ciWatch(append([]string{landed}, ciWaitArgs(args)...)))
	if note != "" {
		fmt.Fprintln(os.Stderr, note)
	}
	return fatal
}

// ciWaitArgs forwards the wait-tuning flags from `work land` through to the
// watch, so `work land --timeout 45m` bounds the wait the same way `ci watch`
// does. Everything else in land's args (--verify-cmd and friends) would only
// confuse the parser.
func ciWaitArgs(args []string) []string {
	// land's own value-taking flags, whose VALUE must not be scanned: a
	// `--verify-cmd --timeout 45m` would otherwise forward a wait flag that was
	// really part of the verify command (mirrors ciPositionalCommit).
	valueFlags := map[string]bool{"--verify-cmd": true}
	var out []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if valueFlags[a] {
			i++ // skip its value
			continue
		}
		switch {
		case a == "--timeout" || a == "--appear-grace":
			if i+1 < len(args) {
				out = append(out, a, args[i+1])
				i++
			}
		case strings.HasPrefix(a, "--timeout=") || strings.HasPrefix(a, "--appear-grace="):
			out = append(out, a)
		}
	}
	return out
}

// landVerifyFile is where a repo declares the checks every land runs.
const landVerifyFile = ".land-verify"

// effectiveVerify returns the verify command and whether to skip verifying.
// A repo that declares its checks in .land-verify (the first line that is not
// blank or a # comment) gets them on every land, whatever --verify-cmd or
// --no-verify say: the gate belongs to the repo, not to whoever lands
// (DRILL R4 re-run, 2026-10-30, a revert landed with a placeholder check).
func effectiveVerify(repoRoot, flagCmd string, noVerify bool) (string, bool) {
	b, err := os.ReadFile(filepath.Join(repoRoot, landVerifyFile))
	if err != nil {
		return flagCmd, noVerify
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if flagCmd != "" && flagCmd != line {
			fmt.Fprintf(os.Stderr, "homelab: this repo declares its land checks in %s; running `%s` instead of --verify-cmd\n", landVerifyFile, line)
		}
		if noVerify {
			fmt.Fprintf(os.Stderr, "homelab: --no-verify ignored: this repo declares its land checks in %s\n", landVerifyFile)
		}
		return line, false
	}
	return flagCmd, noVerify
}

// runVerify runs the explicit --verify-cmd, else auto-detects (go test). If
// neither is available it REFUSES (returns an error) unless allowSkip is set —
// landing to master unverified must be a deliberate choice (--no-verify).
func runVerify(repoRoot, verifyCmd string, allowSkip bool) error {
	if verifyCmd != "" {
		fmt.Fprintf(os.Stderr, "homelab: verify: %s\n", verifyCmd)
		return runStreamingIn(repoRoot, "sh", "-c", verifyCmd)
	}
	// Auto-detection covered only Go, and none of the nine most-worked repos
	// here has a root go.mod — so `work land` errored on the first attempt in
	// almost every repo and the manual git path got used instead (2026-08-31
	// session study, theme 6). Each entry below is checked for the marker file
	// AND for the runner being present, so a detected-but-unrunnable toolchain
	// falls through to the explicit-flag error rather than failing mid-land.
	for _, d := range []struct {
		marker string
		runner string
		args   []string
	}{
		{"go.mod", "go", []string{"test", "./..."}},
		{"Cargo.toml", "cargo", []string{"test"}},
		{"pyproject.toml", "pytest", []string{"-q"}},
		{"pytest.ini", "pytest", []string{"-q"}},
		{"tox.ini", "pytest", []string{"-q"}},
		{"Makefile", "make", []string{"test"}},
	} {
		if !isFile(filepath.Join(repoRoot, d.marker)) {
			continue
		}
		if _, err := exec.LookPath(d.runner); err != nil {
			continue
		}
		// A Makefile without a `test` target would fail for the wrong reason.
		if d.marker == "Makefile" && !makefileHasTarget(filepath.Join(repoRoot, "Makefile"), "test") {
			continue
		}
		fmt.Fprintf(os.Stderr, "homelab: verify: %s %s (detected %s)\n",
			d.runner, strings.Join(d.args, " "), d.marker)
		return runStreamingIn(repoRoot, d.runner, d.args...)
	}
	// package.json is handled separately: the script name is what varies.
	if pkg := filepath.Join(repoRoot, "package.json"); isFile(pkg) {
		if _, err := exec.LookPath("npm"); err == nil {
			if script := packageJSONScript(pkg, "test", "vitest", "jest"); script != "" {
				fmt.Fprintf(os.Stderr, "homelab: verify: npm run %s (detected package.json)\n", script)
				return runStreamingIn(repoRoot, "npm", "run", script)
			}
		}
	}
	if allowSkip {
		fmt.Fprintln(os.Stderr, "homelab: WARNING: --no-verify set — landing without verification")
		return nil
	}
	return fmt.Errorf("no verification detected for this repo (looked for go.mod, Cargo.toml, pyproject.toml/pytest.ini/tox.ini, a Makefile test target, and a package.json test script) — pass --verify-cmd \"...\" or --no-verify to land without verifying")
}

// pushRefusedError is a push the server refused for a reason other than
// master having moved (branch protection, a hook). Only this one falls back to
// pushing the feature branch for a PR.
type pushRefusedError struct{ err error }

func (e *pushRefusedError) Error() string { return "the server refused the push: " + e.err.Error() }
func (e *pushRefusedError) Unwrap() error { return e.err }

// mergeConflictError is a retry merge of master that stopped on conflicts.
// The worktree is left mid-merge so the conflicted files can be resolved.
type mergeConflictError struct {
	remote string
	files  []string
}

func (e *mergeConflictError) Error() string {
	return fmt.Sprintf("CONFLICT merging %s/master into this branch (%s); nothing was pushed. "+
		"The worktree is mid-merge: resolve each file keeping both changes' intent, "+
		"commit the merge, then run `homelab work land` again",
		e.remote, strings.Join(e.files, ", "))
}

// isNonFastForward reports whether git push's stderr says the push was refused
// only because the remote branch has commits we do not have.
func isNonFastForward(stderr string) bool {
	return strings.Contains(stderr, "(non-fast-forward)") || strings.Contains(stderr, "(fetch first)")
}

// gitPushCapture runs `git push` with live output and also returns its stderr.
func gitPushCapture(repoRoot string, flags []string, args ...string) (string, error) {
	full := append(append([]string{}, flags...), append([]string{"-C", repoRoot, "push"}, args...)...)
	cmd := exec.Command("git", full...)
	var buf bytes.Buffer
	cmd.Stdout = os.Stdout
	cmd.Stderr = io.MultiWriter(os.Stderr, &buf)
	err := cmd.Run()
	return buf.String(), err
}

// gitFetchRetry fetches remote, trying again after a pause when it fails.
// Every worktree of a clone shares refs/remotes/<remote>/*, so two lands that
// fetch in the same second race for the ref lock and one fails with "cannot
// lock ref" (DRILL R8 re-run, 2026-10-30); a second try a moment later works.
func gitFetchRetry(repoRoot string, flags []string, remote string, attempts int, pause time.Duration) error {
	var err error
	for i := 0; i < attempts; i++ {
		if err = gitStream(repoRoot, flags, "fetch", remote); err == nil {
			return nil
		}
		if i < attempts-1 {
			fmt.Fprintf(os.Stderr, "homelab: fetch %s failed, trying again in %s\n", remote, pause)
			time.Sleep(pause)
		}
	}
	return err
}

// pushWithRetry pushes HEAD:master. When master moved meanwhile it fetches,
// merges master in, runs reverify on the merged tree, and pushes again. A
// conflicting merge or a failed reverify stops it without pushing; a refusal
// that is not about master moving comes back as a *pushRefusedError.
func pushWithRetry(repoRoot string, flags []string, remote string, attempts int, reverify func() error) error {
	var lastErr error
	for i := 0; i < attempts; i++ {
		stderr, err := gitPushCapture(repoRoot, flags, remote, "HEAD:master")
		if err == nil {
			return nil
		}
		if !isNonFastForward(stderr) {
			return &pushRefusedError{err: err}
		}
		lastErr = err
		if i == attempts-1 {
			break
		}
		fmt.Fprintln(os.Stderr, "homelab: push rejected — fetching + merging master, then retrying")
		if err := gitFetchRetry(repoRoot, flags, remote, 3, 2*time.Second); err != nil {
			return err
		}
		if err := gitStream(repoRoot, flags, "merge", "--no-edit", remote+"/master"); err != nil {
			files, _ := gitOutput(repoRoot, "diff", "--name-only", "--diff-filter=U")
			if files == "" {
				return fmt.Errorf("merging %s/master failed: %w", remote, err)
			}
			return &mergeConflictError{remote: remote, files: strings.Split(files, "\n")}
		}
		if reverify != nil {
			if err := reverify(); err != nil {
				return fmt.Errorf("the merge with %s/master failed verification, so it was not pushed; "+
					"fix it on this branch and land again: %w", remote, err)
			}
		}
	}
	return fmt.Errorf("push to %s/master failed after %d attempts because master kept moving; run `homelab work land` again: %w", remote, attempts, lastErr)
}

// landFallback pushes the feature branch when the server refuses the direct
// master push (e.g. branch protection), so the work isn't lost and a PR can be
// opened. Nothing landed, so it returns an error: an agent that trusts the
// exit code must not believe the change is on master.
func landFallback(repoRoot string, flags []string, remote, branch string, pushErr error) error {
	fmt.Fprintf(os.Stderr, "homelab: direct push to master failed (%v)\n", pushErr)
	fmt.Fprintf(os.Stderr, "homelab: falling back to pushing the feature branch %q for a PR\n", branch)
	if err := gitStream(repoRoot, flags, "push", "-u", remote, branch); err != nil {
		return fmt.Errorf("not landed: the server refused the master push and the fallback branch push also failed: %w", err)
	}
	return fmt.Errorf("not landed: the server refused the push to master (%v); pushed %s to %s instead — open a PR to land it", pushErr, branch, remote)
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
		fmt.Printf("homelab: removed worktree %s; kept branch %s, which has work that is not on master\n", wtRel, branch)
		return nil
	}
	fmt.Printf("homelab: removed worktree %s and branch %s\n", wtRel, branch)
	return nil
}

// ensureWorktreesIgnored makes sure git ignores .worktrees/ before a worktree is
// created under it. The rule goes into the repository's shared info/exclude,
// which git honours like .gitignore but never reports as a change. Appending to
// .gitignore used to leave the main checkout dirty, so the next pull --ff-only
// and every "is the checkout clean?" check tripped over it.
func ensureWorktreesIgnored(repoRoot string) {
	// With the trailing slash: a ".worktrees/" rule matches directories only, and
	// before the first worktree exists git cannot know the bare name is one, so
	// asking about ".worktrees" reported "not ignored" and appended the rule again.
	if _, err := gitOutput(repoRoot, "check-ignore", ".worktrees/"); err == nil {
		return
	}
	common, err := gitOutput(repoRoot, "rev-parse", "--git-common-dir")
	if err != nil {
		return
	}
	common = strings.TrimSpace(common)
	if !filepath.IsAbs(common) {
		common = filepath.Join(repoRoot, common)
	}
	exclude := filepath.Join(common, "info", "exclude")
	if err := os.MkdirAll(filepath.Dir(exclude), 0o755); err != nil {
		return
	}
	lead := ""
	if b, err := os.ReadFile(exclude); err == nil && len(b) > 0 && b[len(b)-1] != '\n' {
		lead = "\n"
	}
	f, err := os.OpenFile(exclude, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.WriteString(lead + ".worktrees/\n"); err == nil {
		fmt.Fprintln(os.Stderr, "homelab: added .worktrees/ to .git/info/exclude")
	}
}

// makefileHasTarget reports whether a Makefile declares the named target, so a
// Makefile that simply exists does not get treated as a test runner.
func makefileHasTarget(path, target string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, target+":") {
			return true
		}
	}
	return false
}

// packageJSONScript returns the first of the named scripts that package.json
// actually declares. Guessing `npm test` on a project without a test script
// fails for the wrong reason and reads as a broken verb.
func packageJSONScript(path string, names ...string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var pkg struct {
		Scripts map[string]string `json:"scripts"`
	}
	if err := json.Unmarshal(b, &pkg); err != nil {
		return ""
	}
	for _, n := range names {
		if v, ok := pkg.Scripts[n]; ok && strings.TrimSpace(v) != "" {
			return n
		}
	}
	return ""
}

// workHelp exists because `homelab work` and `homelab work --help` both printed
// `unknown command: "work"`, which reads as the verb not existing — the same
// class of mistake as bare `homelab tf`.
func workHelp(args []string) error {
	fmt.Println(`homelab work — one task, one worktree, one landing.

  homelab work start <topic>     fetch, create .worktrees/<topic> on <user>/<topic>,
                                 carry the git-crypt filter flags
  homelab work land [flags]      merge master in, verify, push HEAD:master, watch CI
                                 --verify-cmd "<cmd>"   what to run to verify
                                 --no-verify            land without verifying (deliberate)
  homelab work clean <topic>     remove the worktree and the branch

A repo that declares its checks in a .land-verify file at its root gets them on
every land, in place of --verify-cmd and --no-verify. Otherwise verification is
auto-detected from go.mod, Cargo.toml, pyproject.toml/pytest.ini/tox.ini, a
Makefile "test" target, or a package.json test script. Pass --verify-cmd when
your repo does not match one of those.`)
	return nil
}
