package main

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// `homelab work land` on tripit reported "CI did not go green: timed out after
// 20m0s" on 2026-09-04 while the build had in fact succeeded on GitHub Actions.
// Two separate faults hid behind that one message, and they want opposite fixes:
// a pipeline that is RUNNING should be waited on for as long as it takes, while
// a pipeline that never APPEARS must not wedge the caller forever.
func TestCIWaitPolicy(t *testing.T) {
	const grace = 10 * time.Minute
	cases := []struct {
		name   string
		policy ciWaitPolicy
		seen   bool
		waited time.Duration
		want   ciWaitDecision
	}{
		{
			"a running pipeline is waited on for as long as it takes",
			ciWaitPolicy{appearGrace: grace, runTimeout: 0},
			true, 9 * time.Hour, ciKeepWaiting,
		},
		{
			"the appearance grace does not apply once a pipeline is seen",
			ciWaitPolicy{appearGrace: grace, runTimeout: 0},
			true, grace + time.Minute, ciKeepWaiting,
		},
		{
			"no pipeline yet, still inside the grace",
			ciWaitPolicy{appearGrace: grace, runTimeout: 0},
			false, grace - time.Second, ciKeepWaiting,
		},
		{
			"no pipeline after the grace is a missing pipeline, not a failed build",
			ciWaitPolicy{appearGrace: grace, runTimeout: 0},
			false, grace, ciGiveUpNoPipeline,
		},
		{
			"an explicit --timeout still bounds a running pipeline",
			ciWaitPolicy{appearGrace: grace, runTimeout: 30 * time.Minute},
			true, 30 * time.Minute, ciGiveUpTimeout,
		},
		{
			"under an explicit --timeout it keeps waiting",
			ciWaitPolicy{appearGrace: grace, runTimeout: 30 * time.Minute},
			true, 29 * time.Minute, ciKeepWaiting,
		},
	}
	for _, c := range cases {
		if got := c.policy.decide(c.seen, c.waited); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// The default must be "wait as long as it takes" (Viktor, 2026-09-04): a build
// slower than the old fixed 20m was reported as a CI failure when nothing had
// failed.
func TestDefaultCIWaitPolicyHasNoRunTimeout(t *testing.T) {
	p := defaultCIWaitPolicy()
	if p.runTimeout != 0 {
		t.Errorf("default runTimeout should be 0 (unbounded), got %s", p.runTimeout)
	}
	if p.appearGrace <= 0 {
		t.Errorf("appearGrace must stay bounded, got %s", p.appearGrace)
	}
	if got := p.decide(true, 24*time.Hour); got != ciKeepWaiting {
		t.Errorf("a day-old running pipeline should still be waited on, got %v", got)
	}
}

func TestParseCIWaitFlags(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		wantRun    time.Duration
		wantAppear time.Duration
	}{
		{"defaults", nil, 0, 10 * time.Minute},
		{"explicit timeout", []string{"--timeout", "45m"}, 45 * time.Minute, 10 * time.Minute},
		{"equals form", []string{"--timeout=2h"}, 2 * time.Hour, 10 * time.Minute},
		{"appear grace", []string{"--appear-grace", "30s"}, 0, 30 * time.Second},
		{"zero means unbounded", []string{"--timeout", "0"}, 0, 10 * time.Minute},
	}
	for _, c := range cases {
		p, err := parseCIWaitFlags(c.args)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if p.runTimeout != c.wantRun {
			t.Errorf("%s: runTimeout got %s want %s", c.name, p.runTimeout, c.wantRun)
		}
		if p.appearGrace != c.wantAppear {
			t.Errorf("%s: appearGrace got %s want %s", c.name, p.appearGrace, c.wantAppear)
		}
	}
	if _, err := parseCIWaitFlags([]string{"--timeout", "soon"}); err == nil {
		t.Error("an unparseable duration must be an error, not a silent default")
	}
}

// `work land` on tripit printed "landed, but CI did not go green" when nothing
// had gone red — the repo simply has no Woodpecker pipeline for a pushed
// commit. Landing had already succeeded, so a missing pipeline is a note; a
// genuine red build is still an error.
func TestLandCIOutcome(t *testing.T) {
	note, fatal := landCIOutcome(nil)
	if note != "" || fatal != nil {
		t.Errorf("green CI should be silent, got note=%q fatal=%v", note, fatal)
	}

	missing := fmt.Errorf("%w (waited 10m0s for abc1234)", errNoCIPipeline)
	note, fatal = landCIOutcome(missing)
	if fatal != nil {
		t.Errorf("a missing pipeline must not fail the land, got %v", fatal)
	}
	if note == "" || !strings.Contains(note, "no Woodpecker pipeline") {
		t.Errorf("a missing pipeline should be reported as a note, got %q", note)
	}

	red := errors.New("pipeline #12 failure (woodpecker repo, see UI/DB for the failing step)")
	if _, fatal = landCIOutcome(red); fatal == nil {
		t.Error("a red pipeline must still fail the land")
	}
}

// `work land` takes flags of its own, so only the wait-tuning ones may reach
// the watch. Forwarding --verify-cmd's value would be read as a commit.
func TestCIWaitArgsForwardsOnlyWaitFlags(t *testing.T) {
	cases := []struct {
		name string
		in   []string
		want []string
	}{
		{"nothing to forward", []string{"--verify-cmd", "go test ./..."}, nil},
		{"spaced timeout", []string{"--verify-cmd", "make", "--timeout", "45m"}, []string{"--timeout", "45m"}},
		{"equals form", []string{"--timeout=2h"}, []string{"--timeout=2h"}},
		{"appear grace", []string{"--appear-grace", "30s"}, []string{"--appear-grace", "30s"}},
		{"both", []string{"--timeout", "1h", "--appear-grace=5m"}, []string{"--timeout", "1h", "--appear-grace=5m"}},
		{
			"a verify command that mentions the flag name is not a flag",
			[]string{"--verify-cmd", "--timeout"},
			nil,
		},
		{
			"nor when that verify value is followed by a real duration",
			[]string{"--verify-cmd", "--timeout", "45m"},
			nil,
		},
		{
			"a real flag after a skipped verify value is still forwarded",
			[]string{"--verify-cmd", "make", "--appear-grace", "5m"},
			[]string{"--appear-grace", "5m"},
		},
		{"dangling flag with no value is dropped, not half-forwarded", []string{"--timeout"}, nil},
	}
	for _, c := range cases {
		got := ciWaitArgs(c.in)
		if len(got) != len(c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s: got %v, want %v", c.name, got, c.want)
				break
			}
		}
	}
}
