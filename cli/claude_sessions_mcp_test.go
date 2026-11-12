package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const liveCodexTOML = `model = "gpt-5.5"

[projects."/home/emo/code"]
trust_level = "trusted"

[mcp_servers.claude_memory]
url = "https://claude-memory.example/mcp/mcp"
http_headers = { "Authorization" = "Bearer mem-0123456789abcdef" }

[mcp_servers.ha]
url = "http://192.168.1.8:9583/private_FakeHaPath0000000000aa"

[mcp_servers.phpipam.env]
PHPIPAM_URL = "https://phpipam.example"
PHPIPAM_APP_CODE = "ipamSecretCode0123456789"

[tui]
screen_reader_detection_done = true
`

// fakeKV is Vault's KV as the MCP secrets see it.
type fakeKV map[string]map[string]string

func (f fakeKV) get(p string) (map[string]string, bool, error) {
	d, ok := f[p]
	return d, ok, nil
}

func (f fakeKV) put(p string, d map[string]string) error {
	f[p] = d
	return nil
}

// restoredCopy is what a rebuilt box holds after the session-store restore:
// the stored, redacted copy written without its redacted keys.
func restoredCopy(t *testing.T, rel string, live []byte) []byte {
	t.Helper()
	in := live
	if rel == claudeJSONRel {
		r, ok := reduceClaudeJSON(live)
		if !ok {
			t.Fatal("reduce")
		}
		in = r
	}
	red, _ := redactSettings(filepath.Base(rel), in)
	return withoutRedacted(filepath.Base(rel), red)
}

func TestCaptureKeepsOnlySecretBearingEntries(t *testing.T) {
	c, err := captureClaudeMCP([]byte(liveClaudeJSON))
	if err != nil {
		t.Fatal(err)
	}
	if c.Servers["paperless"] == nil || c.Servers["ha"] == nil || c.Servers["playwright"] != nil {
		t.Errorf("servers %v", c.Servers)
	}
	if c.Projects["/home/emo/tv"]["tvdb"] == nil || c.Projects["/home/emo/code"] != nil {
		t.Errorf("projects %v", c.Projects)
	}
	blocks := captureCodexMCP([]byte(liveCodexTOML))
	for _, h := range []string{"[mcp_servers.claude_memory]", "[mcp_servers.ha]", "[mcp_servers.phpipam.env]"} {
		if blocks[h] == "" {
			t.Errorf("%s not kept: %v", h, blocks)
		}
	}
	if _, ok := blocks["[tui]"]; ok || len(blocks) != 3 {
		t.Errorf("blocks %v", blocks)
	}
	if !strings.Contains(blocks["[mcp_servers.ha]"], "private_FakeHaPath0000000000aa") {
		t.Errorf("ha block %q", blocks["[mcp_servers.ha]"])
	}
}

// The restored, redacted files get their secrets back from Vault, byte for
// byte where it matters; a second fill changes nothing.
func TestFillPutsSecretsBack(t *testing.T) {
	kv := fakeKV{}
	live := t.TempDir()
	os.WriteFile(filepath.Join(live, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	os.MkdirAll(filepath.Join(live, ".codex"), 0o700)
	os.WriteFile(filepath.Join(live, ".codex/config.toml"), []byte(liveCodexTOML), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", live); err != nil {
		t.Fatal(err)
	}
	stored := kv["secret/workstation/emo/mcp"]
	if stored["claude_json"] == "" || stored["codex_config_toml"] == "" {
		t.Fatalf("vault %v", stored)
	}

	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".codex"), 0o700)
	os.WriteFile(filepath.Join(home, ".claude.json"), restoredCopy(t, claudeJSONRel, []byte(liveClaudeJSON)), 0o600)
	os.WriteFile(filepath.Join(home, ".codex/config.toml"), restoredCopy(t, codexConfigRel, []byte(liveCodexTOML)), 0o600)
	res, err := fillMCPSecrets(kv, "emo", home, directWriter{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Filled) != 6 || len(res.Differ) != 0 {
		t.Fatalf("filled %v differ %v", res.Filled, res.Differ)
	}
	var got map[string]any
	b, _ := os.ReadFile(filepath.Join(home, ".claude.json"))
	json.Unmarshal(b, &got)
	pl := got["mcpServers"].(map[string]any)["paperless"].(map[string]any)["env"].(map[string]any)
	if pl["PAPERLESS_API_KEY"] != "fake-paperless-key" || pl["PAPERLESS_URL"] != "https://paperless.example" {
		t.Errorf("paperless env %v", pl)
	}
	if u := got["mcpServers"].(map[string]any)["ha"].(map[string]any)["url"]; u != "http://192.168.1.8:9583/private_FakeHaPath0000000000aa" {
		t.Errorf("ha url %v", u)
	}
	if got["hasCompletedOnboarding"] != true {
		t.Error("the rest of the file was lost")
	}
	toml, _ := os.ReadFile(filepath.Join(home, ".codex/config.toml"))
	if string(toml) != liveCodexTOML {
		t.Errorf("config.toml not back to the live copy:\n%s", toml)
	}
	if fi, _ := os.Stat(filepath.Join(home, ".claude.json")); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", fi.Mode())
	}
	res, err = fillMCPSecrets(kv, "emo", home, directWriter{})
	if err != nil || len(res.Filled) != 0 || len(res.Differ) != 0 {
		t.Fatalf("second fill %+v %v", res, err)
	}
}

