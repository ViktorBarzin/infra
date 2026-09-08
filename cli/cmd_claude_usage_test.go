package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeTranscript lays down a Claude transcript in the on-disk layout the real
// ones use: ~/.claude/projects/<slug>/<session-uuid>.jsonl, one JSON object
// per line.
func writeTranscript(t *testing.T, home, project, session string, lines []map[string]interface{}) {
	t.Helper()
	dir := filepath.Join(home, ".claude", "projects", project)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	for _, l := range lines {
		enc, err := json.Marshal(l)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(enc)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(filepath.Join(dir, session+".jsonl"), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func assistant(ts string, model string, in, out, cacheRead int, tools ...string) map[string]interface{} {
	content := []interface{}{}
	for _, name := range tools {
		content = append(content, map[string]interface{}{"type": "tool_use", "name": name})
	}
	return map[string]interface{}{
		"type": "assistant", "timestamp": ts,
		"message": map[string]interface{}{
			"model": model, "content": content,
			"usage": map[string]interface{}{
				"input_tokens": in, "output_tokens": out,
				"cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": 0,
			},
		},
	}
}

func userTurn(ts string) map[string]interface{} {
	return map[string]interface{}{"type": "user", "timestamp": ts,
		"message": map[string]interface{}{"role": "user", "content": "do a thing"}}
}

func TestScanReportsPerUserTotals(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "-home-x-code", "s1", []map[string]interface{}{
		userTurn("2026-08-15T10:00:00Z"),
		assistant("2026-08-15T10:00:05Z", "claude-opus-5", 10, 20, 100, "Bash", "Read"),
		assistant("2026-08-15T10:00:09Z", "claude-opus-5", 5, 7, 50, "Bash"),
	})

	got, err := scanTranscripts([]userRoot{{User: "emo", Home: home}}, time.Time{})
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	u := got.Users["emo"]
	if u == nil {
		t.Fatal("no stats for emo")
	}
	if u.Sessions != 1 {
		t.Errorf("sessions = %d, want 1", u.Sessions)
	}
	if u.InputTokens != 15 || u.OutputTokens != 27 || u.CacheReadTokens != 150 {
		t.Errorf("tokens = in %d out %d cacheRead %d", u.InputTokens, u.OutputTokens, u.CacheReadTokens)
	}
	if u.Turns != 1 {
		t.Errorf("turns = %d, want 1 (one user message)", u.Turns)
	}
	if u.Tools["Bash"] != 2 || u.Tools["Read"] != 1 {
		t.Errorf("tools = %v, want Bash 2 / Read 1", u.Tools)
	}
	if u.Models["claude-opus-5"] != 2 {
		t.Errorf("models = %v", u.Models)
	}
}

// The comparison between users is the point, so one user's data must never be
// folded into another's.
func TestScanKeepsUsersSeparate(t *testing.T) {
	h1, h2 := t.TempDir(), t.TempDir()
	writeTranscript(t, h1, "p", "a", []map[string]interface{}{
		userTurn("2026-08-15T10:00:00Z"),
		assistant("2026-08-15T10:00:01Z", "claude-opus-5", 100, 10, 0, "Bash"),
	})
	writeTranscript(t, h2, "p", "b", []map[string]interface{}{
		userTurn("2026-08-15T11:00:00Z"),
		assistant("2026-08-15T11:00:01Z", "claude-opus-5", 1, 1, 0, "Edit"),
	})

	got, err := scanTranscripts([]userRoot{{User: "wizard", Home: h1}, {User: "emo", Home: h2}}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if got.Users["wizard"].InputTokens != 100 || got.Users["emo"].InputTokens != 1 {
		t.Errorf("totals bled between users: %+v", got.Users)
	}
	if got.Users["wizard"].Tools["Edit"] != 0 {
		t.Error("emo's tool call was counted against wizard")
	}
}

func TestScanHonoursSinceCutoff(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "p", "old", []map[string]interface{}{
		userTurn("2026-01-01T10:00:00Z"),
		assistant("2026-01-01T10:00:01Z", "claude-opus-5", 999, 999, 0, "Bash"),
	})
	writeTranscript(t, home, "p", "new", []map[string]interface{}{
		userTurn("2026-08-15T10:00:00Z"),
		assistant("2026-08-15T10:00:01Z", "claude-opus-5", 5, 5, 0, "Read"),
	})

	cutoff := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	got, err := scanTranscripts([]userRoot{{User: "emo", Home: home}}, cutoff)
	if err != nil {
		t.Fatal(err)
	}
	u := got.Users["emo"]
	if u.InputTokens != 5 {
		t.Errorf("cutoff not applied: input tokens = %d, want 5", u.InputTokens)
	}
	if u.Tools["Bash"] != 0 {
		t.Error("a pre-cutoff tool call was counted")
	}
}

// 1.2 GB of transcripts across 1359 files includes plenty that are truncated,
// half-written, or not what we expect. One bad line must never abort the run.
func TestScanSurvivesMalformedInput(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "projects", "p")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := strings.Join([]string{
		`{"type":"user","timestamp":"2026-08-15T10:00:00Z"}`,
		`{"type":"assistant","timestamp":"2026-08-15T10:00:01Z","message":{"model":"m","usage":{"input_tokens":3}}}`,
		`not json at all`,
		`{"type":"assistant"`,
		``,
		`{"type":"assistant","timestamp":"nonsense","message":{"usage":{"output_tokens":4}}}`,
	}, "\n")
	if err := os.WriteFile(filepath.Join(dir, "s.jsonl"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := scanTranscripts([]userRoot{{User: "emo", Home: home}}, time.Time{})
	if err != nil {
		t.Fatalf("a malformed line aborted the scan: %v", err)
	}
	if got.Users["emo"].InputTokens != 3 {
		t.Errorf("good lines were not counted: %+v", got.Users["emo"])
	}
	if got.Skipped == 0 {
		t.Error("malformed lines should be counted as skipped, not hidden")
	}
}

func TestScanIgnoresAnUnreadableHome(t *testing.T) {
	got, err := scanTranscripts([]userRoot{{User: "ghost", Home: "/nonexistent/nowhere"}}, time.Time{})
	if err != nil {
		t.Fatalf("a missing home should not fail the run: %v", err)
	}
	if len(got.Users) != 0 {
		t.Errorf("expected no users, got %+v", got.Users)
	}
}

func TestRenderReportNamesEveryUserAndIsReadable(t *testing.T) {
	rep := &usageReport{Users: map[string]*userStats{
		"wizard": {Sessions: 3, Turns: 9, InputTokens: 10, OutputTokens: 20,
			CacheReadTokens: 500, Tools: map[string]int{"Bash": 5}, Models: map[string]int{"claude-opus-5": 3}},
		"emo": {Sessions: 1, Turns: 2, InputTokens: 1, OutputTokens: 2,
			Tools: map[string]int{"Read": 1}, Models: map[string]int{"claude-opus-5": 1}},
	}}
	out := renderReport(rep)
	for _, want := range []string{"wizard", "emo", "Bash", "claude-opus-5", "Sessions"} {
		if !strings.Contains(out, want) {
			t.Errorf("report is missing %q:\n%s", want, out)
		}
	}
}

// Cache-read share is the efficiency number worth surfacing: it says how much
// context was reused rather than re-sent.
func TestCacheReadShare(t *testing.T) {
	u := &userStats{InputTokens: 100, CacheReadTokens: 900}
	if got := u.cacheReadShare(); got < 0.89 || got > 0.91 {
		t.Errorf("cacheReadShare = %v, want ~0.9", got)
	}
	empty := &userStats{}
	if got := empty.cacheReadShare(); got != 0 {
		t.Errorf("cacheReadShare on empty = %v, want 0 rather than NaN", got)
	}
}

// A --since window should not cost a full read of the corpus. A transcript's
// mtime is its last append, so a file older than the cutoff cannot contain a
// record inside the window and must be skipped unopened -- without this, a
// one-day query costs the same as a ninety-day one (measured: 35s over 1.2 GB),
// which reads as a hang.
func TestScanSkipsFilesOlderThanCutoff(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "p", "stale", []map[string]interface{}{
		userTurn("2026-01-01T10:00:00Z"),
		assistant("2026-01-01T10:00:01Z", "claude-opus-5", 500, 500, 0, "Bash"),
	})
	writeTranscript(t, home, "p", "fresh", []map[string]interface{}{
		userTurn("2026-08-15T10:00:00Z"),
		assistant("2026-08-15T10:00:01Z", "claude-opus-5", 7, 7, 0, "Read"),
	})

	old := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	stale := filepath.Join(home, ".claude", "projects", "p", "stale.jsonl")
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}

	cutoff := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	got, err := scanTranscripts([]userRoot{{User: "emo", Home: home}}, cutoff)
	if err != nil {
		t.Fatal(err)
	}
	if got.Files != 1 {
		t.Errorf("opened %d files, want 1 — the stale one should be skipped by mtime", got.Files)
	}
	if got.Users["emo"].InputTokens != 7 {
		t.Errorf("wrong totals after skipping: %+v", got.Users["emo"])
	}
}
