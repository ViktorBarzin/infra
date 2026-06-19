package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

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