// On the live box nothing is touched: a value the user changed since the
// capture (a rotated key, a new URL) is theirs, and a server they removed
// stays removed.
func TestFillLeavesLiveFilesAlone(t *testing.T) {
	kv := fakeKV{}
	live := t.TempDir()
	os.WriteFile(filepath.Join(live, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", live); err != nil {
		t.Fatal(err)
	}
	rotated := strings.Replace(liveClaudeJSON, "fake-paperless-key", "fake-paperless-key-2", 1)
	rotated = strings.Replace(rotated, `"ha": {"type": "http", "url": "http://192.168.1.8:9583/private_FakeHaPath0000000000aa"},`, "", 1)
	os.WriteFile(filepath.Join(live, ".claude.json"), []byte(rotated), 0o600)
	before, _ := os.ReadFile(filepath.Join(live, ".claude.json"))
	res, err := fillMCPSecrets(kv, "emo", live, directWriter{})
	if err != nil || len(res.Filled) != 0 {
		t.Fatalf("%+v %v", res, err)
	}
	if after, _ := os.ReadFile(filepath.Join(live, ".claude.json")); string(after) != string(before) {
		t.Error("a live file was rewritten")
	}
	// A restored entry whose non-secret part no longer matches Vault's copy
	// is reported, not guessed at.
	home := t.TempDir()
	moved := strings.Replace(liveClaudeJSON, "https://paperless.example", "https://paperless2.example", 1)
	os.WriteFile(filepath.Join(home, ".claude.json"), restoredCopy(t, claudeJSONRel, []byte(moved)), 0o600)
	res, err = fillMCPSecrets(kv, "emo", home, directWriter{})
	if err != nil || len(res.Differ) != 1 || !strings.Contains(res.Differ[0], "paperless") {
		t.Fatalf("%+v %v", res, err)
	}
}

// Capture refuses a file that still holds placeholders, so a rebuilt box
// whose fill has not run cannot overwrite Vault with its blanks; and it
// merges, so a server kept earlier survives a capture that lacks it.
func TestCaptureRefusesRestoredFilesAndMerges(t *testing.T) {
	kv := fakeKV{}
	home := t.TempDir()
	os.WriteFile(filepath.Join(home, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", home); err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(home, ".codex"), 0o700)
	os.WriteFile(filepath.Join(home, ".codex/config.toml"), []byte("[mcp_servers.ha]\nurl = \"http://x/<redacted>\"\n"), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", home); err == nil || !strings.Contains(err.Error(), "<redacted>") {
		t.Fatalf("want a refusal, got %v", err)
	}
	os.Remove(filepath.Join(home, ".codex/config.toml"))
	only := `{"mcpServers":{"ha":{"type":"http","url":"http://192.168.1.8:9583/private_NEWFakeHaPath000000"}}}`
	os.WriteFile(filepath.Join(home, ".claude.json"), []byte(only), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", home); err != nil {
		t.Fatal(err)
	}
	var c claudeMCPSecrets
	json.Unmarshal([]byte(kv["secret/workstation/emo/mcp"]["claude_json"]), &c)
	if c.Servers["paperless"] == nil || !strings.Contains(c.Servers["ha"].(map[string]any)["url"].(string), "private_NEW") {
		t.Fatalf("merged %v", c.Servers)
	}
	names, err := listMCPSecrets(kv, "emo")
	if err != nil || strings.Contains(strings.Join(names, " "), "private_") || len(names) < 3 {
		t.Fatalf("list %v %v", names, err)
	}
}

func TestRestorePathsOnly(t *testing.T) {
	src, _ := ingestFixture(t)
	dest := t.TempDir()
	st, err := runRestore(onlyPaths(src, []string{".claude/settings.json"}), "emo", "", &dirSink{root: dest}, 100)
	if err != nil || st.Written != 1 {
		t.Fatalf("%+v %v", st, err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".claude/settings.json")); err != nil {
		t.Fatal(err)
	}
}

// fill names, by label only, every entry Vault keeps that the file lacks:
// a server lost to the ~/.claude.json clobber race comes back by hand.
func TestFillReportWarnsAboutAbsentEntries(t *testing.T) {
	var out strings.Builder
	reportFill(&out, "emo", fillResult{
		Filled: []string{".claude.json mcpServers.paperless"},
		Differ: []string{".codex/config.toml [mcp_servers.ha]"},
		Absent: []string{".claude.json mcpServers.tvdb"},
	})
	got := out.String()
	for _, want := range []string{
		"mcp-secrets fill user=emo: secrets put back: .claude.json mcpServers.paperless\n",
		"mcp-secrets fill user=emo: WARN the restored entry differs from the Vault copy, fill by hand: .codex/config.toml [mcp_servers.ha]\n",
		"mcp-secrets fill user=emo: WARN kept in Vault but not in the file, add it back by hand: .claude.json mcpServers.tvdb\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	kv := fakeKV{}
	live := t.TempDir()
	os.WriteFile(filepath.Join(live, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", live); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	lost := strings.Replace(liveClaudeJSON, `"ha": {"type": "http", "url": "http://192.168.1.8:9583/private_FakeHaPath0000000000aa"},`, "", 1)
	os.WriteFile(filepath.Join(home, ".claude.json"), restoredCopy(t, claudeJSONRel, []byte(lost)), 0o600)
	res, err := fillMCPSecrets(kv, "emo", home, directWriter{})
	if err != nil || len(res.Absent) != 1 || res.Absent[0] != ".claude.json mcpServers.ha" {
		t.Fatalf("%+v %v", res, err)
	}
}

// A claude session that rewrites ~/.claude.json while fill works on it does
// not lose its change: fill sees the file moved, reads it again and fills
// the new copy.
func TestFillRereadsAFileThatChangedUnderIt(t *testing.T) {
	kv := fakeKV{}
	live := t.TempDir()
	os.WriteFile(filepath.Join(live, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	if _, err := captureMCPSecrets(kv, "emo", live); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	p := filepath.Join(home, ".claude.json")
	os.WriteFile(p, restoredCopy(t, claudeJSONRel, []byte(liveClaudeJSON)), 0o600)
	calls := 0
	mcpFillBeforeWrite = func(rel string) {
		calls++
		if calls == 1 {
			b, _ := os.ReadFile(p)
			var m map[string]any
			json.Unmarshal(b, &m)
			m["projects"].(map[string]any)["/home/emo/new"] = map[string]any{"hasTrustDialogAccepted": true}
			nb, _ := json.Marshal(m)
			os.WriteFile(p+".x", nb, 0o600)
			os.Rename(p+".x", p) // a new inode, as claude's atomic write makes
		}
	}
	defer func() { mcpFillBeforeWrite = func(string) {} }()
	res, err := fillMCPSecrets(kv, "emo", home, directWriter{})
	if err != nil || calls != 2 || len(res.Filled) != 3 {
		t.Fatalf("calls %d %+v %v", calls, res, err)
	}
	b, _ := os.ReadFile(p)
	if !strings.Contains(string(b), "/home/emo/new") || !strings.Contains(string(b), "fake-paperless-key") {
		t.Fatalf("lost a change:\n%s", b)
	}
}

// capture records a digest of each secret-bearing entry it kept, in
// ~/.claude/mcp-captured.json; the ingest compares the live entries with it
// and names the ones that are new or changed since, so an admin knows to
// capture again before a rebuild puts back a stale secret.
func TestUncapturedMCPEntries(t *testing.T) {
	kv := fakeKV{}
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".claude"), 0o700)
	os.MkdirAll(filepath.Join(home, ".codex"), 0o700)
	os.WriteFile(filepath.Join(home, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	os.WriteFile(filepath.Join(home, ".codex/config.toml"), []byte(liveCodexTOML), 0o600)
	got, err := uncapturedMCPEntries(home)
	if err != nil || len(got) != 6 {
		t.Fatalf("before any capture: %v %v", got, err)
	}
	if _, err := captureMCPSecrets(kv, "emo", home); err != nil {
		t.Fatal(err)
	}
	if err := writeCaptureDigests(home, directWriter{}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(home, ".claude", mcpCapturedName))
	if strings.Contains(string(b), "fake-paperless-key") || strings.Contains(string(b), "private_") {
		t.Fatalf("a value reached the digest file: %s", b)
	}
	if got, err := uncapturedMCPEntries(home); err != nil || len(got) != 0 {
		t.Fatalf("after capture: %v %v", got, err)
	}
	rotated := strings.Replace(liveClaudeJSON, "fake-paperless-key", "fake-paperless-key-2", 1)
	os.WriteFile(filepath.Join(home, ".claude.json"), []byte(rotated), 0o600)
	toml := strings.Replace(liveCodexTOML, "[tui]", "[mcp_servers.new]\nurl = \"https://x.example/mcp\"\nbearer_token = \"new-token-0123456789\"\n\n[tui]", 1)
	os.WriteFile(filepath.Join(home, ".codex/config.toml"), []byte(toml), 0o600)
	got, err = uncapturedMCPEntries(home)
	want := []string{".claude.json mcpServers.paperless", ".codex/config.toml [mcp_servers.new]"}
	if err != nil || strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %v want %v (%v)", got, want, err)
	}
	// A home with no MCP secrets has nothing to report.
	if got, err := uncapturedMCPEntries(t.TempDir()); err != nil || len(got) != 0 {
		t.Fatalf("empty home: %v %v", got, err)
	}
}

func TestIngestMetricsCountUncapturedMCPEntries(t *testing.T) {
	p := filepath.Join(t.TempDir(), "m.prom")
	writeIngestMetrics(p, ingestStats{MCPUncaptured: 3}, true, 0)
	b, _ := os.ReadFile(p)
	if !strings.Contains(string(b), "\nclaude_sessions_ingest_mcp_entries_uncaptured 3\n") {
		t.Fatalf("%s", b)
	}
}
