package main

import (
	"strings"
	"testing"
	"time"
)

// The 2026-08-31 session study measured 30 attempts across 17 sessions where the
// question could not be expressed in these verbs, so Claude reverse-engineered
// the Loki/Prometheus endpoint and wrote curl instead. That partly undercut the
// 2026-08-15 rule fix: the rule successfully sent Claude to the verb, then the
// verb could not answer.
//
// Three concrete gaps, each with its own measured count:
//   * `--since 7d` was typed 19 times and rejected every time (time.ParseDuration
//     knows no unit above h). 40 such failures across 17 sessions, 24 of them
//     AFTER the rule fix landed.
//   * `metrics query` had no time flag at all, so "has this changed since the
//     deploy" was unaskable.
//   * there was no label-value lookup, which is what you need after a
//     zero-result query to find out what the stream is actually called.

func TestParseWindowAcceptsDaysAndWeeks(t *testing.T) {
	cases := map[string]time.Duration{
		"30s": 30 * time.Second,
		"15m": 15 * time.Minute,
		"1h":  time.Hour,
		"24h": 24 * time.Hour,
		"7d":  7 * 24 * time.Hour,
		"1d":  24 * time.Hour,
		"2w":  14 * 24 * time.Hour,
		"90d": 90 * 24 * time.Hour,
		// Compound forms Go already understands must keep working.
		"1h30m": 90 * time.Minute,
	}
	for in, want := range cases {
		got, err := parseWindow(in)
		if err != nil {
			t.Errorf("parseWindow(%q) errored: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("parseWindow(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestParseWindowRejectsGarbageWithAUsefulMessage(t *testing.T) {
	for _, in := range []string{"", "yesterday", "7", "d7", "1y", "-3d"} {
		_, err := parseWindow(in)
		if err == nil {
			t.Errorf("parseWindow(%q) should error", in)
			continue
		}
		// The message must name what IS accepted; a bare ParseDuration error
		// ("unknown unit") is what sent Claude to curl in the first place.
		if !strings.Contains(err.Error(), "s/m/h/d/w") {
			t.Errorf("parseWindow(%q) error should list accepted units, got %q", in, err)
		}
	}
}

func TestParseInstantAcceptsRFC3339AndEpoch(t *testing.T) {
	ts, err := parseInstant("2026-08-15T22:54:54Z")
	if err != nil {
		t.Fatalf("RFC3339: %v", err)
	}
	if ts.UTC().Format(time.RFC3339) != "2026-08-15T22:54:54Z" {
		t.Errorf("got %v", ts.UTC())
	}
	ts2, err := parseInstant("@1755298494")
	if err != nil {
		t.Fatalf("epoch: %v", err)
	}
	if ts2.Unix() != 1755298494 {
		t.Errorf("epoch parsed to %d", ts2.Unix())
	}
	// A relative form is the shape actually typed mid-investigation.
	ts3, err := parseInstant("-2h")
	if err != nil {
		t.Fatalf("relative: %v", err)
	}
	if d := time.Since(ts3); d < 119*time.Minute || d > 121*time.Minute {
		t.Errorf("relative -2h resolved to %v ago", d)
	}
	if _, err := parseInstant("teatime"); err == nil {
		t.Error("garbage should error")
	}
}

func TestResolveRangeDefaultsAndExplicitBounds(t *testing.T) {
	// Default: no flags at all -> the documented 1h window ending now.
	r, err := resolveRange(nil, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if d := r.End.Sub(r.Start); d < 59*time.Minute || d > 61*time.Minute {
		t.Errorf("default window %v, want ~1h", d)
	}
	if r.Instant {
		t.Error("default should not be an instant query")
	}

	// --since alone still works, in days now.
	r, err = resolveRange([]string{"--since", "7d"}, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if d := r.End.Sub(r.Start); d < 167*time.Hour || d > 169*time.Hour {
		t.Errorf("--since 7d window %v", d)
	}

	// --at makes it an instant query at a past moment.
	r, err = resolveRange([]string{"--at", "2026-08-15T22:54:54Z"}, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Instant {
		t.Error("--at should be an instant query")
	}
	if r.At.UTC().Format(time.RFC3339) != "2026-08-15T22:54:54Z" {
		t.Errorf("--at resolved to %v", r.At.UTC())
	}

	// --start/--end give an explicit range.
	r, err = resolveRange([]string{"--start", "2026-08-15T00:00:00Z", "--end", "2026-08-16T00:00:00Z"}, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if d := r.End.Sub(r.Start); d != 24*time.Hour {
		t.Errorf("explicit range %v, want 24h", d)
	}

	// --step rides along for a range query.
	r, err = resolveRange([]string{"--since", "6h", "--step", "5m"}, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if r.Step != 5*time.Minute {
		t.Errorf("step %v", r.Step)
	}
}

func TestResolveRangeRejectsContradictoryFlags(t *testing.T) {
	// Silently picking a winner is how you get a confidently wrong answer.
	for _, args := range [][]string{
		{"--at", "-1h", "--since", "6h"},
		{"--at", "-1h", "--start", "2026-08-15T00:00:00Z"},
		{"--since", "6h", "--start", "2026-08-15T00:00:00Z"},
		{"--end", "2026-08-16T00:00:00Z"}, // --end without --start
	} {
		if _, err := resolveRange(args, time.Hour); err == nil {
			t.Errorf("args %v should be rejected", args)
		}
	}
	// start after end is a user error worth naming, not a silent empty result.
	if _, err := resolveRange([]string{"--start", "2026-08-16T00:00:00Z", "--end", "2026-08-15T00:00:00Z"}, time.Hour); err == nil {
		t.Error("start after end should be rejected")
	}
}

func TestZeroResultHintNamesTheLabelLookup(t *testing.T) {
	// After a zero-line result the next question is always "what is the stream
	// actually called". Before this, that meant reading the endpoint by hand.
	h := zeroResultHint(`{job="devvm-journal"} |= "oom"`)
	for _, want := range []string{"homelab logs labels", "0 lines"} {
		if !strings.Contains(h, want) {
			t.Errorf("hint missing %q:\n%s", want, h)
		}
	}
	// A wide selector is the other common cause and deserves naming.
	wide := zeroResultHint(`{job=~".+"} |= "thing"`)
	if !strings.Contains(strings.ToLower(wide), "wide") {
		t.Errorf("a catch-all selector should be called out:\n%s", wide)
	}
	// The hint must actively disclaim the absence inference rather than let the
	// reader draw it. A zero-line result reported as "it did not happen" is how
	// a wrong negative becomes a finding.
	if !strings.Contains(strings.ToLower(h), "not the same as") {
		t.Errorf("hint must disclaim the absence inference:\n%s", h)
	}
}
