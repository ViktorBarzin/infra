package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLooksLikeSessionID(t *testing.T) {
	if !looksLikeSessionID("f98324f5-be96-48ba-a085-2e0c6a9cfbb5") {
		t.Error("a real session uuid should be recognised")
	}
	for _, name := range []string{"Hunter", "articulation-training", "Council-tax", ""} {
		if looksLikeSessionID(name) {
			t.Errorf("%q is a session NAME, not an id", name)
		}
	}
}

// The tmux-persist manifest is how a human name becomes a uuid; Claude's own
// transcripts know nothing about names.
func TestResolveNameFromManifest(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		"articulation-training\t/home/w/code\t056f7a82-c949-462d-8349-b0bd92a254f3\t1784478605\t1786726816",
		"Hunter\t/home/w\tc5301e63-7623-4a5b-9e11-2b7d9a6f1a22\t1786820000\t1786826000",
	}, "\n")
	if err := os.WriteFile(filepath.Join(dir, "wizard.history.tsv"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := resolveSessionName(dir, "Hunter")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got != "c5301e63-7623-4a5b-9e11-2b7d9a6f1a22" {
		t.Errorf("resolved to %q", got)
	}
}

// A name that matches nothing must say so, not resolve to something adjacent.
func TestResolveNameRejectsUnknown(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "wizard.history.tsv"),
		[]byte("Hunter\t/home/w\tc5301e63-7623-4a5b-9e11-2b7d9a6f1a22\t1\t2\n"), 0o644)

	if _, err := resolveSessionName(dir, "Hunte"); err == nil {
		t.Error("a partial name should not resolve — it would open the wrong conversation")
	}
}

// Names are only unique per user. Two people can both have a "notes" session,
// and silently picking one would show the wrong person's conversation.
func TestResolveNameReportsAmbiguity(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "wizard.history.tsv"),
		[]byte("notes\t/home/w\taaaaaaaa-0000-0000-0000-000000000001\t1\t2\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "emo.history.tsv"),
		[]byte("notes\t/home/e\tbbbbbbbb-0000-0000-0000-000000000002\t1\t2\n"), 0o644)

	_, err := resolveSessionName(dir, "notes")
	if err == nil {
		t.Fatal("an ambiguous name must not silently pick one")
	}
	if !strings.Contains(err.Error(), "wizard") || !strings.Contains(err.Error(), "emo") {
		t.Errorf("the error should name both candidates, got: %v", err)
	}
}

func TestRenderTranscriptShowsTheConversation(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "-home-x-code", "sess", []map[string]interface{}{
		{"type": "user", "timestamp": "2026-08-15T10:00:00Z",
			"message": map[string]interface{}{"role": "user", "content": "fix the auth bug"}},
		assistant("2026-08-15T10:00:05Z", "claude-opus-5", 10, 20, 0, "Bash", "Edit"),
		{"type": "assistant", "timestamp": "2026-08-15T10:00:09Z",
			"message": map[string]interface{}{"model": "claude-opus-5",
				"content": []interface{}{map[string]interface{}{"type": "text", "text": "Fixed it."}},
				"usage":   map[string]interface{}{"output_tokens": 3}}},
	})
	path := filepath.Join(home, ".claude", "projects", "-home-x-code", "sess.jsonl")

	out, err := renderTranscript(path, transcriptOpts{})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	for _, want := range []string{"fix the auth bug", "Fixed it.", "Bash", "Edit"} {
		if !strings.Contains(out, want) {
			t.Errorf("transcript is missing %q:\n%s", want, out)
		}
	}
}

// The user's own words are the point; a content array must not swallow them.
func TestRenderTranscriptHandlesBothContentShapes(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "p", "s", []map[string]interface{}{
		{"type": "user", "timestamp": "2026-08-15T10:00:00Z",
			"message": map[string]interface{}{"content": "plain string form"}},
		{"type": "user", "timestamp": "2026-08-15T10:01:00Z",
			"message": map[string]interface{}{"content": []interface{}{
				map[string]interface{}{"type": "text", "text": "array block form"}}}},
	})
	path := filepath.Join(home, ".claude", "projects", "p", "s.jsonl")

	out, err := renderTranscript(path, transcriptOpts{})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"plain string form", "array block form"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q from:\n%s", want, out)
		}
	}
}

// Tool traffic is the bulk of a session and can be enormous. It is summarised
// by default and only expanded on request.
func TestRenderTranscriptToolDetailIsOptIn(t *testing.T) {
	home := t.TempDir()
	big := strings.Repeat("x", 5000)
	writeTranscript(t, home, "p", "s", []map[string]interface{}{
		{"type": "assistant", "timestamp": "2026-08-15T10:00:00Z",
			"message": map[string]interface{}{"content": []interface{}{
				map[string]interface{}{"type": "tool_use", "name": "Bash",
					"input": map[string]interface{}{"command": big}}}}},
	})
	path := filepath.Join(home, ".claude", "projects", "p", "s.jsonl")

	brief, err := renderTranscript(path, transcriptOpts{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(brief, big) {
		t.Error("a 5000-char tool input should not appear in the default view")
	}
	if !strings.Contains(brief, "Bash") {
		t.Error("the tool NAME should still be shown by default")
	}

	full, err := renderTranscript(path, transcriptOpts{Tools: true, MaxToolChars: 100})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(full, "xxxx") {
		t.Error("--tools should show the input")
	}
	if strings.Contains(full, big) {
		t.Error("--tools output should still be bounded, not dump 5000 chars")
	}
}

func TestFindTranscriptAcrossProjects(t *testing.T) {
	home := t.TempDir()
	writeTranscript(t, home, "-proj-a", "aaaa1111-0000-0000-0000-000000000000", []map[string]interface{}{
		userTurn("2026-08-15T10:00:00Z"),
	})
	got, err := findTranscript([]userRoot{{User: "wizard", Home: home}}, "aaaa1111-0000-0000-0000-000000000000")
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if !strings.HasSuffix(got, "aaaa1111-0000-0000-0000-000000000000.jsonl") {
		t.Errorf("found %q", got)
	}
	if _, err := findTranscript([]userRoot{{User: "wizard", Home: home}}, "nope-0000-0000-0000-000000000000"); err == nil {
		t.Error("a missing session must be reported, not silently empty")
	}
}

// The manifest DIRECTORY is world-readable but the .tsv files inside are
// root-only, so an unprivileged run reads zero rows and would otherwise report
// "no session named X" -- the name does not exist, when in truth it could not
// look. Same silent-omission class as unreadable home directories.
func TestResolveNameDistinguishesUnreadableFromAbsent(t *testing.T) {
	dir := t.TempDir()
	secret := filepath.Join(dir, "wizard.history.tsv")
	if err := os.WriteFile(secret, []byte("Hunter\t/home/w\tc5301e63-7623-4a5b-9e11-2b7d9a6f1a22\t1\t2\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root — mode 0000 is still readable, so this cannot be exercised")
	}

	_, err := resolveSessionName(dir, "Hunter")
	if err == nil {
		t.Fatal("expected an error when the manifests cannot be read")
	}
	if !strings.Contains(err.Error(), "sudo") {
		t.Errorf("the error should say the manifests were unreadable and suggest sudo, got: %v", err)
	}
}
