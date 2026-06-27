package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestVaultCommandsRegistered(t *testing.T) {
	want := map[string]Tier{
		"vault setup":  TierWrite,
		"vault status": TierRead,
		"vault list":   TierRead,
		"vault get":    TierRead,
		"vault search": TierRead,
		"vault code":   TierRead,
		"vault lock":   TierWrite,
	}
	got := map[string]Tier{}
	for _, c := range vaultCommands() {
		got[c.name()] = c.Tier
	}
	for name, tier := range want {
		if got[name] != tier {
			t.Errorf("command %q: tier=%q, want %q (registered=%v)", name, got[name], tier, got[name] != "")
		}
	}
}

func TestVaultGroupInRegistry(t *testing.T) {
	if !isCommandGroup(buildRegistry(), "vault") {
		t.Fatal("`vault` group not wired into buildRegistry()")
	}
}

func TestVaultCredsPath(t *testing.T) {
	if got := vwCredsPath("emo"); got != "secret/workstation/claude-users/emo" {
		t.Fatalf("vwCredsPath = %q", got)
	}
}

func TestBwAppDataDir(t *testing.T) {
	if got := bwAppDataDir("1001"); got != "/run/user/1001/homelab-bw" {
		t.Fatalf("bwAppDataDir = %q", got)
	}
}

// fakeRunner records calls and returns canned stdout/err keyed by argv[0]+first arg.
type fakeRunner struct {
	calls   [][]string
	out     map[string]string // key: name+" "+strings.Join(argv," ") prefix-matched
	err     map[string]error
	lastEnv []string
}

func (f *fakeRunner) run(name string, argv, envv []string) (string, error) {
	f.calls = append(f.calls, append([]string{name}, argv...))
	f.lastEnv = envv
	key := name + " " + strings.Join(argv, " ")
	for k, v := range f.out {
		if strings.HasPrefix(key, k) {
			return v, f.err[k]
		}
	}
	return "", f.err[key]
}

func TestLoadCredsReadsFourFields(t *testing.T) {
	f := &fakeRunner{out: map[string]string{
		"vault kv get -field=vaultwarden_email secret/workstation/claude-users/emo":           "emo@x.me",
		"vault kv get -field=vaultwarden_master_password secret/workstation/claude-users/emo": "hunter2",
		"vault kv get -field=vaultwarden_client_id secret/workstation/claude-users/emo":       "user.abc",
		"vault kv get -field=vaultwarden_client_secret secret/workstation/claude-users/emo":   "sek",
	}}
	c, err := loadCreds(f.run, "emo")
	if err != nil {
		t.Fatalf("loadCreds: %v", err)
	}
	want := vwCreds{Email: "emo@x.me", MasterPassword: "hunter2", ClientID: "user.abc", ClientSecret: "sek"}
	if !reflect.DeepEqual(c, want) {
		t.Fatalf("loadCreds = %+v want %+v", c, want)
	}
}

func TestLoadCredsUnconfigured(t *testing.T) {
	f := &fakeRunner{out: map[string]string{}} // every field empty
	if _, err := loadCreds(f.run, "emo"); err == nil || !strings.Contains(err.Error(), "not configured") {
		t.Fatalf("want 'not configured' error, got %v", err)
	}
}

func TestBwEnvCarriesSecretsNotArgv(t *testing.T) {
	c := vwCreds{ClientID: "user.abc", ClientSecret: "sek", MasterPassword: "hunter2"}
	env := bwSecretEnv("/run/user/1001/homelab-bw", c, "SESSIONKEY")
	joined := strings.Join(env, "\n")
	for _, want := range []string{
		"BW_CLIENTID=user.abc", "BW_CLIENTSECRET=sek", "BW_PASSWORD=hunter2",
		"BW_SESSION=SESSIONKEY", "BITWARDENCLI_APPDATA_DIR=/run/user/1001/homelab-bw",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("bwSecretEnv missing %q", want)
		}
	}
	if strings.Contains(joined, "PATH=") == false {
		t.Error("bwSecretEnv must keep a PATH so node/bw resolve")
	}
}

func TestBwGetArgsHasNoSessionInArgv(t *testing.T) {
	argv := bwGetArgs("password", "github")
	for _, a := range argv {
		if strings.Contains(a, "SESSION") || a == "--session" {
			t.Fatalf("session must travel via env, not argv: %v", argv)
		}
	}
	if !reflect.DeepEqual(argv, []string{"get", "password", "github"}) {
		t.Fatalf("bwGetArgs = %v", argv)
	}
}

