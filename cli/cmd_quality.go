package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// `homelab quality` measures whether a repo is getting easier to work in.
//
// Why a verb rather than a script. The same reason `homelab reflect` is one: a
// single measurement says a repo has two invisible coupling pairs, two say
// whether last month's work removed them, and the second run only happens if
// running it is one discoverable command. A script in docs/agents that nobody
// remembers is a study, not an instrument.
//
// What it measures and what it refuses to measure is in the monorepo README.
// The short version: summed cyclomatic complexity, the maintainability index
// and the SQALE debt ratio were each measured against line count on this
// monorepo on 2026-09-06 and each turned out to be line count wearing a hat, so
// they are refused by construction rather than merely unused. What survives
// reads git history and test execution instead of source text.
//
// The tooling is Python and lives in the MONOREPO, next to its committed
// history and beside session-reflection, which it mirrors. This verb is a thin
// driver so there is one place to change.
func qualityCommands() []Command {
	return []Command{
		{Path: []string{"quality"}, Tier: TierWrite,
			Summary: "measure whether a repo is getting easier to work in: quality [run|diff|history|gate] [repo...] (run records history + pushes metrics)",
			Run:     qualityRun},
	}
}

// qualityToolCandidates are where the monorepo may sit. ~/code is the usual
// layout; the second covers a workspace whose monorepo root is elsewhere.
func qualityToolCandidates() []string {
	home, _ := os.UserHomeDir()
	return []string{
		filepath.Join(home, "code", "docs", "agents", "code-quality", "quality.py"),
		filepath.Join(home, "docs", "agents", "code-quality", "quality.py"),
	}
}

func qualityToolPath() (string, error) {
	for _, p := range qualityToolCandidates() {
		if isFile(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("code-quality tooling not found (looked in %s) — "+
		"it lives in the monorepo at docs/agents/code-quality",
		strings.Join(qualityToolCandidates(), ", "))
}

func isQualitySub(s string) bool {
	switch s {
	case "run", "diff", "history", "gate":
		return true
	}
	return false
}

// looksLikePath keeps `homelab quality ~/code/infra` working. A first argument
// naming a directory is a repo to measure, not a mistyped subcommand, so it
// must not be rejected by the typo guard.
func looksLikePath(s string) bool {
	if strings.ContainsAny(s, "/.~") {
		return true
	}
	info, err := os.Stat(s)
	return err == nil && info.IsDir()
}

// validateQualityArgs rejects a typo rather than letting it fall through to the
// default. Bare `homelab quality` runs, which records a history entry and
// pushes metrics, and that is a surprising thing for a mistyped read command to
// do: `homelab quality histry` should say so rather than quietly measure.
func validateQualityArgs(args []string) error {
	if len(args) == 0 {
		return nil
	}
	first := args[0]
	if strings.HasPrefix(first, "-") || isQualitySub(first) || looksLikePath(first) {
		return nil
	}
	return fmt.Errorf("unknown subcommand %q — use run|diff|history|gate, or "+
		"pass a repo path (bare `homelab quality` measures the repo you are in)",
		first)
}

func qualityRun(args []string) error {
	tool, err := qualityToolPath()
	if err != nil {
		return err
	}
	if err := validateQualityArgs(args); err != nil {
		return err
	}
	// Bare, or naming only paths, means run.
	if len(args) == 0 || !isQualitySub(args[0]) {
		args = append([]string{"run"}, args...)
	}
	cmd := exec.Command("python3", append([]string{tool}, args...)...)
	cmd.Stdout, cmd.Stderr, cmd.Stdin = os.Stdout, os.Stderr, os.Stdin
	return cmd.Run()
}
