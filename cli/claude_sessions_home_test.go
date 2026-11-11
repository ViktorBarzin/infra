package main

import (
	"encoding/base64"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClassifyHomeFile(t *testing.T) {
	home := "/home/emo"
	cases := []struct {
		rel  string
		want homeClass
	}{
		{".claude/history.jsonl", homeAppend},
		{".claude/plans/fizzy-hopper.md", homeWhole},
		{".claude/tasks/session-1/1.json", homeWhole},
		{".claude/teams/t/config.json", homeWhole},
		{".claude/todos/abc.json", homeWhole},
		{".claude/file-history/5e55/e60a92f5d6383a03@v1", homeWhole},
		{".claude/remote/remote-server.log", homeWhole},
		{".claude/settings.json", homeWhole},
		{".claude/projects/-home-emo-code/5e55.jsonl", homeTranscript},
		{".claude/projects/-home-emo-code/5e55/subagents/workflows/wf_1/agent-a.jsonl", homeTranscript},
		{".claude/projects/-home-emo-code/5e55/workflows/wf_1.json", homeWhole},
		{".claude/projects/-home-emo-code/memory/MEMORY.md", homeWhole},
		{".codex/sessions/2026/11/01/rollout-2026-11-01T10-00-00-abc.jsonl", homeAppend},
		{".codex/session_index.jsonl", homeAppend},
		{".codex/config.toml", homeWhole},
		{".codex/state_5.sqlite", homeWhole},
		// credentials
		{".claude/.credentials.json", homeSkip},
		{".claude/.credentials.json.bak-20260622", homeSkip},
		{".codex/auth.json", homeSkip},
		{".claude/sessions/1217656.10723c.key", homeSkip},
		{".claude/state/github-token.txt", homeSkip},
		{".claude/x/client_secret.json", homeSkip},
		// caches and runtime files
		{".codex/logs_2.sqlite", homeSkip},
		{".codex/logs_2.sqlite-wal", homeSkip},
		{".codex/state_5.sqlite-shm", homeSkip},
		{".codex/models_cache.json", homeSkip},
		{".codex/auth.lock", homeSkip},
		{".claude/policy-limits.json.stamp.json.tmp.0398e2d9", homeSkip},
		{".claude/remote-settings.json", homeSkip},
		{".claude/plugins/plugin-catalog-cache.json", homeSkip},
		{".claude/remote/server", homeSkip},
	}
	for _, c := range cases {
		got, _ := classifyHomeFile(home, filepath.Join(home, c.rel), c.rel)
		if got != c.want {
			t.Errorf("%s: got %d, want %d", c.rel, got, c.want)
		}
	}
}

func TestSkipHomeDir(t *testing.T) {
	for _, d := range []string{".claude/cache", ".claude/session-env", ".claude/backups", ".claude/sessions",
		".claude/plugins/marketplaces", ".claude/remote/ccd-cli", ".codex/packages", ".codex/plugins/cache",
		".claude/skills/x/node_modules", ".claude/hooks/__pycache__", ".claude/skills/y/.git"} {
		if !skipHomeDir(d) {
			t.Errorf("%s should be pruned", d)
		}
	}
	for _, d := range []string{".claude/plans", ".claude/file-history", ".claude/remote", ".claude/remote/run", ".codex/sessions", ".claude/plugins"} {
		if skipHomeDir(d) {
			t.Errorf("%s should be walked", d)
		}
	}
}

func TestRedactSettingsJSON(t *testing.T) {
	in := `{"env":{"MEMORY_API_KEY":"k-123","EDITOR":"vim","GH_PAT":"ghp_x"},
	"permissions":{"allow":["Bash(HIK_PASSWORD=hunter2 curl -s http://cam)","Bash(ls)"]},
	"mcpServers":{"m":{"url":"https://u:pw@host/x","headers":{"X-Custom":"abc"}}},
	"model":"opus","apiKeyHelper":"/bin/key"}`
	out, red := redactSettings("settings.json", []byte(in))
	if !red {
		t.Fatal("secrets present, redacted must be true")
	}
	s := string(out)
	for _, leak := range []string{"k-123", "ghp_x", "hunter2", "abc", ":pw@", "/bin/key"} {
		if strings.Contains(s, leak) {
			t.Errorf("%q survived redaction:\n%s", leak, s)
		}
	}
	for _, keep := range []string{`"model": "opus"`, `Bash(ls)`, `HIK_PASSWORD=<redacted>`, `curl -s http://cam`} {
		if !strings.Contains(s, keep) {
			t.Errorf("%q should be kept:\n%s", keep, s)
		}
	}
	clean := `{"model":"opus","hooks":{}}`
	got, red := redactSettings("settings.json", []byte(clean))
	if red || string(got) != clean {
		t.Fatalf("a file with no secrets must be sent as is, got %v %q", red, got)
	}
}

func TestRedactSettingsTOML(t *testing.T) {
	in := strings.Join([]string{
		`model = "gpt-5"`,
		`[mcp_servers.mem]`,
		`url = "https://mem/x"`,
		`[mcp_servers.ha]`,
		`url = "https://ha.example/api/mcp/private_Fak3HaPathXq-zz0000000"`,
		`http_headers = { "Authorization" = "Bearer abcdefgh123", "X-Id" = "7" }`,
		`[mcp_servers.mem.env]`,
		`MEMORY_KEY = "sekrit"`,
		`[profiles.x]`,
		`bearer_token = "tok-999"`,
		`approval = "never"`,
	}, "\n")
	out, red := redactSettings("config.toml", []byte(in))
	s := string(out)
	if !red {
		t.Fatal("want redacted")
	}
	for _, leak := range []string{"abcdefgh123", "sekrit", "tok-999", "Fak3HaPathXq"} {
		if strings.Contains(s, leak) {
			t.Errorf("%q survived:\n%s", leak, s)
		}
	}
	for _, keep := range []string{`model = "gpt-5"`, `url = "https://mem/x"`, `approval = "never"`, `https://ha.example/api/mcp/`} {
		if !strings.Contains(s, keep) {
			t.Errorf("%q should be kept:\n%s", keep, s)
		}
	}
}

func agentHomeFixture(t *testing.T) (homes string, home string) {
	t.Helper()
	homes = t.TempDir()
	home = filepath.Join(homes, "emo")
	files := map[string]string{
		".claude/history.jsonl":                                  `{"display":"hi","timestamp":1}` + "\n",
		".claude/plans/p.md":                                     "# plan\n",
		".claude/file-history/5e55/abc@v1":                       "\x00\x01binary\xff",
		".claude/settings.json":                                  `{"env":{"MEMORY_API_KEY":"k-1"},"model":"opus"}`,
		".claude/.credentials.json":                              `{"claudeAiOauth":{"accessToken":"sk-ant"}}`,
		".claude/cache/changelog.md":                             "cache",
		".claude/projects/-home-emo-code/5e55.jsonl":             `{"type":"user","timestamp":"2026-10-01T10:00:00Z"}` + "\n",
		".claude/projects/-home-emo-code/5e55/workflows/wf.json": `{"wf":1}`,
		".codex/sessions/2026/11/01/rollout-x.jsonl":             `{"type":"session_meta"}` + "\n",
		".codex/auth.json":                                       `{"tokens":{}}`,
		".codex/logs_2.sqlite":                                   "log",
	}
	for rel, body := range files {
		p := filepath.Join(home, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	return homes, home
}

func TestIngestHomeFiles(t *testing.T) {
	fake, srvURL, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: srvURL, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	st, err := runIngest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if st.Users != 1 {
		t.Fatalf("users = %d", st.Users)
	}
	files := map[string]map[string]any{}
	for _, r := range fake.rows("home_files") {
		files[r["path"].(string)] = r
	}
	for _, want := range []string{".claude/plans/p.md", ".claude/file-history/5e55/abc@v1", ".claude/settings.json",
		".claude/projects/-home-emo-code/5e55/workflows/wf.json"} {
		if files[want] == nil {
			t.Errorf("%s not sent; got %v", want, sortedPaths(files))
		}
	}
	for _, never := range []string{".claude/.credentials.json", ".claude/cache/changelog.md", ".codex/auth.json", ".codex/logs_2.sqlite"} {
		if files[never] != nil {
			t.Errorf("%s must never be sent", never)
		}
	}
	if b := files[".claude/file-history/5e55/abc@v1"]; b != nil {
		raw, _ := base64.StdEncoding.DecodeString(b["content"].(string))
		if b["encoding"] != "base64" || string(raw) != "\x00\x01binary\xff" {
			t.Errorf("binary file not kept byte for byte: %v", b)
		}
	}
	if s := files[".claude/settings.json"]; s != nil && (s["redacted"] != true || strings.Contains(s["content"].(string), "k-1")) {
		t.Errorf("settings sent with its secret: %v", s)
	}
	if p := files[".claude/plans/p.md"]; p != nil && (p["mode"].(float64) != 0o640 || p["kind"] != "claude:plans") {
		t.Errorf("mode or kind wrong: %v", p)
	}
	lines := map[string]int{}
	for _, r := range fake.rows("home_lines") {
		lines[r["path"].(string)]++
		if r["generation"] == "" {
			t.Errorf("line without generation: %v", r)
		}
	}
	if lines[".claude/history.jsonl"] != 1 || lines[".codex/sessions/2026/11/01/rollout-x.jsonl"] != 1 {
		t.Errorf("home lines = %v", lines)
	}
	if len(fake.rows("lines")) != 1 {
		t.Errorf("the transcript must still go to claude.lines, got %v", fake.rows("lines"))
	}
	if n := len(fake.insertsTo("home_files")); n != 1 {
		t.Errorf("whole files should share one INSERT, got %d", n)
	}

	// Nothing changed: nothing is sent.
	before := len(fake.inserts)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	if len(fake.inserts) != before {
		t.Fatalf("unchanged home files re-sent: %+v", fake.inserts[before:])
	}

	// An append sends one line in the same generation; a rewrite starts a new one.
	hist := filepath.Join(home, ".claude", "history.jsonl")
	gen1 := fake.rows("home_lines")[0]["generation"]
	f, _ := os.OpenFile(hist, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"display":"again","timestamp":2}` + "\n")
	f.Close()
	time.Sleep(10 * time.Millisecond)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	newRows := fake.rowsSince("home_lines", before)
	if len(newRows) != 1 || newRows[0]["byte_offset"].(float64) != 31 || newRows[0]["generation"] != gen1 {
		t.Fatalf("append: %v (gen1 %v)", newRows, gen1)
	}
	before = len(fake.inserts)
	os.WriteFile(hist, []byte(`{"x":1}`+"\n"), 0o600)
	time.Sleep(10 * time.Millisecond)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	newRows = fake.rowsSince("home_lines", before)
	if len(newRows) != 1 || newRows[0]["byte_offset"].(float64) != 0 || newRows[0]["generation"] == gen1 {
		t.Fatalf("rewrite should start a new generation at 0: %v", newRows)
	}
}

func sortedPaths(m map[string]map[string]any) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func startFake(t *testing.T) (*fakeClickHouse, string, func()) {
	fake := &fakeClickHouse{}
	srv := httptest.NewServer(fake.handler(t))
	return fake, srv.URL, srv.Close
}

func (f *fakeClickHouse) insertsTo(table string) []recordedInsert {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []recordedInsert
	for _, i := range f.inserts {
		if strings.Contains(i.Query, "INTO claude."+table+" ") {
			out = append(out, i)
		}
	}
	return out
}

func (f *fakeClickHouse) rowsSince(table string, from int) []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []map[string]any
	for _, i := range f.inserts[from:] {
		if strings.Contains(i.Query, "INTO claude."+table+" ") {
			out = append(out, i.Rows...)
		}
	}
	return out
}
