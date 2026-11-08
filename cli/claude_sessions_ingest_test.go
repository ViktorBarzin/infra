package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type emitted struct {
	Offset int64
	Line   string
	Hint   string
}

func collect(t *testing.T, data string, from int64, hint string) ([]emitted, int64, string) {
	t.Helper()
	var got []emitted
	end, last, err := readNewLines(strings.NewReader(data[from:]), from, hint, func(off int64, line []byte, h string) error {
		got = append(got, emitted{off, string(line), h})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return got, end, last
}

func TestReadNewLinesEmitsCompleteLinesWithOffsets(t *testing.T) {
	data := `{"a":1}` + "\n" + `{"b":22}` + "\n"
	got, end, _ := collect(t, data, 0, "")
	if len(got) != 2 || got[0].Offset != 0 || got[1].Offset != 8 || got[1].Line != `{"b":22}` {
		t.Fatalf("got %+v", got)
	}
	if end != int64(len(data)) {
		t.Fatalf("end = %d, want %d", end, len(data))
	}
}

func TestReadNewLinesLeavesAPartialLastLineForNextRun(t *testing.T) {
	data := `{"a":1}` + "\n" + `{"half":`
	got, end, _ := collect(t, data, 0, "")
	if len(got) != 1 || end != 8 {
		t.Fatalf("got %+v end %d; a partial line must not be consumed", got, end)
	}
	// The writer finishes the line; the next run starts where the last stopped.
	data += `true}` + "\n"
	got, end, _ = collect(t, data, end, "")
	if len(got) != 1 || got[0].Offset != 8 || got[0].Line != `{"half":true}` || end != int64(len(data)) {
		t.Fatalf("resume got %+v end %d", got, end)
	}
}

func TestReadNewLinesHasNoLineSizeLimit(t *testing.T) {
	// claude-usage's scanner stops at 16 MiB; an archive must not drop lines.
	big := `{"x":"` + strings.Repeat("y", 20<<20) + `"}`
	got, _, _ := collect(t, big+"\n", 0, "")
	if len(got) != 1 || len(got[0].Line) != len(big) {
		t.Fatalf("a %d-byte line was not emitted whole", len(big))
	}
}

func TestReadNewLinesCarriesTheTimestampHint(t *testing.T) {
	data := `{"type":"mode"}` + "\n" +
		`{"type":"user","timestamp":"2026-10-01T10:00:00Z"}` + "\n" +
		`{"type":"last-prompt"}` + "\n"
	got, _, last := collect(t, data, 0, "")
	if got[0].Hint != "" {
		t.Fatalf("no timestamp seen yet, hint should be empty, got %q", got[0].Hint)
	}
	if got[2].Hint != "2026-10-01T10:00:00Z" || last != "2026-10-01T10:00:00Z" {
		t.Fatalf("hint not carried: %+v last=%q", got, last)
	}
	// A hint from the previous run seeds the next one.
	got, _, _ = collect(t, `{"type":"mode"}`+"\n", 0, "2026-09-09T09:09:09Z")
	if got[0].Hint != "2026-09-09T09:09:09Z" {
		t.Fatalf("seeded hint lost: %+v", got)
	}
}

func TestReadNewLinesSkipsBlankLines(t *testing.T) {
	got, end, _ := collect(t, "\n"+`{"a":1}`+"\n", 0, "")
	if len(got) != 1 || got[0].Offset != 1 || end != 9 {
		t.Fatalf("got %+v end %d", got, end)
	}
}

func TestPlanFile(t *testing.T) {
	prev := &fileState{Inode: 7, Size: 100, MtimeNs: 5, Offset: 100, TsHint: "h"}
	cases := []struct {
		name       string
		prev       *fileState
		inode      uint64
		size       int64
		mtime      int64
		wantSkip   bool
		wantOffset int64
		wantHint   string
	}{
		{"new file", nil, 7, 50, 1, false, 0, ""},
		{"unchanged", prev, 7, 100, 5, true, 0, ""},
		{"grown", prev, 7, 150, 6, false, 100, "h"},
		{"touched but same size", prev, 7, 100, 9, false, 100, "h"},
		{"truncated", prev, 7, 40, 9, false, 0, ""},
		{"replaced", prev, 8, 150, 9, false, 0, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			skip, off, hint := planFile(c.prev, c.inode, c.size, c.mtime)
			if skip != c.wantSkip || (!skip && (off != c.wantOffset || hint != c.wantHint)) {
				t.Fatalf("planFile = (%v,%d,%q), want (%v,%d,%q)", skip, off, hint, c.wantSkip, c.wantOffset, c.wantHint)
			}
		})
	}
}

func TestClassifyTranscriptPath(t *testing.T) {
	root := "/home/emo/.claude/projects"
	cases := []struct {
		rel  string
		want pathInfo
		ok   bool
	}{
		{"-home-emo-code/1111.jsonl", pathInfo{Project: "-home-emo-code", Session: "1111", Kind: kindTranscript}, true},
		{"-home-emo-code/1111/subagents/agent-ab12.jsonl", pathInfo{Project: "-home-emo-code", Session: "1111", Agent: "agent-ab12", Kind: kindTranscript}, true},
		{"-home-emo-code/1111/subagents/agent-ab12.meta.json", pathInfo{Project: "-home-emo-code", Session: "1111", Agent: "agent-ab12", Kind: kindSubagentMeta}, true},
		{"-home-emo-code/1111/tool-results/bx9.txt", pathInfo{Project: "-home-emo-code", Session: "1111", Kind: kindToolResult}, true},
		{"-home-emo-code/1111/other/x.txt", pathInfo{}, false},
		{"-home-emo-code/notes.md", pathInfo{}, false},
	}
	for _, c := range cases {
		got, ok := classifyTranscriptPath(root, filepath.Join(root, c.rel))
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("%s: got %+v,%v want %+v,%v", c.rel, got, ok, c.want, c.ok)
		}
	}
}

