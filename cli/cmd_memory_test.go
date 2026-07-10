package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newMemTestServer points the memory client at an httptest server for the
// duration of one test (the client resolves base URL + key from env).
func newMemTestServer(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	t.Setenv("CLAUDE_MEMORY_API_URL", srv.URL)
	t.Setenv("MEMORY_API_URL", "")
	t.Setenv("CLAUDE_MEMORY_API_KEY", "test-key")
	return srv
}

func TestRenderMemoryGetHumanOutput(t *testing.T) {
	// `memory get` is the read-one-full-entry verb (ADR-0007): full content
	// (verbatim, multi-line — never flattened like list/recall), metadata, then
	// links one per line: "-> <type> #<id>" outgoing, "<- <type> #<id>" incoming.
	raw, _ := json.Marshal(map[string]interface{}{
		"id": 6775, "content": "root cause line one\nline two", "category": "gotchas",
		"tags": "dns,nvidia", "importance": 0.8, "owner": "wizard",
		"created_at": "2026-07-09T10:00:00", "updated_at": "2026-07-10T11:00:00",
		"links_out": []map[string]interface{}{{"type": "supersedes", "target_id": 274}},
		"links_in": []map[string]interface{}{
			{"type": "part-of", "source_id": 123},
			{"type": "resolved-by", "source_id": 5972},
		},
	})
	got := renderMemory(raw, false)
	if !strings.Contains(got, "#6775 [gotchas] (0.80)") {
		t.Fatalf("missing header line: %q", got)
	}
	if !strings.Contains(got, "root cause line one\nline two") {
		t.Fatalf("content must be full and multi-line, not flattened: %q", got)
	}
	for _, want := range []string{"tags: dns,nvidia", "owner: wizard", "created: 2026-07-09T10:00:00", "updated: 2026-07-10T11:00:00"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing metadata %q in %q", want, got)
		}
	}
	for _, want := range []string{"-> supersedes #274", "<- part-of #123", "<- resolved-by #5972"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing link line %q in %q", want, got)
		}
	}
}

func TestRenderMemoryGetEdgeCases(t *testing.T) {
	// --json and unparseable responses pass through raw (same contract as
	// renderMemories); no links → no arrow lines.
	if got := renderMemory([]byte(`{"id":1}`), true); got != "{\"id\":1}\n" {
		t.Fatalf("json passthrough: %q", got)
	}
	if got := renderMemory([]byte(`not json`), false); got != "not json\n" {
		t.Fatalf("unparseable passthrough: %q", got)
	}
	raw, _ := json.Marshal(map[string]interface{}{
		"id": 2, "content": "bare", "category": "facts", "importance": 0.5,
	})
	got := renderMemory(raw, false)
	if strings.Contains(got, "->") || strings.Contains(got, "<-") {
		t.Fatalf("no links stored, no arrow lines expected: %q", got)
	}
}

func TestMemoryGetHitsGetEndpoint(t *testing.T) {
	var gotPath, gotAuth, gotMethod string
	newMemTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth, gotMethod = r.URL.Path, r.Header.Get("Authorization"), r.Method
		w.Write([]byte(`{"id":6775,"content":"x","category":"facts","importance":0.5,"links_out":[],"links_in":[]}`))
	}))
	if err := memoryGet([]string{"6775"}); err != nil {
		t.Fatalf("memoryGet: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/api/memories/6775" {
		t.Fatalf("want GET /api/memories/6775, got %s %s", gotMethod, gotPath)
	}
	if gotAuth != "Bearer test-key" {
		t.Fatalf("auth header = %q", gotAuth)
	}
}

func TestMemoryGetRequiresID(t *testing.T) {
	if err := memoryGet([]string{}); err == nil || !strings.Contains(err.Error(), "usage:") {
		t.Fatalf("get without id should print usage, got %v", err)
	}
	if err := memoryGet([]string{"--json"}); err == nil {
		t.Fatalf("get with only flags should error")
	}
}
