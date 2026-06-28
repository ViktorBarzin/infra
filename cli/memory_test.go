package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestTruncatePreviewKeepsValidUTF8(t *testing.T) {
	// Byte-slicing a long Cyrillic string at 240 splits a 2-byte rune and emits
	// invalid UTF-8 — the bug that crashed the recall hook. truncatePreview must
	// cut on a rune boundary and always stay valid UTF-8.
	long := strings.Repeat("я", 300) // 300 runes / 600 bytes
	got := truncatePreview(long, 240)
	if !utf8.ValidString(got) {
		t.Fatalf("truncatePreview produced invalid UTF-8: %q", got)
	}
	if r := []rune(got); len(r) != 241 || string(r[:240]) != strings.Repeat("я", 240) || r[240] != '…' {
		t.Fatalf("truncatePreview = %d runes, want 240 Cyrillic + ellipsis", len(r))
	}
	// Short multibyte strings pass through untouched (no ellipsis).
	if got := truncatePreview("кратко", 240); got != "кратко" {
		t.Fatalf("short string altered: %q", got)
	}
	// ASCII boundary still works.
	if got := truncatePreview(strings.Repeat("a", 500), 240); got != strings.Repeat("a", 240)+"…" {
		t.Fatalf("ascii truncation wrong: %q", got)
	}
}

func TestResolveMemoryBase(t *testing.T) {
	old1, old2 := os.Getenv("CLAUDE_MEMORY_API_URL"), os.Getenv("MEMORY_API_URL")
	defer func() { os.Setenv("CLAUDE_MEMORY_API_URL", old1); os.Setenv("MEMORY_API_URL", old2) }()

	os.Unsetenv("CLAUDE_MEMORY_API_URL")
	os.Unsetenv("MEMORY_API_URL")
	if got := resolveMemoryBase(); got != defaultMemoryURL {
		t.Errorf("resolveMemoryBase() = %q, want default %q", got, defaultMemoryURL)
	}
	os.Setenv("CLAUDE_MEMORY_API_URL", "https://m.example/") // trailing slash trimmed
	if got := resolveMemoryBase(); got != "https://m.example" {
		t.Errorf("resolveMemoryBase() = %q, want https://m.example", got)
	}
}

func TestMemStoreReqAlwaysSendsImportance(t *testing.T) {
	b, _ := json.Marshal(memStoreReq{Content: "x", Category: "facts", Importance: 0.5})
	s := string(b)
	if !strings.Contains(s, `"content":"x"`) || !strings.Contains(s, `"importance":0.5`) {
		t.Fatalf("memStoreReq JSON missing fields: %s", s)
	}
}

func TestMemUpdateReqOmitsUnsetFields(t *testing.T) {
	tags := "a,b"
	b, _ := json.Marshal(memUpdateReq{Tags: &tags})
	s := string(b)
	if strings.Contains(s, "content") || strings.Contains(s, "importance") {
		t.Fatalf("unset update fields must be omitted: %s", s)
	}
	if !strings.Contains(s, `"tags":"a,b"`) {
		t.Fatalf("set field missing: %s", s)
	}
}

func TestMemRecallReqOmitsEmptyOptionals(t *testing.T) {
	b, _ := json.Marshal(memRecallReq{Context: "hi"})
	s := string(b)
	if strings.Contains(s, "expanded_query") || strings.Contains(s, "category") || strings.Contains(s, "limit") {
		t.Fatalf("empty optionals must be omitted: %s", s)
	}
}
