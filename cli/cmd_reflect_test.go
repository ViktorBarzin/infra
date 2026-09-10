package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// `homelab reflect` drives the session-reflection tooling that lives in the
// MONOREPO, not in this repo. The verb exists so a periodic run is one
// discoverable command instead of three scripts and a remembered path — and so
// another agent can find it via `homelab how`.
func TestReflectToolCandidatesAreWellFormed(t *testing.T) {
	// Deliberately NOT asserting the file exists: infra CI runs on GitHub
	// Actions where the monorepo is not checked out at all, and coupling this
	// suite to another repo's working tree would make it fail for a reason
	// that has nothing to do with the CLI.
	cands := reflectToolCandidates()
	if len(cands) == 0 {
		t.Fatal("no candidate paths")
	}
	for _, c := range cands {
		if filepath.Base(c) != "reflect.py" {
			t.Errorf("candidate %q should end in reflect.py", c)
		}
		if !filepath.IsAbs(c) {
			t.Errorf("candidate %q should be absolute", c)
		}
	}
}

func TestReflectToolPathErrorNamesWhereItLooked(t *testing.T) {
	// When it is genuinely missing the error has to say where to put it,
	// otherwise the verb is a dead end.
	if _, err := reflectToolPath(); err != nil {
		if !strings.Contains(err.Error(), "docs/agents/session-reflection") {
			t.Errorf("error should name the expected location, got %q", err)
		}
	} else {
		t.Log("tooling present on this box; the missing-path branch is untested here")
	}
}

func TestReflectSubcommandValidation(t *testing.T) {
	// A typo must not silently become `run`, which records history and pushes
	// metrics — a surprising side effect for a mistyped read command.
	for _, bad := range []string{"runn", "hisory", "show"} {
		if err := validateReflectSub(bad); err == nil {
			t.Errorf("%q should be rejected", bad)
		} else if !strings.Contains(err.Error(), "run|diff|history") {
			t.Errorf("%q error should list the valid subcommands, got %q", bad, err)
		}
	}
	for _, ok := range []string{"run", "diff", "history", ""} {
		if err := validateReflectSub(ok); err != nil {
			t.Errorf("%q should be accepted: %v", ok, err)
		}
	}
}
