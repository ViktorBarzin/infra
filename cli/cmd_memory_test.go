package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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
	// links_out/links_in entries are keyed {"id": <otherEnd>, "type": ...} —
	// the landed server shape (claude-memory-mcp api/app.py get_memory).
	raw, _ := json.Marshal(map[string]interface{}{
		"id": 6775, "content": "root cause line one\nline two", "category": "gotchas",
		"tags": "dns,nvidia", "importance": 0.8, "owner": "wizard",
		"created_at": "2026-07-09T10:00:00", "updated_at": "2026-07-10T11:00:00",
		"links_out": []map[string]interface{}{{"type": "supersedes", "id": 274}},
		"links_in": []map[string]interface{}{
			{"type": "part-of", "id": 123},
			{"type": "resolved-by", "id": 5972},
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

func TestRenderMemoryToleratesLegacyEndKeys(t *testing.T) {
	// otherEnd tolerance: entries keyed target_id (out) / source_id (in) must
	// still render the right end — never "#0" — if the server shape drifts.
	raw, _ := json.Marshal(map[string]interface{}{
		"id": 1, "content": "x", "category": "facts", "importance": 0.5,
		"links_out": []map[string]interface{}{{"type": "supersedes", "target_id": 274}},
		"links_in":  []map[string]interface{}{{"type": "part-of", "source_id": 123}},
	})
	got := renderMemory(raw, false)
	for _, want := range []string{"-> supersedes #274", "<- part-of #123"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing link line %q in %q", want, got)
		}
	}
	if strings.Contains(got, "#0") {
		t.Fatalf("a link line rendered as #0 — end-key tolerance broken: %q", got)
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

func TestParseLinkSpec(t *testing.T) {
	// The link vocabulary is a CLOSED enum of four (ADR-0007 — the
	// category-drift lesson: free vocabularies rot). id must be an integer.
	for _, tc := range []struct{ in, wantType string; wantID int }{
		{"part-of:123", "part-of", 123},
		{"supersedes:274", "supersedes", 274},
		{"see-also:9", "see-also", 9},
		{"resolved-by:6775", "resolved-by", 6775},
	} {
		got, err := parseLinkSpec(tc.in)
		if err != nil {
			t.Errorf("parseLinkSpec(%q): unexpected err %v", tc.in, err)
			continue
		}
		if got.Type != tc.wantType || got.TargetID != tc.wantID {
			t.Errorf("parseLinkSpec(%q) = %+v, want %s:%d", tc.in, got, tc.wantType, tc.wantID)
		}
	}
	for _, bad := range []string{"parent-of:5", "PART-OF:5", "part-of", "part-of:", "part-of:abc", "part-of:1.5", "see-also:-2", ":5", ""} {
		if _, err := parseLinkSpec(bad); err == nil {
			t.Errorf("parseLinkSpec(%q) should be rejected", bad)
		}
	}
}

// memAPIRecorder captures every request the CLI makes so tests can assert on
// method/path/body sequences.
type memAPIRecorder struct {
	mu       sync.Mutex
	reqs     []recordedReq
	linkFail bool // 500 every /links POST/DELETE
}

type recordedReq struct {
	method, path, body string
}

func (rec *memAPIRecorder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	rec.mu.Lock()
	rec.reqs = append(rec.reqs, recordedReq{r.Method, r.URL.Path, string(body)})
	rec.mu.Unlock()
	// Mirror the real server (api/app.py): a PUT carrying no updatable fields
	// is a 400. A recorder that 200s empty PUTs hid the link-only-update bug.
	if r.Method == "PUT" && strings.TrimSpace(string(body)) == "{}" {
		http.Error(w, `{"detail":"No fields to update"}`, http.StatusBadRequest)
		return
	}
	if strings.Contains(r.URL.Path, "/links") {
		if rec.linkFail {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		w.Write([]byte(`{"status":"linked"}`))
		return
	}
	w.Write([]byte(`{"id":42,"category":"facts","importance":0.5}`))
}

func TestMemoryStoreWithLinksPostsEachLink(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	err := memoryStore([]string{"the hub entry", "--link", "part-of:7", "--link", "see-also:9"})
	if err != nil {
		t.Fatalf("memoryStore: %v", err)
	}
	if len(rec.reqs) != 3 {
		t.Fatalf("want store + 2 link POSTs, got %+v", rec.reqs)
	}
	if rec.reqs[0].method != "POST" || rec.reqs[0].path != "/api/memories" {
		t.Fatalf("first call must store the memory: %+v", rec.reqs[0])
	}
	// Wire key is link_type (server LinkCreate model) — {"type": ...} 422s.
	for i, want := range []recordedReq{
		{"POST", "/api/memories/42/links", `{"link_type":"part-of","target_id":7}`},
		{"POST", "/api/memories/42/links", `{"link_type":"see-also","target_id":9}`},
	} {
		got := rec.reqs[i+1]
		if got.method != want.method || got.path != want.path || got.body != want.body {
			t.Errorf("link call %d = %+v, want %+v", i, got, want)
		}
	}
}

func TestMemoryStoreLinkFailureReportedNotRolledBack(t *testing.T) {
	// ADR-0007: the memory is the durable thing — a failed link never deletes
	// it. The error must surface (non-zero exit) so the caller can retry the
	// link, and must NOT be followed by any rollback call.
	rec := &memAPIRecorder{linkFail: true}
	newMemTestServer(t, rec)
	err := memoryStore([]string{"content", "--link", "supersedes:274"})
	if err == nil || !strings.Contains(err.Error(), "link") {
		t.Fatalf("link failure must be reported, got %v", err)
	}
	for _, r := range rec.reqs {
		if r.method == "DELETE" {
			t.Fatalf("no rollback allowed, saw %+v", rec.reqs)
		}
	}
	if rec.reqs[0].path != "/api/memories" {
		t.Fatalf("memory must have been stored first: %+v", rec.reqs)
	}
}

func TestMemoryStoreInvalidLinkFailsBeforeAPI(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	if err := memoryStore([]string{"content", "--link", "parent-of:5"}); err == nil {
		t.Fatalf("invalid link type must be rejected")
	}
	if len(rec.reqs) != 0 {
		t.Fatalf("invalid link must fail before any API call, saw %+v", rec.reqs)
	}
}

func TestMemoryUpdateLinkAndUnlink(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	err := memoryUpdate([]string{"5", "--content", "new text", "--link", "resolved-by:6775", "--unlink", "see-also:9"})
	if err != nil {
		t.Fatalf("memoryUpdate: %v", err)
	}
	// DELETE is path-addressed as /links/{targetId}/{type} — ID FIRST — to
	// match the server route /api/memories/{memory_id}/links/{dst_id}/{link_type}
	// (type-first would 422: "see-also" can't parse as int dst_id).
	want := []recordedReq{
		{"PUT", "/api/memories/5", `{"content":"new text"}`},
		{"POST", "/api/memories/5/links", `{"link_type":"resolved-by","target_id":6775}`},
		{"DELETE", "/api/memories/5/links/9/see-also", ""},
	}
	if len(rec.reqs) != len(want) {
		t.Fatalf("calls = %+v, want %+v", rec.reqs, want)
	}
	for i := range want {
		if rec.reqs[i] != want[i] {
			t.Errorf("call %d = %+v, want %+v", i, rec.reqs[i], want[i])
		}
	}
}

func TestMemoryUpdateLinkOnlySkipsPut(t *testing.T) {
	// The canonical ADR-0007 retro-cross-linking flow: after storing a truth,
	// `memory update <symptomId> --link resolved-by:<truthId>` carries NO field
	// edits. The server 400s an empty PUT ("No fields to update"), so the CLI
	// must skip the PUT entirely and go straight to the link call.
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	if err := memoryUpdate([]string{"5972", "--link", "resolved-by:6775"}); err != nil {
		t.Fatalf("link-only update must succeed without a PUT: %v", err)
	}
	want := []recordedReq{
		{"POST", "/api/memories/5972/links", `{"link_type":"resolved-by","target_id":6775}`},
	}
	if len(rec.reqs) != len(want) || rec.reqs[0] != want[0] {
		t.Fatalf("calls = %+v, want %+v", rec.reqs, want)
	}
}

func TestMemoryUpdateUnlinkOnlySkipsPut(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	if err := memoryUpdate([]string{"5", "--unlink", "see-also:9"}); err != nil {
		t.Fatalf("unlink-only update must succeed without a PUT: %v", err)
	}
	want := []recordedReq{{"DELETE", "/api/memories/5/links/9/see-also", ""}}
	if len(rec.reqs) != len(want) || rec.reqs[0] != want[0] {
		t.Fatalf("calls = %+v, want %+v", rec.reqs, want)
	}
}

func TestMemoryUpdateNothingToDoErrors(t *testing.T) {
	// No fields, no links, no unlinks → a local error, not a silent no-op and
	// not a doomed empty PUT.
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	if err := memoryUpdate([]string{"5"}); err == nil {
		t.Fatalf("update with nothing to change must error")
	}
	if len(rec.reqs) != 0 {
		t.Fatalf("no-op update must not reach the API, saw %+v", rec.reqs)
	}
}

func TestRecallOmitsSortByUnlessGiven(t *testing.T) {
	// ADR-0005 (amended): the SERVER default sort is relevance. The CLI must
	// not silently re-impose an old default — sort_by is sent only when the
	// caller passes --sort.
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	if err := memoryRecall([]string{"nvidia", "dns", "--json"}); err != nil {
		t.Fatalf("memoryRecall: %v", err)
	}
	if err := memoryRecall([]string{"nvidia", "--sort", "importance"}); err != nil {
		t.Fatalf("memoryRecall --sort: %v", err)
	}
	if len(rec.reqs) != 2 || rec.reqs[0].path != "/api/memories/recall" {
		t.Fatalf("unexpected calls: %+v", rec.reqs)
	}
	if strings.Contains(rec.reqs[0].body, "sort_by") {
		t.Fatalf("recall without --sort must omit sort_by (server default = relevance): %s", rec.reqs[0].body)
	}
	if !strings.Contains(rec.reqs[0].body, `"context":"nvidia dns"`) {
		t.Fatalf("--json must not leak into the recall context: %s", rec.reqs[0].body)
	}
	if !strings.Contains(rec.reqs[1].body, `"sort_by":"importance"`) {
		t.Fatalf("--sort importance must be sent explicitly: %s", rec.reqs[1].body)
	}
}

func TestCheckMemoryBoundCountsRunesNotBytes(t *testing.T) {
	// The bound is 1,400 UNICODE CHARACTERS (ADR-0007 — derived from the recall
	// hook's 8KB/5-results delivery budget, so a ranked Memory arrives whole).
	// 1,400 Cyrillic runes are 2,800 bytes and must PASS: chars, not bytes.
	if err := checkMemoryBound(strings.Repeat("я", 1400)); err != nil {
		t.Fatalf("1400 multibyte runes must pass the bound: %v", err)
	}
	err := checkMemoryBound(strings.Repeat("я", 1401))
	if err == nil {
		t.Fatalf("1401 runes must be rejected")
	}
	want := "content is 1401 chars; the Memory bound is 1,400. Split into a hub + part-of details: store the hub, then store parts with --link part-of:<hubId> (ADR-0007)"
	if err.Error() != want {
		t.Fatalf("bound error must teach the split pattern verbatim:\n got %q\nwant %q", err.Error(), want)
	}
}

func TestMemoryStoreOverBoundNeverCallsAPI(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	err := memoryStore([]string{strings.Repeat("x", 1401)})
	if err == nil || !strings.Contains(err.Error(), "1,400") {
		t.Fatalf("over-bound store must fail with the bound message, got %v", err)
	}
	if len(rec.reqs) != 0 {
		t.Fatalf("over-bound store must not reach the API, saw %+v", rec.reqs)
	}
}

func TestMemoryUpdateOverBoundNeverCallsAPI(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	err := memoryUpdate([]string{"5", "--content", strings.Repeat("x", 1401)})
	if err == nil || !strings.Contains(err.Error(), "1,400") {
		t.Fatalf("over-bound update must fail with the bound message, got %v", err)
	}
	if len(rec.reqs) != 0 {
		t.Fatalf("over-bound update must not reach the API, saw %+v", rec.reqs)
	}
	// An update that does NOT touch content (e.g. importance-only) is exempt —
	// the bound is a write-side content rule.
	if err := memoryUpdate([]string{"5", "--importance", "0.9"}); err != nil {
		t.Fatalf("content-less update must not trip the bound: %v", err)
	}
}

func TestMemoryUpdateInvalidUnlinkFailsBeforeAPI(t *testing.T) {
	rec := &memAPIRecorder{}
	newMemTestServer(t, rec)
	if err := memoryUpdate([]string{"5", "--unlink", "see-also:x"}); err == nil {
		t.Fatalf("invalid unlink id must be rejected")
	}
	if len(rec.reqs) != 0 {
		t.Fatalf("invalid unlink must fail before any API call, saw %+v", rec.reqs)
	}
}