func TestBwListArgs(t *testing.T) {
	if got := bwListArgs(""); !reflect.DeepEqual(got, []string{"list", "items"}) {
		t.Fatalf("bwListArgs('') = %v", got)
	}
	if got := bwListArgs("git"); !reflect.DeepEqual(got, []string{"list", "items", "--search", "git"}) {
		t.Fatalf("bwListArgs('git') = %v", got)
	}
}

func TestBwUnlockReturnsSession(t *testing.T) {
	f := &fakeRunner{out: map[string]string{"bw unlock": "THE-SESSION-KEY"}}
	env := bwSecretEnv("/run/user/1001/homelab-bw", vwCreds{MasterPassword: "pw"}, "")
	sess, err := bwUnlock(f.run, env)
	if err != nil || sess != "THE-SESSION-KEY" {
		t.Fatalf("bwUnlock = %q, %v", sess, err)
	}
	// argv must use --passwordenv + --raw, never the password literal
	last := f.calls[len(f.calls)-1]
	if strings.Join(last, " ") != "bw unlock --passwordenv BW_PASSWORD --raw" {
		t.Fatalf("unlock argv = %v", last)
	}
}

func TestReturnMode(t *testing.T) {
	if returnMode(true) != "clipboard" || returnMode(false) != "stdout" {
		t.Fatal("returnMode wrong")
	}
}

func TestOSC52Encode(t *testing.T) {
	got := osc52("secret")
	want := "\x1b]52;c;" + base64.StdEncoding.EncodeToString([]byte("secret")) + "\a"
	if got != want {
		t.Fatalf("osc52 = %q want %q", got, want)
	}
	if osc52clear() != "\x1b]52;c;\a" {
		t.Fatalf("osc52clear wrong: %q", osc52clear())
	}
}

func TestTerminalAllowed(t *testing.T) {
	allow := []struct{ term, prog string }{
		{"xterm-kitty", ""}, {"alacritty", ""}, {"foot", ""}, {"tmux-256color", ""},
		{"screen-256color", ""}, {"xterm-256color", "WezTerm"}, {"xterm-256color", "ghostty"},
	}
	for _, c := range allow {
		if !terminalAllowed(c.term, c.prog) {
			t.Errorf("terminalAllowed(%q,%q) = false, want true", c.term, c.prog)
		}
	}
	deny := []struct{ term, prog string }{{"dumb", ""}, {"", ""}, {"vt100", ""}}
	for _, c := range deny {
		if terminalAllowed(c.term, c.prog) {
			t.Errorf("terminalAllowed(%q,%q) = true, want false", c.term, c.prog)
		}
	}
}

func TestOpLogLineHasNoSecretOrItem(t *testing.T) {
	line := opLogLine(opRecord{User: "emo", Verb: "get", PID: 10, PPID: 9, ParentComm: "claude", ItemName: "Chase Bank"})
	for _, must := range []string{"user=emo", "verb=get", "ppid=9", "parent=claude"} {
		if !strings.Contains(line, must) {
			t.Errorf("op-log missing %q: %s", must, line)
		}
	}
	for _, mustNot := range []string{"Chase", "password", "secret"} {
		if strings.Contains(line, mustNot) {
			t.Fatalf("op-log LEAKS %q (privacy violation): %s", mustNot, line)
		}
	}
}

func TestLockPath(t *testing.T) {
	if got := vaultLockPath("1001"); got != "/run/user/1001/homelab-vault.lock" {
		t.Fatalf("vaultLockPath = %q", got)
	}
}

func TestParseGetArgs(t *testing.T) {
	o, err := parseGetArgs([]string{"github", "--field", "username", "--json"})
	if err != nil || o.name != "github" || o.field != "username" || !o.json {
		t.Fatalf("parseGetArgs = %+v err=%v", o, err)
	}
	d, _ := parseGetArgs([]string{"github"})
	if d.field != "password" || d.json {
		t.Fatalf("defaults wrong: %+v", d)
	}
	if _, err := parseGetArgs([]string{}); err == nil {
		t.Fatal("get with no name must error")
	}
	if _, err := parseGetArgs([]string{"x", "--field", "evil"}); err == nil {
		t.Fatal("invalid --field must error")
	}
}

func TestListNamesParsing(t *testing.T) {
	// bw list items returns JSON; listNames extracts name + id only.
	js := `[{"id":"1","name":"GitHub","login":{"username":"u"}},{"id":"2","name":"AWS"}]`
	names := listNames(js)
	if len(names) != 2 || names[0] != "GitHub (1)" || names[1] != "AWS (2)" {
		t.Fatalf("listNames = %v", names)
	}
}