func TestBatchTokensAreDeterministic(t *testing.T) {
	var b1, b2 []string
	for _, out := range []*[]string{&b1, &b2} {
		bt := newBatcher(30, func(token string, body []byte) error {
			*out = append(*out, token)
			return nil
		})
		for i, off := range []int64{0, 10, 20, 30} {
			if err := bt.add("/f.jsonl", off, []byte(`{"n":`+string(rune('0'+i))+`}`)); err != nil {
				t.Fatal(err)
			}
		}
		if err := bt.flush(); err != nil {
			t.Fatal(err)
		}
	}
	if len(b1) < 2 {
		t.Fatalf("budget of 30 bytes should split 4 rows, got %v", b1)
	}
	if strings.Join(b1, ",") != strings.Join(b2, ",") {
		t.Fatalf("tokens differ between identical runs: %v vs %v", b1, b2)
	}
	if b1[0] != "/f.jsonl:0" {
		t.Fatalf("token should name the file and first offset, got %q", b1[0])
	}
}

func TestStateRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	s := ingestState{Files: map[string]*fileState{"/a": {Inode: 1, Size: 2, MtimeNs: 3, Offset: 2, TsHint: "x"}}}
	if err := saveState(p, &s); err != nil {
		t.Fatal(err)
	}
	got, err := loadState(p)
	if err != nil || got.Files["/a"].TsHint != "x" || got.Files["/a"].Offset != 2 {
		t.Fatalf("got %+v err %v", got, err)
	}
	// A missing state file is a first run, not an error.
	empty, err := loadState(filepath.Join(t.TempDir(), "none.json"))
	if err != nil || len(empty.Files) != 0 {
		t.Fatalf("missing state: %+v %v", empty, err)
	}
}

