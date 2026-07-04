package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestRenderMemoriesFullContent(t *testing.T) {
	// The pretty view must NOT truncate content: the old 240-rune preview cut
	// memories mid-sentence, misled agents into thinking no full-content
	// read-back existed, and made blind `update --content` from the preview
	// destroy the stored tail. Full passthrough also removes the mid-rune-cut
	// invalid-UTF-8 class by construction — nothing is ever sliced.
	long := strings.Repeat("я", 300) + strings.Repeat("a", 300)
	raw, _ := json.Marshal(map[string]interface{}{"memories": []map[string]interface{}{
		{"id": 7, "content": long, "category": "facts", "tags": "t1,t2", "importance": 0.7},
	}})
	got := renderMemories(raw, false)
	if !strings.Contains(got, long) {
		t.Fatalf("content was truncated: %q", got)
	}
	if strings.Contains(got, "…") {
		t.Fatalf("ellipsis in output — truncation still active: %q", got)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("invalid UTF-8 in output: %q", got)
	}
	if !strings.Contains(got, "#7 [facts] (0.70) ") || !strings.Contains(got, "tags: t1,t2") {
		t.Fatalf("line format broken: %q", got)
	}
}

func TestRenderMemoriesFlattensNewlinesToOneLine(t *testing.T) {
	// Consumers (the recall hook, terminal skims) rely on one memory per line;
	// multi-line content is flattened, never split across lines.
	raw, _ := json.Marshal(map[string]interface{}{"memories": []map[string]interface{}{
		{"id": 1, "content": "line one\nline two\nline three", "category": "facts", "importance": 0.5},
	}})
	got := renderMemories(raw, false)
	if !strings.Contains(got, "line one line two line three") {
		t.Fatalf("newlines not flattened: %q", got)
	}
}

func TestRenderMemoriesEdgeCases(t *testing.T) {
	if got := renderMemories([]byte(`{"memories":[]}`), false); got != "(no memories)\n" {
		t.Fatalf("empty list: %q", got)
	}
	// --json and unparseable responses pass through raw.
	if got := renderMemories([]byte(`{"x":1}`), true); got != "{\"x\":1}\n" {
		t.Fatalf("json passthrough: %q", got)
	}
	if got := renderMemories([]byte(`not json`), false); got != "not json\n" {
		t.Fatalf("unparseable passthrough: %q", got)
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
