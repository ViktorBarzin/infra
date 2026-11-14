package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A live ~/.claude.json, cut down: caches, stats and the account go; the
// onboarding flags, project trust and MCP servers stay.
const liveClaudeJSON = `{
  "numStartups": 3446,
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.0",
  "installMethod": "native",
  "migrationVersion": 15,
  "opusProMigrationComplete": true,
  "hasSeenTasksHint": true,
  "oauthAccount": {"emailAddress": "someone@example.com", "accountUuid": "u-1"},
  "userID": "abc",
  "cachedGrowthBookFeatures": {"x": 1},
  "tipsHistory": {"t": 3},
  "mcpServers": {
    "paperless": {"type": "stdio", "command": "npx", "args": ["-y", "@baruchiro/paperless-mcp@1.0.0"],
      "env": {"PAPERLESS_API_KEY": "fake-paperless-key", "PAPERLESS_URL": "https://paperless.example"}},
    "ha": {"type": "http", "url": "http://192.168.1.8:9583/private_FakeHaPath0000000000aa"},
    "playwright": {"type": "stdio", "command": "/usr/local/bin/tl-browser", "args": [], "env": {}}
  },
  "projects": {
    "/home/emo/code": {"hasTrustDialogAccepted": true, "allowedTools": [], "mcpServers": {},
      "enabledMcpjsonServers": [], "disabledMcpjsonServers": [], "lastCost": 1.5, "lastSessionId": "s-1",
      "hasClaudeMdExternalIncludesApproved": false},
    "/tmp/once": {"hasTrustDialogAccepted": false, "allowedTools": [], "lastCost": 0.1},
    "/home/emo/tv": {"hasTrustDialogAccepted": true, "mcpServers": {"tvdb": {"type": "http", "url": "https://tvdb.example/mcp",
      "headers": {"Authorization": "Bearer tvdb-secret-123456"}}}}
  }
}`

func TestReduceClaudeJSONKeepsTrustAndServers(t *testing.T) {
	out, ok := reduceClaudeJSON([]byte(liveClaudeJSON))
	if !ok {
		t.Fatal("not reduced")
	}
	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"hasCompletedOnboarding", "lastOnboardingVersion", "installMethod", "migrationVersion",
		"opusProMigrationComplete", "hasSeenTasksHint", "mcpServers", "projects"} {
		if _, ok := got[k]; !ok {
			t.Errorf("%s dropped", k)
		}
	}
	for _, k := range []string{"numStartups", "oauthAccount", "userID", "cachedGrowthBookFeatures", "tipsHistory"} {
		if _, ok := got[k]; ok {
			t.Errorf("%s kept", k)
		}
	}
	projects := got["projects"].(map[string]any)
	if _, ok := projects["/tmp/once"]; ok {
		t.Error("a project with nothing worth keeping is kept")
	}
	code := projects["/home/emo/code"].(map[string]any)
	if len(code) != 1 || code["hasTrustDialogAccepted"] != true {
		t.Errorf("project /home/emo/code = %v", code)
	}
	if tv := projects["/home/emo/tv"].(map[string]any); tv["mcpServers"] == nil {
		t.Errorf("project servers dropped: %v", tv)
	}
	if _, ok := reduceClaudeJSON([]byte(`{"numStartups":`)); ok {
		t.Error("a half-written file must not be reduced")
	}
	// The same live state reduces to the same bytes, whatever the stats say.
	again, _ := reduceClaudeJSON([]byte(strings.Replace(liveClaudeJSON, `"numStartups": 3446`, `"numStartups": 3447`, 1)))
	if string(again) != string(out) {
		t.Error("reduction is not stable")
	}
}