func TestParseEnvFile(t *testing.T) {
	got := parseEnvFile("# comment\nA=1\n\nB = two words \nC='q'\nD=\"dq\"\nbroken\n")
	want := map[string]string{"A": "1", "B": "two words", "C": "q", "D": "dq"}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	if _, ok := got["broken"]; ok {
		t.Error("a line without = must be ignored")
	}
}

// fakeClickHouse records every INSERT body and the dedup token it came with.
type fakeClickHouse struct {
	mu      sync.Mutex
	inserts []recordedInsert
}

type recordedInsert struct {
	Query, Token string
	Rows         []map[string]any
}

func (f *fakeClickHouse) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-ClickHouse-User") != "ingest" || r.Header.Get("X-ClickHouse-Key") != "pw" {
			http.Error(w, "auth", http.StatusUnauthorized)
			return
		}
		var rd io.Reader = r.Body
		if r.Header.Get("Content-Encoding") == "gzip" {
			zr, err := gzip.NewReader(r.Body)
			if err != nil {
				t.Errorf("bad gzip body: %v", err)
				return
			}
			rd = zr
		}
		body, _ := io.ReadAll(rd)
		ins := recordedInsert{Query: r.URL.Query().Get("query"), Token: r.URL.Query().Get("insert_deduplication_token")}
		for _, l := range bytes.Split(bytes.TrimSpace(body), []byte("\n")) {
			if len(l) == 0 {
				continue
			}
			var m map[string]any
			if err := json.Unmarshal(l, &m); err != nil {
				t.Errorf("body is not JSONEachRow: %v", err)
			}
			ins.Rows = append(ins.Rows, m)
		}
		f.mu.Lock()
		f.inserts = append(f.inserts, ins)
		f.mu.Unlock()
	}
}

func (f *fakeClickHouse) rows(table string) []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []map[string]any
	for _, i := range f.inserts {
		if strings.Contains(i.Query, "INTO claude."+table+" ") {
			out = append(out, i.Rows...)
		}
	}
	return out
}

