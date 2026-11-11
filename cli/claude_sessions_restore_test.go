package main

import (
	"archive/tar"
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// memSource serves what the fake ClickHouse recorded, the way the real
// queries do: newest row per key, sorted, from/after paging.
type memSource struct {
	lines, files, hFiles, hLines []map[string]any
}

func newMemSource(f *fakeClickHouse) *memSource {
	return &memSource{lines: f.rows("lines"), files: f.rows("files"), hFiles: f.rows("home_files"), hLines: f.rows("home_lines")}
}

func (m *memSource) transcriptFiles(user, session string) ([]storedRef, error) {
	seen := map[string]storedRef{}
	for _, r := range m.lines {
		if r["os_user"] != user || (session != "" && r["session_id"] != session) {
			continue
		}
		seen[r["file"].(string)] = storedRef{Path: r["file"].(string), Session: r["session_id"].(string), MtimeMs: 1_700_000_000_000}
	}
	var out []storedRef
	for _, k := range sortedRefKeys(seen) {
		out = append(out, seen[k])
	}
	return out, nil
}

func (m *memSource) linesOf(rows []map[string]any, match func(map[string]any) bool, from uint64, limit int) []storedLine {
	byOff := map[uint64]string{}
	for _, r := range rows {
		if match(r) {
			byOff[uint64(r["byte_offset"].(float64))] = r["raw"].(string) // later rows win
		}
	}
	var offs []uint64
	for o := range byOff {
		if o >= from {
			offs = append(offs, o)
		}
	}
	sort.Slice(offs, func(i, j int) bool { return offs[i] < offs[j] })
	var out []storedLine
	for _, o := range offs {
		if len(out) == limit {
			break
		}
		out = append(out, storedLine{Offset: o, Raw: byOff[o]})
	}
	return out
}

func (m *memSource) transcriptLines(user string, ref storedRef, from uint64, limit int) ([]storedLine, error) {
	return m.linesOf(m.lines, func(r map[string]any) bool { return r["os_user"] == user && r["file"] == ref.Path }, from, limit), nil
}

func (m *memSource) pageFiles(rows []map[string]any, match func(map[string]any) bool, after string, limit int) []storedFile {
	latest := map[string]storedFile{}
	for _, r := range rows {
		if !match(r) {
			continue
		}
		f := storedFile{Path: r["path"].(string), MtimeMs: 1_700_000_000_000, Content: r["content"].(string), Encoding: "text"}
		if v, ok := r["mode"].(float64); ok {
			f.Mode = uint32(v)
		}
		if v, ok := r["encoding"].(string); ok {
			f.Encoding = v
		}
		if v, ok := r["redacted"].(bool); ok {
			f.Redacted = v
		}
		latest[f.Path] = f
	}
	var out []storedFile
	for _, k := range sortedFileKeys(latest) {
		if k > after && len(out) < limit {
			out = append(out, latest[k])
		}
	}
	return out
}

func (m *memSource) sideFiles(user, session, after string, limit int) ([]storedFile, error) {
	return m.pageFiles(m.files, func(r map[string]any) bool {
		return r["os_user"] == user && (session == "" || r["session_id"] == session)
	}, after, limit), nil
}

func (m *memSource) homeFiles(user, session, after string, limit int) ([]storedFile, error) {
	return m.pageFiles(m.hFiles, func(r map[string]any) bool {
		return r["os_user"] == user && (session == "" || strings.Contains(r["path"].(string), "/"+session+"/"))
	}, after, limit), nil
}

func (m *memSource) homeLineFiles(user, session string) ([]storedRef, error) {
	seen := map[string]storedRef{}
	for _, r := range m.hLines {
		if r["os_user"] != user || (session != "" && !strings.Contains(r["path"].(string), session)) {
			continue
		}
		seen[r["path"].(string)] = storedRef{Path: r["path"].(string), Generation: r["generation"].(string), MtimeMs: 1_700_000_000_000}
	}
	var out []storedRef
	for _, k := range sortedRefKeys(seen) {
		out = append(out, seen[k])
	}
	return out, nil
}

func (m *memSource) homeLines(user string, ref storedRef, from uint64, limit int) ([]storedLine, error) {
	return m.linesOf(m.hLines, func(r map[string]any) bool {
		return r["os_user"] == user && r["path"] == ref.Path && r["generation"] == ref.Generation
	}, from, limit), nil
}

func sortedRefKeys(m map[string]storedRef) []string {
	var k []string
	for x := range m {
		k = append(k, x)
	}
	sort.Strings(k)
	return k
}

func sortedFileKeys(m map[string]storedFile) []string {
	var k []string
	for x := range m {
		k = append(k, x)
	}
	sort.Strings(k)
	return k
}

// ingestFixture runs the real ingest over agentHomeFixture and returns what
// the store would hold.
func ingestFixture(t *testing.T) (*memSource, string) {
	t.Helper()
	fake, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	return newMemSource(fake), home
}

func TestRestoreRoundTrip(t *testing.T) {
	src, home := ingestFixture(t)
	dest := t.TempDir()
	st, err := runRestore(src, "emo", "", &dirSink{root: dest}, 2) // page size 2 exercises paging
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{
		".claude/history.jsonl",
		".claude/plans/p.md",
		".claude/file-history/5e55/abc@v1",
		".claude/projects/-home-emo-code/5e55.jsonl",
		".claude/projects/-home-emo-code/5e55/workflows/wf.json",
		".codex/sessions/2026/11/01/rollout-x.jsonl",
	} {
		want, _ := os.ReadFile(filepath.Join(home, rel))
		got, err := os.ReadFile(filepath.Join(dest, rel))
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: got %q (%v), want %q", rel, got, err, want)
		}
	}
	for _, never := range []string{".claude/.credentials.json", ".codex/auth.json", ".claude/cache/changelog.md", ".claude/settings.json.from-store"} {
		if _, err := os.Stat(filepath.Join(dest, never)); err == nil {
			t.Errorf("%s must not be restored", never)
		}
	}
	// The redacted settings file comes back under its real name, without the
	// redacted key, so provisioning can fill it from Vault.
	red, err := os.ReadFile(filepath.Join(dest, ".claude/settings.json"))
	if err != nil || strings.Contains(string(red), "k-1") || strings.Contains(string(red), "MEMORY_API_KEY") || strings.Contains(string(red), redactedValue) || !strings.Contains(string(red), "opus") {
		t.Errorf("redacted settings should come back under the real name without the secret: %q %v", red, err)
	}
	if len(st.Redacted) != 1 || st.Written != 7 {
		t.Errorf("stats %+v", st)
	}
	fi, _ := os.Stat(filepath.Join(dest, ".claude/plans/p.md"))
	if fi.Mode().Perm() != 0o640 {
		t.Errorf("mode = %v, want 0640", fi.Mode().Perm())
	}

	// A second restore leaves what is there alone.
	st, err = runRestore(src, "emo", "", &dirSink{root: dest}, 100)
	if err != nil || st.Written != 0 || st.Skipped != 7 || len(st.Beside) != 0 {
		t.Fatalf("second run: %+v %v", st, err)
	}

	// A settings file of the user's own that differs gets the stored copy
	// beside it.
	os.WriteFile(filepath.Join(dest, ".claude/settings.json"), []byte(`{"theme":"dark"}`), 0o600)
	st, err = runRestore(src, "emo", "", &dirSink{root: dest}, 100)
	if err != nil || len(st.Beside) != 1 || st.Beside[0] != ".claude/settings.json.from-store" {
		t.Fatalf("third run: %+v %v", st, err)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, ".claude/settings.json")); string(b) != `{"theme":"dark"}` {
		t.Fatalf("the user's file was changed: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, ".claude/settings.json.from-store")); !strings.Contains(string(b), "opus") {
		t.Fatalf("beside copy %q", b)
	}
}

