package main

import (
	"archive/tar"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Environment variables are judged one by one: flags survive, keys do not.
func TestRedactSettingsKeepsEnvFlags(t *testing.T) {
	in := `{"env":{"MEMORY_API_KEY":"k-123","MEMORY_KEY":"plain","DISABLE_AUTOUPDATER":"1","STATUSLINE_DISABLE_SESSION_NAME":"1",
	"MEMORY_API_URL":"https://claude-memory.example","HASH":"0123456789abcdef0123456789abcdef"},
	"mcpServers":{"m":{"headers":{"X-Plain":"short"}}}}`
	out, red := redactSettings("settings.json", []byte(in))
	s := string(out)
	if !red {
		t.Fatal("want redacted")
	}
	for _, leak := range []string{"k-123", "plain", "0123456789abcdef", "short"} {
		if strings.Contains(s, leak) {
			t.Errorf("%q survived:\n%s", leak, s)
		}
	}
	for _, keep := range []string{`"DISABLE_AUTOUPDATER": "1"`, `"STATUSLINE_DISABLE_SESSION_NAME": "1"`, `"MEMORY_API_URL": "https://claude-memory.example"`} {
		if !strings.Contains(s, keep) {
			t.Errorf("%q should be kept:\n%s", keep, s)
		}
	}
	toml := "[mcp_servers.mem.env]\nDEBUG = \"1\"\nMEMORY_KEY = \"sekrit\"\n[mcp_servers.mem]\nenv = { A = \"1\" }\n"
	got, _ := redactSettings("config.toml", []byte(toml))
	if g := string(got); !strings.Contains(g, `DEBUG = "1"`) || strings.Contains(g, "sekrit") || strings.Contains(g, `A = "1"`) {
		t.Errorf("toml env:\n%s", g)
	}
}

func TestWithoutRedacted(t *testing.T) {
	in := `{"env":{"MEMORY_API_KEY":"<redacted>","DISABLE_AUTOUPDATER":"1"},"permissions":{"allow":["<redacted>","Bash(HIK_PASSWORD=<redacted> curl)"]},"model":"opus"}`
	got := string(withoutRedacted("settings.json", []byte(in)))
	if strings.Contains(got, "MEMORY_API_KEY") || strings.Contains(got, `"<redacted>"`) || !strings.Contains(got, `"DISABLE_AUTOUPDATER": "1"`) ||
		!strings.Contains(got, "HIK_PASSWORD=<redacted> curl") || !strings.Contains(got, `"model": "opus"`) {
		t.Errorf("json:\n%s", got)
	}
	toml := "model = \"gpt-5\"\n[mcp_servers.x]\nurl = \"https://x/<redacted>\"\nbearer_token = \"<redacted>\"\nhttp_headers = { \"<redacted>\" = \"<redacted>\" }\n"
	g := string(withoutRedacted("config.toml", []byte(toml)))
	if strings.Contains(g, "bearer_token") || strings.Contains(g, "http_headers") || !strings.Contains(g, `model = "gpt-5"`) ||
		!strings.Contains(g, "[mcp_servers.x]") || !strings.Contains(g, `url = "https://x/<redacted>"`) {
		t.Errorf("toml:\n%s", g)
	}
}

// A settings file stored under the old rule is sent once more, then left
// alone again.
func TestIngestSendsSettingsAgainUnderANewRule(t *testing.T) {
	fake, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	statePath := filepath.Join(t.TempDir(), "state.json")
	cfg := ingestConfig{HomesRoot: homes, StatePath: statePath, DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	sp := filepath.Join(home, ".claude/settings.json")
	state, _ := loadState(statePath)
	if state.Files[sp].Rv != redactVersion {
		t.Fatalf("rv %d", state.Files[sp].Rv)
	}
	state.Files[sp].Rv = 0
	saveState(statePath, state)
	n := len(fake.rows("home_files"))
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	rows := fake.rows("home_files")
	if len(rows) != n+1 || rows[n]["path"] != ".claude/settings.json" {
		t.Fatalf("want settings.json sent once more, got %d new rows", len(rows)-n)
	}
	if _, err := runIngest(cfg); err != nil || len(fake.rows("home_files")) != n+1 {
		t.Fatalf("sent again on the next run: %v", err)
	}
}

// The skills lockfile, outside ~/.claude, is kept and comes back.
func TestSkillLockIsKept(t *testing.T) {
	fake, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	os.MkdirAll(filepath.Join(home, ".agents/skills"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents/.skill-lock.json"), []byte(`{"skills":{"tdd":{"source":"mattpocock/skills"}}}`), 0o644)
	os.WriteFile(filepath.Join(home, ".agents/AGENTS.md"), []byte("provisioned"), 0o644)
	if _, err := runIngest(ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if _, err := runRestore(newMemSource(fake), "emo", "", &dirSink{root: dest}, 100); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(dest, ".agents/.skill-lock.json")); err != nil || !strings.Contains(string(b), "tdd") {
		t.Fatalf("lockfile %q %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".agents/AGENTS.md")); err == nil {
		t.Fatal("only the lockfile is kept from ~/.agents")
	}
	if !safeRel(".agents/.skill-lock.json") || safeRel(".agents/AGENTS.md") {
		t.Fatal("safeRel")
	}
}

// untarOverwrite stands in for `runuser -u <user> -- tar -x`.
func untarOverwrite(root string) func(io.Reader) error {
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
				os.MkdirAll(p, 0o700)
				continue
			}
			b, _ := io.ReadAll(tr)
			if err := os.WriteFile(p, b, fs.FileMode(h.Mode)); err != nil {
				return err
			}
		}
	}
}

// ingestHome ingests homes and returns what the store would hold.
func ingestHome(t *testing.T, homes string) *memSource {
	t.Helper()
	fake, url, done := startFake(t)
	defer done()
	if _, err := runIngest(ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}); err != nil {
		t.Fatal(err)
	}
	return newMemSource(fake)
}

// On a rebuilt box with nothing there, settings.json comes back under its
// real name. When provisioning got there first (a pass whose restore failed
// wired the memory hooks into a new file), the stored keys are merged in, the
// provisioned ones stay, and the file is not recorded as sent, so the ingest
// stores the merged file. A TOML file that was there gets the copy beside it.
func TestRebuildRestoresAndMergesSettings(t *testing.T) {
	homes, home := agentHomeFixture(t)
	os.WriteFile(filepath.Join(home, ".claude/settings.json"),
		[]byte(`{"env":{"MEMORY_API_KEY":"k-1","DISABLE_AUTOUPDATER":"1"},"model":"opus","hooks":{"Stop":[{"command":"mine"}]}}`), 0o600)
	os.WriteFile(filepath.Join(home, ".codex/config.toml"), []byte("model = \"gpt-5\"\nbearer_token = \"tok-1\"\n"), 0o600)
	src := ingestHome(t, homes)

	// An empty home: everything under the real names.
	fresh := filepath.Join(t.TempDir(), "emo")
	os.MkdirAll(fresh, 0o700)
	statePath := filepath.Join(t.TempDir(), "state.json")
	res, err := runRebuildRestore(rebuildConfig{User: "emo", Home: fresh, StatePath: statePath, Src: src,
		Extract: untarSkipOld(fresh), Overwrite: untarOverwrite(fresh), PageRows: 3})
	if err != nil || res.Outcome != "restored" || len(res.Merged) != 0 || len(res.Beside) != 0 {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ := os.ReadFile(filepath.Join(fresh, ".claude/settings.json"))
	if g := string(b); !strings.Contains(g, `"DISABLE_AUTOUPDATER": "1"`) || strings.Contains(g, "MEMORY_API_KEY") || !strings.Contains(g, `"command": "mine"`) {
		t.Fatalf("settings.json %s", g)
	}
	b, _ = os.ReadFile(filepath.Join(fresh, ".codex/config.toml"))
	if g := string(b); g != "model = \"gpt-5\"\n" {
		t.Fatalf("config.toml %q", g)
	}

	// Provisioning was there first.
	pre := filepath.Join(t.TempDir(), "emo")
	os.MkdirAll(filepath.Join(pre, ".claude"), 0o700)
	os.MkdirAll(filepath.Join(pre, ".codex"), 0o700)
	os.WriteFile(filepath.Join(pre, ".claude/settings.json"), []byte(`{"fastMode":true,"hooks":{"Stop":[{"command":"wired"}]},"env":{"MEMORY_API_KEY":"vault"}}`), 0o600)
	os.WriteFile(filepath.Join(pre, ".codex/config.toml"), []byte("model = \"o3\"\n"), 0o600)
	statePath = filepath.Join(t.TempDir(), "state.json")
	res, err = runRebuildRestore(rebuildConfig{User: "emo", Home: pre, StatePath: statePath, Src: src,
		Extract: untarSkipOld(pre), Overwrite: untarOverwrite(pre), PageRows: 3})
	if err != nil || len(res.Merged) != 1 || res.Merged[0] != ".claude/settings.json" || len(res.Beside) != 1 || res.Beside[0] != ".codex/config.toml.from-store" {
		t.Fatalf("%+v %v", res, err)
	}
	b, _ = os.ReadFile(filepath.Join(pre, ".claude/settings.json"))
	g := string(b)
	for _, want := range []string{`"fastMode": true`, `"model": "opus"`, `"MEMORY_API_KEY": "vault"`, `"DISABLE_AUTOUPDATER": "1"`, `"command": "wired"`, `"command": "mine"`} {
		if !strings.Contains(g, want) {
			t.Errorf("merged settings lack %s:\n%s", want, g)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(pre, ".codex/config.toml")); string(b) != "model = \"o3\"\n" {
		t.Errorf("the TOML that was there was changed: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(pre, ".codex/config.toml.from-store")); string(b) != "model = \"gpt-5\"\n" {
		t.Errorf("beside copy %q", b)
	}
	state, _ := loadState(statePath)
	if state.Files[filepath.Join(pre, ".claude/settings.json")] != nil {
		t.Error("a merged file must not be recorded as sent")
	}
	if s := state.Files[filepath.Join(pre, ".claude/plans/p.md")]; s == nil {
		t.Error("restored files are still recorded")
	}
}

// A restore cut off mid-stream takes back what it wrote, so the retry writes
// whole files instead of keeping a cut one. What was there first stays.
func TestRebuildRemovesWhatAFailedAttemptWrote(t *testing.T) {
	src, orig := ingestFixture(t)
	home := filepath.Join(t.TempDir(), "emo")
	os.MkdirAll(filepath.Join(home, ".claude"), 0o700)
	os.WriteFile(filepath.Join(home, ".claude/history.jsonl"), []byte("mine\n"), 0o600)
	statePath := filepath.Join(t.TempDir(), "state.json")
	remove := func(rels []string) error {
		for _, r := range rels {
			os.Remove(filepath.Join(home, r))
		}
		return nil
	}
	// Writes two whole files, then half of the third, then fails.
	cut := func(r io.Reader) error {
		tr := tar.NewReader(r)
		files := 0
		for {
			h, err := tr.Next()
			if err != nil {
				return err
			}
			p := filepath.Join(home, filepath.FromSlash(h.Name))
			if h.Typeflag == tar.TypeDir {
				os.MkdirAll(p, 0o700)
				continue
			}
			b, _ := io.ReadAll(tr)
			if files == 2 {
				os.WriteFile(p, b[:len(b)/2], 0o600)
				io.Copy(io.Discard, r)
				return errors.New("tar: connection reset")
			}
			os.WriteFile(p, b, 0o600)
			files++
		}
	}
	if _, err := runRebuildRestore(rebuildConfig{User: "emo", Home: home, StatePath: statePath, Src: src,
		Extract: cut, Overwrite: untarOverwrite(home), Remove: remove, PageRows: 2}); err == nil {
		t.Fatal("want the extract error")
	}
	var left []string
	filepath.WalkDir(home, func(p string, d fs.DirEntry, _ error) error {
		if !d.IsDir() {
			left = append(left, p)
		}
		return nil
	})
	if len(left) != 1 || left[0] != filepath.Join(home, ".claude/history.jsonl") {
		t.Fatalf("files left after a failed attempt: %v", left)
	}
	res, err := runRebuildRestore(rebuildConfig{User: "emo", Home: home, StatePath: statePath, Src: src,
		Extract: untarSkipOld(home), Overwrite: untarOverwrite(home), Remove: remove, PageRows: 2})
	if err != nil || res.Outcome != "restored" {
		t.Fatalf("retry %+v %v", res, err)
	}
	want, _ := os.ReadFile(filepath.Join(orig, ".claude/projects/-home-emo-code/5e55.jsonl"))
	if got, _ := os.ReadFile(filepath.Join(home, ".claude/projects/-home-emo-code/5e55.jsonl")); string(got) != string(want) {
		t.Fatalf("transcript after retry %q", got)
	}
}

// A user whose restore never ran is exported, so an alert can say so.
func TestIngestMetricsCountUsersWaiting(t *testing.T) {
	p := filepath.Join(t.TempDir(), "claude_sessions.prom")
	writeIngestMetrics(p, ingestStats{UsersWaiting: 2}, true, 0)
	b, _ := os.ReadFile(p)
	if !strings.Contains(string(b), "\nclaude_sessions_ingest_users_waiting_for_restore 2\n") {
		t.Fatalf("metrics:\n%s", b)
	}
}