// ~/.claude.json goes to the store reduced and redacted, is sent again only
// when the reduced copy changes, and comes back under its real name.
func TestIngestKeepsReducedClaudeJSON(t *testing.T) {
	fake, url, done := startFake(t)
	defer done()
	homes, home := agentHomeFixture(t)
	cj := filepath.Join(home, ".claude.json")
	os.WriteFile(cj, []byte(liveClaudeJSON), 0o600)
	cfg := ingestConfig{HomesRoot: homes, StatePath: filepath.Join(t.TempDir(), "state.json"),
		DB: dbConn{URL: url, User: "ingest", Password: "pw"}, Budget: 1 << 20}
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	var row map[string]any
	for _, r := range fake.rows("home_files") {
		if r["path"] == ".claude.json" {
			row = r
		}
	}
	if row == nil {
		t.Fatal(".claude.json not sent")
	}
	c := row["content"].(string)
	if row["redacted"] != true || row["kind"] != "claude.json" {
		t.Errorf("row %v", row)
	}
	for _, leak := range []string{"fake-paperless-key", "FakeHaPath0000000000aa", "tvdb-secret", "someone@example.com", "3446"} {
		if strings.Contains(c, leak) {
			t.Errorf("%q reached the store:\n%s", leak, c)
		}
	}
	if !strings.Contains(c, `"hasTrustDialogAccepted": true`) || !strings.Contains(c, "paperless-mcp@1.0.0") {
		t.Errorf("stored copy lacks trust or servers:\n%s", c)
	}

	// Claude rewrites the file on every start; only the stats changed.
	n := len(fake.rows("home_files"))
	time.Sleep(10 * time.Millisecond)
	os.WriteFile(cj+".tmp", []byte(strings.Replace(liveClaudeJSON, "3446", "3447", 1)), 0o600)
	os.Rename(cj+".tmp", cj)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	if got := len(fake.rows("home_files")); got != n {
		t.Fatalf("an unchanged reduced copy was sent again (%d new rows)", got-n)
	}
	// A new trusted project is worth a new row.
	time.Sleep(10 * time.Millisecond)
	os.WriteFile(cj, []byte(strings.Replace(liveClaudeJSON, `"/tmp/once": {"hasTrustDialogAccepted": false`, `"/tmp/once": {"hasTrustDialogAccepted": true`, 1)), 0o600)
	if _, err := runIngest(cfg); err != nil {
		t.Fatal(err)
	}
	if got := len(fake.rows("home_files")); got != n+1 {
		t.Fatalf("a trust change was not sent (%d new rows)", got-n)
	}

	// Restore into an empty home: the real name, no placeholders.
	dest := t.TempDir()
	if _, err := runRestore(newMemSource(fake), "emo", "", &dirSink{root: dest}, 100); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dest, ".claude.json"))
	if err != nil {
		t.Fatal(err)
	}
	if g := string(b); strings.Contains(g, `"<redacted>"`) || strings.Contains(g, "PAPERLESS_API_KEY") ||
		!strings.Contains(g, `"PAPERLESS_URL": "https://paperless.example"`) || !strings.Contains(g, `"/tmp/once"`) {
		t.Errorf("restored .claude.json:\n%s", g)
	}
	if !safeRel(".claude.json") || safeRel(".claude.json.backup") {
		t.Error("safeRel")
	}
}

// On a rebuild where provisioning wrote a ~/.claude.json first (claude mcp
// add playwright, the onboarding flag), the stored projects and servers are
// merged in, and a project the new file has not trusted yet takes the stored
// trust.
func TestRebuildMergesClaudeJSON(t *testing.T) {
	homes, home := agentHomeFixture(t)
	os.WriteFile(filepath.Join(home, ".claude.json"), []byte(liveClaudeJSON), 0o600)
	src := ingestHome(t, homes)

	pre := filepath.Join(t.TempDir(), "emo")
	os.MkdirAll(pre, 0o700)
	os.WriteFile(filepath.Join(pre, ".claude.json"), []byte(`{"installMethod":"native","numStartups":1,
	  "mcpServers":{"playwright":{"type":"stdio","command":"/usr/local/bin/tl-browser","args":[],"env":{}}},
	  "projects":{"/home/emo/code":{"hasTrustDialogAccepted":false,"allowedTools":[]}}}`), 0o600)
	res, err := runRebuildRestore(rebuildConfig{User: "emo", Home: pre, StatePath: filepath.Join(t.TempDir(), "state.json"), Src: src,
		Extract: untarSkipOld(pre), Overwrite: untarOverwrite(pre), PageRows: 3})
	if err != nil {
		t.Fatal(err)
	}
	merged := false
	for _, m := range res.Merged {
		merged = merged || m == ".claude.json"
	}
	if !merged {
		t.Fatalf("not merged: %+v", res)
	}
	var got map[string]any
	b, _ := os.ReadFile(filepath.Join(pre, ".claude.json"))
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got["hasCompletedOnboarding"] != true || got["numStartups"] != float64(1) {
		t.Errorf("top level %v", got)
	}
	servers := got["mcpServers"].(map[string]any)
	if servers["paperless"] == nil || servers["ha"] == nil || servers["playwright"] == nil {
		t.Errorf("servers %v", servers)
	}
	projects := got["projects"].(map[string]any)
	if p := projects["/home/emo/code"].(map[string]any); p["hasTrustDialogAccepted"] != true {
		t.Errorf("stored trust not taken: %v", p)
	}
	if projects["/home/emo/tv"] == nil {
		t.Error("stored project not merged in")
	}
}