func TestRestoreOneSession(t *testing.T) {
	src, _ := ingestFixture(t)
	dest := t.TempDir()
	st, err := runRestore(src, "emo", "5e55", &dirSink{root: dest}, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{".claude/projects/-home-emo-code/5e55.jsonl", ".claude/file-history/5e55/abc@v1",
		".claude/projects/-home-emo-code/5e55/workflows/wf.json"} {
		if _, err := os.Stat(filepath.Join(dest, rel)); err != nil {
			t.Errorf("%s missing: %v", rel, err)
		}
	}
	for _, rel := range []string{".claude/history.jsonl", ".claude/plans/p.md"} {
		if _, err := os.Stat(filepath.Join(dest, rel)); err == nil {
			t.Errorf("%s is not part of the session", rel)
		}
	}
	if st.Written != 3 {
		t.Errorf("stats %+v", st)
	}
}

func TestRestoreTar(t *testing.T) {
	src, home := ingestFixture(t)
	var buf bytes.Buffer
	sink := newTarSink(&buf)
	if _, err := runRestore(src, "emo", "", sink, 100); err != nil {
		t.Fatal(err)
	}
	if err := sink.Close(); err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(&buf)
	got := map[string][]byte{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			b, _ := io.ReadAll(tr)
			got[h.Name] = b
		} else if h.Typeflag == tar.TypeDir && h.Mode != 0o700 {
			t.Errorf("dir %s mode %o", h.Name, h.Mode)
		}
	}
	want, _ := os.ReadFile(filepath.Join(home, ".claude/projects/-home-emo-code/5e55.jsonl"))
	if !bytes.Equal(got[".claude/projects/-home-emo-code/5e55.jsonl"], want) || len(got) != 7 {
		t.Fatalf("tar entries %v", len(got))
	}
}