func TestStatusSummaryUnconfigured(t *testing.T) {
	f := &fakeRunner{out: map[string]string{}} // no creds
	s := statusSummary(f.run, "emo", "1001")
	if !strings.Contains(s, "not configured") {
		t.Fatalf("status = %q", s)
	}
}

func TestEnsureVaultTokenSetsScopedFallback(t *testing.T) {
	dir := t.TempDir()
	cfg := dir + "/.config/claude-auth-sync"
	if err := os.MkdirAll(cfg, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg+"/vault-token", []byte("SCOPED-TOK\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", dir)
	t.Setenv("VAULT_TOKEN", "") // no ambient token

	ensureVaultToken()
	if got := os.Getenv("VAULT_TOKEN"); got != "SCOPED-TOK" {
		t.Fatalf("VAULT_TOKEN = %q, want scoped fallback to be exported", got)
	}
}

func TestEnsureVaultTokenKeepsExplicitEnv(t *testing.T) {
	dir := t.TempDir()
	cfg := dir + "/.config/claude-auth-sync"
	if err := os.MkdirAll(cfg, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg+"/vault-token", []byte("SCOPED-TOK"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", dir)
	t.Setenv("VAULT_TOKEN", "ADMIN-TOK")

	ensureVaultToken()
	if got := os.Getenv("VAULT_TOKEN"); got != "ADMIN-TOK" {
		t.Fatalf("VAULT_TOKEN = %q, must not override an explicit token", got)
	}
}

func TestScopedTokenPath(t *testing.T) {
	if got := scopedTokenPath("/home/emo"); got != "/home/emo/.config/claude-auth-sync/vault-token" {
		t.Fatalf("scopedTokenPath = %q", got)
	}
}

func TestVaultTokenSource(t *testing.T) {
	// Precedence: explicit $VAULT_TOKEN > ~/.vault-token (vault CLI native) >
	// the claude-auth-sync per-user scoped token. This is what lets a non-admin
	// workstation user (no ambient token) reach their own Vault path.
	cases := []struct {
		name             string
		env              string
		haveVaultToken   bool
		scoped           string
		wantTok, wantSrc string
	}{
		{"explicit env wins", "abc", true, "S", "", "env"},
		{"vault-token file used natively", "", true, "S", "", "file"},
		{"scoped fallback for non-admin", "", false, "S-TOK", "S-TOK", "scoped"},
		{"scoped value is trimmed", "", false, "  S-TOK\n", "S-TOK", "scoped"},
		{"whitespace-only scoped is no token", "", false, "  \n", "", "none"},
		{"nothing configured", "", false, "", "", "none"},
	}
	for _, c := range cases {
		tok, src := vaultTokenSource(c.env, c.haveVaultToken, c.scoped)
		if tok != c.wantTok || src != c.wantSrc {
			t.Errorf("%s: vaultTokenSource(%q,%v,%q) = (%q,%q), want (%q,%q)",
				c.name, c.env, c.haveVaultToken, c.scoped, tok, src, c.wantTok, c.wantSrc)
		}
	}
}

func TestKvWriteVerb(t *testing.T) {
	// merge=true → read-modify-write patch (needs only read+update, NOT the
	// `patch` capability the scoped workstation policy lacks).
	if got := kvWriteVerb(true); !reflect.DeepEqual(got, []string{"kv", "patch", "-method=rw"}) {
		t.Fatalf("kvWriteVerb(true) = %v", got)
	}
	// merge=false → put (creates the path on first use)
	if got := kvWriteVerb(false); !reflect.DeepEqual(got, []string{"kv", "put"}) {
		t.Fatalf("kvWriteVerb(false) = %v", got)
	}
}

func TestVaultWritePublicArgs(t *testing.T) {
	got := vaultWritePublicArgs(true, "emo", "e@x.me", "user.ci")
	want := []string{"kv", "patch", "-method=rw", "secret/workstation/claude-users/emo",
		"vaultwarden_email=e@x.me", "vaultwarden_client_id=user.ci"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("vaultWritePublicArgs(merge) = %v", got)
	}
	if got := vaultWritePublicArgs(false, "emo", "e@x.me", "user.ci"); got[0] != "kv" || got[1] != "put" {
		t.Fatalf("vaultWritePublicArgs(create) must use `kv put`, got %v", got)
	}
	for _, a := range got {
		if strings.Contains(a, "master_password") || strings.Contains(a, "client_secret") {
			t.Fatalf("secret key leaked into public argv: %v", got)
		}
	}
}

func TestVaultWriteSecretArgsNoValueInArgv(t *testing.T) {
	for _, key := range []string{"vaultwarden_master_password", "vaultwarden_client_secret"} {
		got := vaultWriteSecretArgs(true, "emo", key)
		want := []string{"kv", "patch", "-method=rw", "secret/workstation/claude-users/emo", key + "=-"}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("vaultWriteSecretArgs(%q) = %v", key, got)
		}
		if got[len(got)-1] != key+"=-" {
			t.Fatalf("secret value must be read from stdin (`%s=-`), got %v", key, got)
		}
	}
}

// recStdin records a stdin-bearing call for assertions.
type recStdin struct {
	argv  []string
	stdin string
}

// TestWriteCredsCreatesThenMerges: when the path is ABSENT the first (public)
// write must `kv put` (create), and the two secrets must merge via patch -rw
// with values on stdin only — never the buggy plain `kv patch` (needs `patch`).
func TestWriteCredsCreatesThenMerges(t *testing.T) {
	var calls [][]string
	var stdinCalls []recStdin
	run := func(name string, argv, envv []string) (string, error) {
		calls = append(calls, append([]string{name}, argv...))
		if len(argv) >= 2 && argv[0] == "kv" && argv[1] == "get" {
			return "", fmt.Errorf("no value found") // path absent
		}
		return "", nil
	}
	runStdin := func(name string, argv, envv []string, stdin string) (string, error) {
		stdinCalls = append(stdinCalls, recStdin{append([]string{name}, argv...), stdin})
		return "", nil
	}
	c := vwCreds{Email: "e@x.me", MasterPassword: "PW", ClientID: "user.ci", ClientSecret: "CS"}
	if err := writeCreds(run, runStdin, "emo", c); err != nil {
		t.Fatalf("writeCreds: %v", err)
	}
	var sawPut, sawPlainPatch bool
	for _, cl := range calls {
		j := strings.Join(cl, " ")
		if strings.Contains(j, "kv put") {
			sawPut = true
		}
		if strings.Contains(j, "kv patch") && !strings.Contains(j, "-method=rw") {
			sawPlainPatch = true
		}
	}
	if !sawPut {
		t.Fatalf("path absent → public write must be `kv put`; calls=%v", calls)
	}
	if sawPlainPatch {
		t.Fatalf("must never use plain `kv patch` (needs `patch` capability); calls=%v", calls)
	}
	if len(stdinCalls) != 2 {
		t.Fatalf("want 2 stdin secret writes, got %d", len(stdinCalls))
	}
	for _, sc := range stdinCalls {
		if !strings.Contains(strings.Join(sc.argv, " "), "kv patch -method=rw") {
			t.Errorf("secret write must use patch -method=rw: %v", sc.argv)
		}
		for _, a := range sc.argv {
			if strings.Contains(a, "PW") || strings.Contains(a, "CS") {
				t.Errorf("secret leaked into argv: %v", sc.argv)
			}
		}
	}
	if stdinCalls[0].stdin != "PW" || stdinCalls[1].stdin != "CS" {
		t.Errorf("stdin values wrong: %q,%q", stdinCalls[0].stdin, stdinCalls[1].stdin)
	}
}

// TestWriteCredsMergesWhenPresent: when the path EXISTS, every write must merge
// (patch -rw) — a `kv put` would wipe sibling keys (e.g. claude_ai_oauth_json).
func TestWriteCredsMergesWhenPresent(t *testing.T) {
	var calls [][]string
	run := func(name string, argv, envv []string) (string, error) {
		calls = append(calls, append([]string{name}, argv...))
		return "{}", nil // get succeeds → path exists
	}
	runStdin := func(name string, argv, envv []string, stdin string) (string, error) {
		calls = append(calls, append([]string{name}, argv...))
		return "", nil
	}
	c := vwCreds{Email: "e@x.me", MasterPassword: "PW", ClientID: "user.ci", ClientSecret: "CS"}
	if err := writeCreds(run, runStdin, "emo", c); err != nil {
		t.Fatalf("writeCreds: %v", err)
	}
	for _, cl := range calls {
		if strings.Contains(strings.Join(cl, " "), "kv put") {
			t.Fatalf("path exists → must NOT `kv put` (wipes siblings): %v", cl)
		}
	}
}

// TestNoSecretInArgvAcrossFlow is the load-bearing security test: across the
// whole get flow (vault reads, bw config/status/login/unlock/get) NO secret
// value may appear in any command's argv — secrets travel via env/stdin only.
func TestNoSecretInArgvAcrossFlow(t *testing.T) {
	uid := fmt.Sprintf("%d", os.Getuid())
	f := &fakeRunner{out: map[string]string{
		"vault kv get -field=vaultwarden_master_password secret/workstation/claude-users/emo": "SUPERSECRETPW",
		"vault kv get -field=vaultwarden_client_id secret/workstation/claude-users/emo":       "user.x",
		"vault kv get -field=vaultwarden_client_secret secret/workstation/claude-users/emo":   "CLIENTSEKRET",
		"bw status":              `{"status":"locked"}`,
		"bw unlock":              "SESSIONXYZ",
		"bw get password github": "p@ss",
	}}
	if _, err := getValue(f.run, "emo", uid, getOpts{name: "github", field: "password"}); err != nil {
		t.Fatalf("getValue: %v", err)
	}
	for _, call := range f.calls {
		for _, arg := range call {
			for _, s := range []string{"SUPERSECRETPW", "CLIENTSEKRET", "SESSIONXYZ"} {
				if strings.Contains(arg, s) {
					t.Errorf("secret %q leaked into argv: %v", s, call)
				}
			}
		}
	}
	if !strings.Contains(strings.Join(f.lastEnv, "\n"), "BW_SESSION=SESSIONXYZ") {
		t.Error("expected BW_SESSION in the bw get env (test would be vacuous otherwise)")
	}
}

func TestClipboardDecision(t *testing.T) {
	cases := []struct {
		stdoutTTY, stderrTTY bool
		term, prog, want     string
	}{
		{false, true, "xterm-kitty", "", "stdout"},
		{true, true, "xterm-kitty", "", "clipboard"},
		{true, true, "dumb", "", "refuse"},
		{true, false, "xterm-kitty", "", "refuse"},
	}
	for _, c := range cases {
		if got := clipboardDecision(c.stdoutTTY, c.stderrTTY, c.term, c.prog); got != c.want {
			t.Errorf("clipboardDecision(%v,%v,%q) = %q, want %q", c.stdoutTTY, c.stderrTTY, c.term, got, c.want)
		}
	}
}

func TestJSONToStdoutOK(t *testing.T) {
	if jsonToStdoutOK(true) {
		t.Error("must refuse JSON secret on a terminal")
	}
	if !jsonToStdoutOK(false) {
		t.Error("must allow JSON when piped")
	}
}

func TestBwNeedsLogin(t *testing.T) {
	if !bwNeedsLogin(`{"status":"unauthenticated"}`) {
		t.Error("unauthenticated → needs login")
	}
	if bwNeedsLogin(`{"status":"locked"}`) {
		t.Error("locked → no login (just unlock)")
	}
	if bwNeedsLogin(`{"status":"unlocked"}`) {
		t.Error("unlocked → no login")
	}
	if !bwNeedsLogin(`not json`) {
		t.Error("unparseable → attempt login")
	}
}

func TestVaultHelpMentionsSecurity(t *testing.T) {
	h := vaultHelp()
	for _, want := range []string{"homelab vault get", "no-HITL", "your own", "setup"} {
		if !strings.Contains(h, want) {
			t.Errorf("vault help missing %q", want)
		}
	}
}

func TestVaultBareGroupRegistered(t *testing.T) {
	for _, c := range vaultCommands() {
		if len(c.Path) == 1 && c.Path[0] == "vault" {
			return
		}
	}
	t.Fatal("bare `vault` help command not registered")
}

// getValue is the testable core: given a runner + opts, returns the secret value.
func TestGetValueFlow(t *testing.T) {
	f := &fakeRunner{out: map[string]string{
		"vault kv get -field=vaultwarden_master_password secret/workstation/claude-users/emo": "pw",
		"vault kv get -field=vaultwarden_client_id secret/workstation/claude-users/emo":       "user.x",
		"vault kv get -field=vaultwarden_client_secret secret/workstation/claude-users/emo":   "cs",
		"bw status":              `{"status":"locked"}`,
		"bw unlock":              "SESS",
		"bw get password github": "p@ss",
	}}
	// Use real UID so os.MkdirAll(/run/user/<uid>/homelab-bw) succeeds.
	uid := fmt.Sprintf("%d", os.Getuid())
	val, err := getValue(f.run, "emo", uid, getOpts{name: "github", field: "password"})
	if err != nil || val != "p@ss" {
		t.Fatalf("getValue = %q, %v", val, err)
	}
}
