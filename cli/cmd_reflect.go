package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// `homelab reflect` drives the session-reflection study: the deterministic
// detectors that measure how often we reach past our own tooling.
//
// Why a verb rather than a script anyone can run. The study exists to be
// re-run — a single measurement says "we hand-roll 1,789 sleeps", two say
// "the reword worked". A run has to be one discoverable command, findable
// through `homelab how` and reachable by any agent, or the periodic part
// quietly stops happening. That is the same failure the study itself measured.
//
// The tooling is Python and lives in the MONOREPO (it reads ~/.claude
// transcripts and its history is committed next to the findings), so this verb
// is a thin driver rather than a reimplementation. One place to change.
func reflectCommands() []Command {
	return []Command{
		{Path: []string{"reflect"}, Tier: TierWrite,
			Summary: "measure how often we reach past our own tooling: reflect [run|diff|history] (run records history + pushes metrics)",
			Run:     reflectRun},
	}
}

// reflectToolCandidates are where the monorepo may sit. ~/code is the usual
// layout; the second covers a workspace whose monorepo root is elsewhere.
func reflectToolCandidates() []string {
	home, _ := os.UserHomeDir()
	return []string{
		filepath.Join(home, "code", "docs", "agents", "session-reflection", "reflect.py"),
		filepath.Join(home, "docs", "agents", "session-reflection", "reflect.py"),
	}
}

func reflectToolPath() (string, error) {
	for _, p := range reflectToolCandidates() {
		if isFile(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("session-reflection tooling not found (looked in %s) — "+
		"it lives in the monorepo at docs/agents/session-reflection",
		strings.Join(reflectToolCandidates(), ", "))
}

// validateReflectSub rejects a typo rather than letting it fall through to the
// default. `run` records a history entry, pushes metrics and stores a memory,
// which is a surprising thing for a mistyped read command to do.
func validateReflectSub(sub string) error {
	switch sub {
	case "", "run", "diff", "history":
		return nil
	}
	return fmt.Errorf("unknown subcommand %q — use run|diff|history "+
		"(bare `homelab reflect` runs)", sub)
}

func reflectRun(args []string) error {
	tool, err := reflectToolPath()
	if err != nil {
		return err
	}
	sub := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		sub = args[0]
	}
	if err := validateReflectSub(sub); err != nil {
		return err
	}
	if sub == "" {
		args = append([]string{"run"}, args...)
	}
	cmd := exec.Command("python3", append([]string{tool}, args...)...)
	cmd.Stdout, cmd.Stderr, cmd.Stdin = os.Stdout, os.Stderr, os.Stdin
	return cmd.Run()
}
