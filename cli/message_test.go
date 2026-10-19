package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseMessageArgs(t *testing.T) {
	t.Run("send with flags and text", func(t *testing.T) {
		o, err := parseMessageArgs("send", []string{"--to", "Anca Milea", "running", "10", "late"})
		if err != nil {
			t.Fatal(err)
		}
		if o.to != "Anca Milea" {
			t.Errorf("to = %q", o.to)
		}
		if o.text != "running 10 late" {
			t.Errorf("text = %q", o.text)
		}
		if o.via != "wa" {
			t.Errorf("default via = %q, want wa", o.via)
		}
	})
	t.Run("flags with equals and dry-run/yes", func(t *testing.T) {
		o, err := parseMessageArgs("send", []string{"--to=Bob", "--dry-run", "--yes", "hi"})
		if err != nil {
			t.Fatal(err)
		}
		if o.to != "Bob" || !o.dryRun || !o.yes || o.text != "hi" {
			t.Errorf("%+v", o)
		}
	})
	t.Run("read limit default and override", func(t *testing.T) {
		o, _ := parseMessageArgs("read", []string{"--to", "X"})
		if o.limit != 20 {
			t.Errorf("default limit = %d, want 20", o.limit)
		}
		o, _ = parseMessageArgs("read", []string{"--to", "X", "--limit", "5"})
		if o.limit != 5 {
			t.Errorf("limit = %d, want 5", o.limit)
		}
	})
	t.Run("unknown flag errors", func(t *testing.T) {
		if _, err := parseMessageArgs("send", []string{"--nope"}); err == nil {
			t.Error("expected error for --nope")
		}
	})
	t.Run("bad limit errors", func(t *testing.T) {
		if _, err := parseMessageArgs("read", []string{"--limit", "abc"}); err == nil {
			t.Error("expected error for non-int limit")
		}
	})
}

func TestBuildAuditRecord(t *testing.T) {
	r := buildAuditRecord("2026-07-20T19:00:00Z", "wa", "send", "Anca Milea", "hello there", "sent")
	if r.Chars != 11 {
		t.Errorf("chars = %d, want 11", r.Chars)
	}
	if len(r.SHA8) != 8 {
		t.Errorf("sha8 = %q", r.SHA8)
	}
	if r.Preview != "hello there" {
		t.Errorf("preview = %q", r.Preview)
	}
	// determinism of the hash
	r2 := buildAuditRecord("later", "wa", "send", "X", "hello there", "sent")
	if r.SHA8 != r2.SHA8 {
		t.Errorf("sha8 not deterministic on text: %q vs %q", r.SHA8, r2.SHA8)
	}
	// long preview truncates with ellipsis
	long := strings.Repeat("x", 100)
	rl := buildAuditRecord("t", "wa", "send", "X", long, "sent")
	if !strings.HasSuffix(rl.Preview, "…") || len([]rune(rl.Preview)) != 61 {
		t.Errorf("preview truncation wrong: %d runes", len([]rune(rl.Preview)))
	}
	// serializes to one JSON line
	ln, err := r.line()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(ln, "\n") {
		t.Error("audit line must be single-line")
	}
	var back auditRecord
	if err := json.Unmarshal([]byte(ln), &back); err != nil {
		t.Fatalf("round-trip: %v", err)
	}
	if back.To != "Anca Milea" {
		t.Errorf("round-trip to = %q", back.To)
	}
}

// A delegation is a multi-line message, and Enter alone sends in WhatsApp
// Web, so the automation must type newlines as Shift+Enter.
func TestMessageWATypesNewlineAsShiftEnter(t *testing.T) {
	if !strings.Contains(messageWAJS, `if (ch === '\n') await page.keyboard.press('Shift+Enter');`) {
		t.Error("message_wa.js typeHuman no longer types a newline as Shift+Enter")
	}
}