type evilSource struct{ memSource }

func (evilSource) homeFiles(user, session, after string, limit int) ([]storedFile, error) {
	if after != "" {
		return nil, nil
	}
	return []storedFile{
		{Path: "../../etc/evil", Encoding: "text", Content: "x"},
		{Path: ".claude/../../evil", Encoding: "text", Content: "x"},
		{Path: "/abs/evil", Encoding: "text", Content: "x"},
		{Path: ".bashrc", Encoding: "text", Content: "x"},
		{Path: ".claude/big.bin", Encoding: "omitted"},
	}, nil
}

func TestRestoreRefusesPathsOutsideTheAgentDirs(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "home")
	os.Mkdir(dest, 0o700)
	st, err := runRestore(&evilSource{}, "emo", "", &dirSink{root: dest}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if st.Written != 0 || st.Refused != 4 || st.Omitted != 1 {
		t.Fatalf("stats %+v", st)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dest), "evil")); err == nil {
		t.Fatal("a path escaped the target")
	}
}

func TestTranscriptRel(t *testing.T) {
	cases := map[string]string{
		"/home/emo/.claude/projects/p/s.jsonl":      ".claude/projects/p/s.jsonl",
		"/srv/homes/emo/.claude/projects/p/s.jsonl": ".claude/projects/p/s.jsonl",
		"/home/wizard/.claude/projects/p/s.jsonl":   "",
		"/home/emo/notes.txt":                       "",
	}
	for abs, want := range cases {
		if got := transcriptRel("emo", abs); got != want {
			t.Errorf("%s -> %q, want %q", abs, got, want)
		}
	}
}

// The SQL source pages with keyset queries and passes user input only as
// query parameters.
func TestSQLSourceUsesParameters(t *testing.T) {
	var queries []string
	var params []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		q := r.URL.Query()
		queries = append(queries, q.Get("query"))
		params = append(params, q.Get("param_u")+"|"+q.Get("param_s")+"|"+q.Get("param_f"))
		if strings.Contains(q.Get("query"), "byte_offset >= 0") {
			io.WriteString(w, `{"byte_offset":0,"raw":"{\"a\":1}"}`+"\n"+`{"byte_offset":8,"raw":"{\"b\":2}"}`+"\n")
		}
	}))
	defer srv.Close()
	src := sqlSource{db: dbConn{URL: srv.URL, User: "reader", Password: "pw"}}
	got, err := src.transcriptLines("emo", storedRef{Path: "/home/emo/.claude/projects/p/s'; DROP.jsonl", Session: "s"}, 0, 50)
	if err != nil || len(got) != 2 || got[1].Offset != 8 || got[1].Raw != `{"b":2}` {
		t.Fatalf("got %+v %v", got, err)
	}
	if strings.Contains(queries[0], "DROP") || !strings.Contains(params[0], "DROP") {
		t.Fatalf("user input must travel as a parameter: %q %q", queries[0], params[0])
	}
}