func TestIngestEndToEndIsIncremental(t *testing.T) {
	fake := &fakeClickHouse{}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()

	homes := t.TempDir()
	proj := filepath.Join(homes, "emo", ".claude", "projects", "-home-emo-code")
	sess := "5e55"
	if err := os.MkdirAll(filepath.Join(proj, sess, "subagents"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(proj, sess, "tool-results"), 0o755); err != nil {
		t.Fatal(err)
	}
	main := filepath.Join(proj, sess+".jsonl")
	write := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(main, `{"type":"user","timestamp":"2026-10-01T10:00:00Z"}`+"\n"+`{"type":"mode"}`+"\n")
	write(filepath.Join(proj, sess, "subagents", "agent-a1.jsonl"), `{"type":"assistant","timestamp":"2026-10-01T10:00:05Z"}`+"\n")
	write(filepath.Join(proj, sess, "subagents", "agent-a1.meta.json"), `{"agentType":"Explore"}`)
	write(filepath.Join(proj, sess, "tool-results", "bx.txt"), "big output")

	cfg := ingestConfig{
		HomesRoot: homes,
		StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB:        dbConn{URL: srv.URL, User: "ingest", Password: "pw"},
		Budget:    1 << 20,
	}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	lines := fake.rows("lines")
	if len(lines) != 3 {
		t.Fatalf("first run: want 3 lines (2 main + 1 subagent), got %d: %v", len(lines), lines)
	}
	for _, r := range lines {
		if r["os_user"] != "emo" || r["session_id"] != sess || r["project"] != "-home-emo-code" {
			t.Fatalf("bad identity columns: %v", r)
		}
	}
	var sawHint, sawAgent bool
	for _, r := range lines {
		if strings.Contains(r["raw"].(string), `"mode"`) && r["ts_hint"] == "2026-10-01T10:00:00Z" {
			sawHint = true
		}
		if r["agent_id"] == "agent-a1" {
			sawAgent = true
		}
	}
	if !sawHint || !sawAgent {
		t.Fatalf("hint=%v agent=%v in %v", sawHint, sawAgent, lines)
	}
	if files := fake.rows("files"); len(files) != 2 {
		t.Fatalf("want tool-result and meta.json in files, got %v", files)
	}

	// Second run with nothing changed sends nothing.
	before := len(fake.inserts)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	if len(fake.inserts) != before {
		t.Fatalf("unchanged files were re-sent: %d inserts after %d", len(fake.inserts), before)
	}

	// Appending one line sends exactly that line, at its byte offset.
	f, _ := os.OpenFile(main, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"type":"assistant","timestamp":"2026-10-01T10:01:00Z"}` + "\n")
	f.Close()
	time.Sleep(10 * time.Millisecond)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	newRows := fake.inserts[before:]
	if len(newRows) != 1 || len(newRows[0].Rows) != 1 {
		t.Fatalf("want one insert of one row, got %+v", newRows)
	}
	if off := newRows[0].Rows[0]["byte_offset"].(float64); off != 67 {
		t.Fatalf("appended line offset = %v, want 67", off)
	}
}

func TestIngestKeepsStateWhenTheDatabaseFails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	homes := t.TempDir()
	proj := filepath.Join(homes, "wizard", ".claude", "projects", "p")
	os.MkdirAll(proj, 0o755)
	os.WriteFile(filepath.Join(proj, "s.jsonl"), []byte(`{"type":"user"}`+"\n"), 0o644)
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: srv.URL, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	if _, err := runIngest(cfg); err == nil {
		t.Fatal("a failed insert must surface as an error")
	}
	st, _ := loadState(cfg.StatePath)
	if fs := st.Files[filepath.Join(proj, "s.jsonl")]; fs != nil && fs.Offset > 0 {
		t.Fatalf("offset advanced past data the database never accepted: %+v", fs)
	}
}

func TestIngestResumesAfterFailingMidFile(t *testing.T) {
	fake := &fakeClickHouse{}
	var calls int
	failSecond := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if failSecond && calls == 2 {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		fake.handler(t)(w, r)
	}))
	defer srv.Close()
	homes := t.TempDir()
	proj := filepath.Join(homes, "wizard", ".claude", "projects", "p")
	os.MkdirAll(proj, 0o755)
	var b strings.Builder
	for i := 0; i < 6; i++ {
		b.WriteString(`{"type":"user","n":` + string(rune('0'+i)) + `}` + "\n")
	}
	os.WriteFile(filepath.Join(proj, "s.jsonl"), []byte(b.String()), 0o644)
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: srv.URL, User: "ingest", Password: "pw"}, Budget: 60}
	if _, err := runIngest(cfg); err == nil {
		t.Fatal("want an error from the failed second batch")
	}
	sent := len(fake.rows("lines"))
	if sent == 0 || sent == 6 {
		t.Fatalf("expected a partial first run, sent %d", sent)
	}
	failSecond = false
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	if got := len(fake.rows("lines")); got != 6 {
		t.Fatalf("after the retry every line should be sent exactly once, got %d", got)
	}
}

func TestIngestIgnoresSymlinks(t *testing.T) {
	fake := &fakeClickHouse{}
	srv := httptest.NewServer(fake.handler(t))
	defer srv.Close()
	homes := t.TempDir()
	proj := filepath.Join(homes, "emo", ".claude", "projects", "p")
	os.MkdirAll(filepath.Join(proj, "sess", "tool-results"), 0o755)
	secret := filepath.Join(t.TempDir(), "shadow")
	os.WriteFile(secret, []byte(`{"secret":true}`+"\n"), 0o600)
	os.Symlink(secret, filepath.Join(proj, "evil.jsonl"))
	os.Symlink(secret, filepath.Join(proj, "sess", "tool-results", "evil.txt"))
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: srv.URL, User: "ingest", Password: "pw"}}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	if len(fake.inserts) != 0 {
		t.Fatalf("a symlinked file was ingested: %+v", fake.inserts)
	}
}
