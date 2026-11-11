package main

import (
	"archive/tar"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// untarSkipOld stands in for `runuser -u <user> -- tar -x --skip-old-files`:
// it writes every regular entry that is not there yet, with its mode and mtime.
func untarSkipOld(root string) func(io.Reader) error {
	return func(r io.Reader) error {
		tr := tar.NewReader(r)
		for {
			h, err := tr.Next()
			if errors.Is(err, io.EOF) {
				return nil
			}
			if err != nil {
				return err
			}
			p := filepath.Join(root, filepath.FromSlash(h.Name))
			if h.Typeflag == tar.TypeDir {
				if err := os.MkdirAll(p, 0o700); err != nil {
					return err
				}
				continue
			}
			if _, err := os.Lstat(p); err == nil {
				continue
			}
			b, err := io.ReadAll(tr)
			if err != nil {
				return err
			}
			if err := os.WriteFile(p, b, fs.FileMode(h.Mode)); err != nil {
				return err
			}
			if err := os.Chtimes(p, h.ModTime, h.ModTime); err != nil {
				return err
			}
		}
	}
}

func inodeOf(t *testing.T, p string) uint64 {
	t.Helper()
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Sys().(*syscall.Stat_t).Ino
}

// A rebuilt box: restore writes the user's files back and records them in the
// ingest state as already sent, so the first ingest after it sends nothing
// again. A file that was there first is kept and not recorded.
func TestRebuildRestoreSeedsTheIngestState(t *testing.T) {
	src, orig := ingestFixture(t)
	homes := t.TempDir()
	home := filepath.Join(homes, "emo")
	os.MkdirAll(filepath.Join(home, ".claude"), 0o700)
	os.WriteFile(filepath.Join(home, ".claude/history.jsonl"), []byte(`{"display":"new box"}`+"\n"), 0o600)
	statePath := filepath.Join(t.TempDir(), "state.json")

	res, err := runRebuildRestore(rebuildConfig{User: "emo", Home: home, StatePath: statePath, Src: src,
		Extract: untarSkipOld(home), PageRows: 2})
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != "restored" || res.Seeded != 6 || len(res.KeptLineFiles) != 1 || res.KeptLineFiles[0] != ".claude/history.jsonl" {
		t.Fatalf("result %+v", res)
	}
	want, _ := os.ReadFile(filepath.Join(orig, ".claude/projects/-home-emo-code/5e55.jsonl"))
	got, _ := os.ReadFile(filepath.Join(home, ".claude/projects/-home-emo-code/5e55.jsonl"))
	if string(got) != string(want) {
		t.Fatalf("transcript %q, want %q", got, want)
	}
	if _, err := os.Stat(rebuildMarker(statePath, "emo")); err != nil {
		t.Fatalf("no marker: %v", err)
	}
	state, _ := loadState(statePath)
	tp := filepath.Join(home, ".claude/projects/-home-emo-code/5e55.jsonl")
	if s := state.Files[tp]; s == nil || s.Offset != int64(len(want)) || s.Size != int64(len(want)) || s.Inode != inodeOf(t, tp) {
		t.Fatalf("transcript state %+v", state.Files[tp])
	}
	rp := filepath.Join(home, ".codex/sessions/2026/11/01/rollout-x.jsonl")
	if s := state.Files[rp]; s == nil || s.Gen == "" {
		t.Fatalf("a restored line file keeps its stored generation: %+v", state.Files[rp])
	}
	if state.Files[filepath.Join(home, ".claude/history.jsonl")] != nil {
		t.Fatal("a file that was there first must not be recorded as sent")
	}

	// The first ingest afterwards sends only the file that was there first.
	fake, url, done := startFake(t)
	defer done()
	st, err := runIngest(ingestConfig{HomesRoot: homes, StatePath: statePath, RequireRestore: true,
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	if len(fake.rows("lines")) != 0 || len(fake.rows("home_files")) != 0 || len(fake.rows("files")) != 0 {
		t.Fatalf("restored files were sent again: lines=%d home_files=%d files=%d", len(fake.rows("lines")), len(fake.rows("home_files")), len(fake.rows("files")))
	}
	if hl := fake.rows("home_lines"); len(hl) != 1 || hl[0]["path"] != ".claude/history.jsonl" || st.UsersWaiting != 0 {
		t.Fatalf("home_lines %v, stats %+v", hl, st)
	}

	// Every later provisioning run is a no-op.
	res, err = runRebuildRestore(rebuildConfig{User: "emo", Home: home, StatePath: statePath, Src: src,
		Extract: func(io.Reader) error { t.Fatal("extract on a second run"); return nil }})
	if err != nil || res.Outcome != "already restored" {
		t.Fatalf("second run %+v %v", res, err)
	}
}

// The live box has been ingesting the user all along: restore must not write
// anything into the home, only record that the user is done.
func TestRebuildRestoreLeavesAnIngestingBoxAlone(t *testing.T) {
	home := filepath.Join(t.TempDir(), "wizard")
	statePath := filepath.Join(t.TempDir(), "state.json")
	saveState(statePath, &ingestState{Files: map[string]*fileState{home + "/.claude/history.jsonl": {Inode: 1, Size: 1, Offset: 1}}})
	res, err := runRebuildRestore(rebuildConfig{User: "wizard", Home: home, StatePath: statePath, Src: &memSource{},
		Extract: func(io.Reader) error { t.Fatal("extract on a box that ingests the user"); return nil }})
	if err != nil || res.Outcome != "already ingesting" {
		t.Fatalf("%+v %v", res, err)
	}
	if _, err := os.Stat(rebuildMarker(statePath, "wizard")); err != nil {
		t.Fatal("marker missing")
	}
}

// A failed extract leaves no marker, so the next provisioning run tries again,
// and the ingest keeps waiting.
func TestRebuildRestoreRetriesAfterAFailure(t *testing.T) {
	src, _ := ingestFixture(t)
	home := filepath.Join(t.TempDir(), "emo")
	os.MkdirAll(home, 0o700)
	statePath := filepath.Join(t.TempDir(), "state.json")
	_, err := runRebuildRestore(rebuildConfig{User: "emo", Home: home, StatePath: statePath, Src: src,
		Extract: func(r io.Reader) error { io.Copy(io.Discard, r); return errors.New("tar: disk full") }})
	if err == nil {
		t.Fatal("want the extract error")
	}
	if _, err := os.Stat(rebuildMarker(statePath, "emo")); err == nil {
		t.Fatal("a failed restore must not leave a marker")
	}
}

// The ingest leaves a user alone until restore has run for them on this box,
// so a rebuilt box's first files never shadow the stored ones.
func TestIngestWaitsForRestore(t *testing.T) {
	fake, url, done := startFake(t)
	defer done()
	homes, _ := agentHomeFixture(t)
	statePath := filepath.Join(t.TempDir(), "state.json")
	cfg := ingestConfig{HomesRoot: homes, StatePath: statePath, RequireRestore: true,
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	st, err := runIngest(cfg)
	if err != nil || st.UsersWaiting != 1 || len(fake.inserts) != 0 {
		t.Fatalf("stats %+v err %v inserts %d", st, err, len(fake.inserts))
	}
	if err := writeRebuildMarker(statePath, "emo", "test"); err != nil {
		t.Fatal(err)
	}
	st, err = runIngest(cfg)
	if err != nil || st.UsersWaiting != 0 || len(fake.rows("lines")) == 0 {
		t.Fatalf("after the marker: stats %+v err %v", st, err)
	}
}

// On the live box the state already lists the user's files: the ingest goes
// on and writes the marker itself, so it never depends on provisioning.
func TestIngestMarksAUserItAlreadyTracks(t *testing.T) {
	_, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	statePath := filepath.Join(t.TempDir(), "state.json")
	saveState(statePath, &ingestState{Files: map[string]*fileState{home + "/.claude/plans/p.md": {Inode: 1, Size: 1, Offset: 1}}})
	st, err := runIngest(ingestConfig{HomesRoot: homes, StatePath: statePath, RequireRestore: true,
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20})
	if err != nil || st.UsersWaiting != 0 {
		t.Fatalf("%+v %v", st, err)
	}
	if _, err := os.Stat(rebuildMarker(statePath, "emo")); err != nil {
		t.Fatal("marker missing")
	}
}

// The verb takes short Linux user names such as emo; --session keeps its
// stricter id rule.
func TestRestoreVerbAcceptsShortUserNames(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	t.Setenv("CLAUDE_SESSIONS_URL", srv.URL)
	t.Setenv("CLAUDE_SESSIONS_USER", "reader")
	t.Setenv("CLAUDE_SESSIONS_PASSWORD", "pw")
	out := filepath.Join(t.TempDir(), "emo.tar")
	if err := claudeSessionsRestore([]string{"--user", "emo", "--tar", out}); err != nil {
		t.Fatalf("--user emo: %v", err)
	}
	if err := claudeSessionsRestore([]string{"--user", "emo", "--to", t.TempDir()}); err != nil {
		t.Fatalf("--user emo --to: %v", err)
	}
	for _, bad := range [][]string{
		{"--user", "e/mo", "--to", t.TempDir()},
		{"--user", "emo;rm", "--to", t.TempDir()},
		{"--user", "-emo", "--to", t.TempDir()},
		{"--user", strings.Repeat("a", 33), "--to", t.TempDir()},
		{"--user", "emo", "--session", "abc", "--to", t.TempDir()},
		{"--user", "emo", "--session", "../x", "--to", t.TempDir()},
	} {
		if err := claudeSessionsRestore(bad); err == nil {
			t.Errorf("%v: want a refusal", bad)
		}
	}
}

// A transcript with lines missing in the middle is written, and reported.
func TestRestoreReportsGaps(t *testing.T) {
	src := &memSource{lines: []map[string]any{
		{"os_user": "emo", "session_id": "s1", "file": "/home/emo/.claude/projects/p/s1.jsonl", "byte_offset": float64(0), "raw": `{"a":1}`},
		{"os_user": "emo", "session_id": "s1", "file": "/home/emo/.claude/projects/p/s1.jsonl", "byte_offset": float64(8), "raw": `{"b":2}`},
		{"os_user": "emo", "session_id": "s1", "file": "/home/emo/.claude/projects/p/s1.jsonl", "byte_offset": float64(100), "raw": `{"c":3}`},
		{"os_user": "emo", "session_id": "s2", "file": "/home/emo/.claude/projects/p/s2.jsonl", "byte_offset": float64(0), "raw": `{"a":1}`},
	}}
	st, err := runRestore(src, "emo", "", &dirSink{root: t.TempDir()}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Gapped) != 1 || st.Gapped[0] != ".claude/projects/p/s1.jsonl (84 bytes missing)" || st.Written != 2 {
		t.Fatalf("stats %+v", st)
	}
}

func TestRebuildMarkerPath(t *testing.T) {
	if got := rebuildMarker("/var/lib/claude-sessions-ingest/state.json", "emo"); got != "/var/lib/claude-sessions-ingest/restored/emo" {
		t.Fatal(got)
	}
	_ = time.Now
}

// A transcript Claude Code rewrites (a new inode) is read again from the
// start. Its first batch must not reuse the token of the old file's first
// batch: ClickHouse drops a block whose token it has seen, and on 2026-11-08
// that silently lost 357 lines that were new in the rewritten copy.
func TestIngestTokensChangeWhenAFileIsReplaced(t *testing.T) {
	fake, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	statePath := filepath.Join(t.TempDir(), "state.json")
	cfg := ingestConfig{HomesRoot: homes, StatePath: statePath, DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	tp := filepath.Join(home, ".claude/projects/-home-emo-code/5e55.jsonl")
	first := fake.insertsTo("lines")
	if len(first) != 1 {
		t.Fatalf("inserts %d", len(first))
	}
	old, _ := os.ReadFile(tp)
	tmp := tp + ".new"
	os.WriteFile(tmp, append(old, []byte(`{"type":"assistant","timestamp":"2026-10-01T10:01:00Z"}`+"\n")...), 0o640)
	os.Rename(tmp, tp)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	all := fake.insertsTo("lines")
	if len(all) != 2 || all[1].Token == first[0].Token || !strings.HasPrefix(all[1].Token, tp+"@") || !strings.HasSuffix(all[1].Token, ":0") {
		t.Fatalf("tokens %q then %q", first[0].Token, all[len(all)-1].Token)
	}
}

// claude.files keeps text, so a tool result that is not UTF-8 (a fetched PDF,
// a binary dump) also goes to claude.home_files as base64, and restore writes
// that copy, byte for byte.
func TestBinaryToolResultsComeBackByteForByte(t *testing.T) {
	fake, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	rel := ".claude/projects/-home-emo-code/5e55/tool-results/fetch.pdf"
	bin := []byte("%PDF-1.7\n\xe2\x28\xa1\x00\xff binary")
	os.MkdirAll(filepath.Dir(filepath.Join(home, rel)), 0o755)
	os.WriteFile(filepath.Join(home, rel), bin, 0o600)
	txt := ".claude/projects/-home-emo-code/5e55/tool-results/out.txt"
	os.WriteFile(filepath.Join(home, txt), []byte("plain text"), 0o600)
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	var copies int
	for _, r := range fake.rows("home_files") {
		if strings.Contains(r["path"].(string), "/tool-results/") {
			copies++
			if r["path"] != rel || r["encoding"] != "base64" {
				t.Errorf("unexpected home_files copy %v", r)
			}
		}
	}
	if copies != 1 {
		t.Fatalf("want one base64 copy of the binary tool result, got %d", copies)
	}
	dest := t.TempDir()
	st, err := runRestore(newMemSource(fake), "emo", "", &dirSink{root: dest}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(dest, rel)); string(got) != string(bin) {
		t.Fatalf("binary tool result %q, want %q", got, bin)
	}
	if got, _ := os.ReadFile(filepath.Join(dest, txt)); string(got) != "plain text" {
		t.Fatalf("text tool result %q", got)
	}
	if st.Skipped != 0 {
		t.Fatalf("the text copy of the binary file must not count as kept: %+v", st)
	}
}
