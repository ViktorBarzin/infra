package main

import (
	"strings"
	"testing"
	"time"
)

// Loki returns the most RECENT n lines, so a --limit that is reached silently
// narrows the window: a --since 96h query on a chatty stream can come back
// covering two minutes and look exactly like "nothing happened earlier".
// That is a wrong answer delivered confidently, which is worse than an error.
func TestTruncationNoteFiresWhenTheLimitIsReached(t *testing.T) {
	now := time.Now()
	oldest := now.Add(-3 * time.Minute)
	note := truncationNote(100, 100, oldest.UnixNano(), now.UnixNano(), 96*time.Hour)
	if note == "" {
		t.Fatal("hitting the limit must be reported")
	}
	for _, want := range []string{"--limit", "96h"} {
		if !strings.Contains(note, want) {
			t.Errorf("note should mention %q, got: %s", want, note)
		}
	}
	if !strings.Contains(note, "m") && !strings.Contains(note, "s") {
		t.Errorf("note should state the span actually covered, got: %s", note)
	}
}

// Under the limit, the window really was covered — saying otherwise would
// train people to ignore the warning.
func TestTruncationNoteSilentWhenUnderTheLimit(t *testing.T) {
	now := time.Now()
	if note := truncationNote(100, 42, now.Add(-90*time.Minute).UnixNano(), now.UnixNano(), 2*time.Hour); note != "" {
		t.Errorf("expected no note, got: %s", note)
	}
}

// Exactly at the limit with the full window covered is still worth flagging:
// there may be more lines just beyond the boundary.
func TestTruncationNoteHandlesNoLines(t *testing.T) {
	if note := truncationNote(100, 0, 0, 0, time.Hour); note != "" {
		t.Errorf("no lines means nothing to warn about, got: %s", note)
	}
}
