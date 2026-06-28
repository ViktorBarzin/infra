package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
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

func TestEnsureVaultTokenPrefersScopedOverFile(t *testing.T) {
	// Regression: a power-user's read-only OIDC ~/.vault-token must NOT shadow the
	// purpose-built scoped token (emo's setup hit 403 because it did, 2026-06-28).
	dir := t.TempDir()
	cfg := dir + "/.config/claude-auth-sync"
	if err := os.MkdirAll(cfg, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg+"/vault-token", []byte("SCOPED-TOK"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/.vault-token", []byte("STALE-OIDC-TOK"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", dir)
	t.Setenv("VAULT_TOKEN", "")

	ensureVaultToken()
	if got := os.Getenv("VAULT_TOKEN"); got != "SCOPED-TOK" {
		t.Fatalf("VAULT_TOKEN = %q, want the scoped token to win over a stale ~/.vault-token", got)
	}
}

func TestScopedTokenPath(t *testing.T) {
	if got := scopedTokenPath("/home/emo"); got != "/home/emo/.config/claude-auth-sync/vault-token" {
		t.Fatalf("scopedTokenPath = %q", got)
	}
}

func TestVaultTokenSource(t *testing.T) {
	// Precedence: explicit $VAULT_TOKEN > the claude-auth-sync per-user scoped
	// token > a native ~/.vault-token. Scoped beats the file so a power-user's
	// read-only OIDC ~/.vault-token can't shadow the scoped token on the user's
	// own path (emo, 2026-06-28).
	cases := []struct {
		name             string
		env              string
		haveVaultToken   bool
		scoped           string
		wantTok, wantSrc string
	}{
		{"explicit env wins", "abc", true, "S", "", "env"},
		{"scoped beats a stale ~/.vault-token", "", true, "S-TOK", "S-TOK", "scoped"},
		{"scoped used when no file", "", false, "S-TOK", "S-TOK", "scoped"},
		{"native ~/.vault-token only when no scoped", "", true, "", "", "file"},
		{"scoped value is trimmed", "", false, "  S-TOK\n", "S-TOK", "scoped"},
		{"whitespace-only scoped falls back to file", "", true, "  \n", "", "file"},
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

func TestVaultAddrToSet(t *testing.T) {
	// homelab vault is invoked by AFK agent sessions (non-login shells that
	// never sourced /etc/environment), so the CLI must self-default VAULT_ADDR
	// rather than rely on the ambient env — else every `vault` child hits the
	// 127.0.0.1:8200 default and fails "connection refused" (exit 2).
	cases := []struct {
		name, env, want string
	}{
		{"unset -> default", "", vaultAddrDefault},
		{"whitespace-only -> default", "  \n", vaultAddrDefault},
		{"explicit kept (empty = leave alone)", "https://vault.example.com", ""},
	}
	for _, c := range cases {
		if got := vaultAddrToSet(c.env); got != c.want {
			t.Errorf("%s: vaultAddrToSet(%q) = %q, want %q", c.name, c.env, got, c.want)
		}
	}
}

func TestEnsureVaultTokenSetsDefaultAddr(t *testing.T) {
	dir := t.TempDir() // no scoped token, no ~/.vault-token
	t.Setenv("HOME", dir)
	t.Setenv("VAULT_TOKEN", "")
	t.Setenv("VAULT_ADDR", "") // emo's non-login-shell situation

	ensureVaultToken()
	if got := os.Getenv("VAULT_ADDR"); got != vaultAddrDefault {
		t.Fatalf("VAULT_ADDR = %q, want default %q to be exported", got, vaultAddrDefault)
	}
}

func TestEnsureVaultTokenKeepsExplicitAddr(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("VAULT_TOKEN", "")
	t.Setenv("VAULT_ADDR", "https://vault.example.com")

	ensureVaultToken()
	if got := os.Getenv("VAULT_ADDR"); got != "https://vault.example.com" {
		t.Fatalf("VAULT_ADDR = %q, must not override an explicit addr", got)
	}
}

func TestAugmentErrSurfacesStderr(t *testing.T) {
	if got := augmentErr(nil, []byte("ignored")); got != nil {
		t.Fatalf("augmentErr(nil, …) = %v, want nil", got)
	}
	base := errors.New("exit status 2")
	got := augmentErr(base, []byte("  dial tcp 127.0.0.1:8200: connect: connection refused\n"))
	if got == nil || !strings.Contains(got.Error(), "connection refused") || !strings.Contains(got.Error(), "exit status 2") {
		t.Fatalf("augmentErr did not surface stderr: %v", got)
	}
	if !errors.Is(got, base) {
		t.Fatal("augmentErr lost the wrapped error (errors.Is failed)")
	}
	if got := augmentErr(base, []byte("   ")); got != base {
		t.Fatalf("augmentErr with blank stderr = %v, want the original error unchanged", got)
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

// --- vault get --all (browse all fields) ----------------------------------

func TestParseGetArgsAll(t *testing.T) {
	o, err := parseGetArgs([]string{"github", "--all"})
	if err != nil || o.name != "github" || !o.all {
		t.Fatalf("parseGetArgs(--all) = %+v err=%v", o, err)
	}
	// --all must skip --field validation (field is irrelevant for a full dump).
	if _, err := parseGetArgs([]string{"github", "--all", "--field", "evil"}); err != nil {
		t.Fatalf("--all must ignore an otherwise-invalid --field, got err=%v", err)
	}
	// A name is still required.
	if _, err := parseGetArgs([]string{"--all"}); err == nil {
		t.Fatal("get --all with no name must error")
	}
	// Without --all, the field allowlist still applies.
	if _, err := parseGetArgs([]string{"github", "--field", "evil"}); err == nil {
		t.Fatal("invalid --field without --all must still error")
	}
}

func TestBwItemArgs(t *testing.T) {
	argv := bwItemArgs("github")
	if !reflect.DeepEqual(argv, []string{"get", "item", "github"}) {
		t.Fatalf("bwItemArgs = %v", argv)
	}
	for _, a := range argv {
		if strings.Contains(a, "SESSION") || a == "--session" {
			t.Fatalf("session must travel via env, not argv: %v", argv)
		}
	}
}

// a representative `bw get item` payload: login fields, multiple URIs, a TOTP
// seed, notes, custom fields (text/hidden/boolean), plus bw internals that MUST
// be dropped (id/object/reprompt/passwordHistory).
const sampleLoginItemJSON = `{
  "object":"item","id":"abc-123","folderId":null,"type":1,"reprompt":0,
  "name":"GitHub","notes":"my notes","favorite":false,
  "fields":[
    {"name":"PIN","value":"1234","type":1},
    {"name":"endpoint","value":"https://api.gh","type":0},
    {"name":"enabled","value":"true","type":2}
  ],
  "login":{
    "username":"octocat","password":"hunter2",
    "totp":"otpauth://totp/GitHub:octocat?secret=SEEDSEEDSEED",
    "uris":[{"match":null,"uri":"https://github.com"},{"match":null,"uri":"https://gist.github.com"}]
  },
  "passwordHistory":[{"password":"OLD-PASSWORD-XYZ"}]
}`

func TestNormalizeItemLogin(t *testing.T) {
	n, err := normalizeItem(sampleLoginItemJSON)
	if err != nil {
		t.Fatalf("normalizeItem: %v", err)
	}
	if n.Name != "GitHub" || n.Username != "octocat" || n.Password != "hunter2" || n.Notes != "my notes" {
		t.Fatalf("standard fields wrong: %+v", n)
	}
	if !n.TOTP {
		t.Fatal("TOTP presence flag must be true when a seed exists")
	}
	if !reflect.DeepEqual(n.URIs, []string{"https://github.com", "https://gist.github.com"}) {
		t.Fatalf("URIs = %v", n.URIs)
	}
	want := map[string]string{"PIN": "1234", "endpoint": "https://api.gh", "enabled": "true"}
	if !reflect.DeepEqual(n.Fields, want) {
		t.Fatalf("custom fields = %v want %v", n.Fields, want)
	}
}

// The load-bearing security test: the raw TOTP seed (more powerful than a
// one-time code) and the password history must NEVER appear in the dump.
func TestNormalizeItemNeverLeaksSeedOrHistory(t *testing.T) {
	n, err := normalizeItem(sampleLoginItemJSON)
	if err != nil {
		t.Fatalf("normalizeItem: %v", err)
	}
	out, err := json.Marshal(n)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, leak := range []string{"SEEDSEEDSEED", "otpauth", "OLD-PASSWORD-XYZ", "passwordHistory", "abc-123"} {
		if strings.Contains(string(out), leak) {
			t.Fatalf("dump leaked %q: %s", leak, out)
		}
	}
}

func TestNormalizeItemNoTOTP(t *testing.T) {
	n, err := normalizeItem(`{"name":"X","type":1,"login":{"username":"u","password":"p"}}`)
	if err != nil {
		t.Fatalf("normalizeItem: %v", err)
	}
	if n.TOTP {
		t.Fatal("TOTP must be false when no seed present")
	}
	out, _ := json.Marshal(n)
	if strings.Contains(string(out), "totp") {
		t.Fatalf("no-totp item must omit the totp key entirely: %s", out)
	}
}

func TestNormalizeItemEmptyStandardFieldsOmitted(t *testing.T) {
	n, err := normalizeItem(`{"name":"Bare","type":1,"login":{"username":"","password":"","totp":"","uris":[]},"fields":[{"name":"only","value":"x","type":0}]}`)
	if err != nil {
		t.Fatalf("normalizeItem: %v", err)
	}
	out, _ := json.Marshal(n)
	for _, k := range []string{"username", "password", "uris", "notes", "totp"} {
		if strings.Contains(string(out), `"`+k+`"`) {
			t.Fatalf("empty standard field %q must be omitted: %s", k, out)
		}
	}
	if !strings.Contains(string(out), `"name":"Bare"`) || !strings.Contains(string(out), `"only":"x"`) {
		t.Fatalf("name + custom field must survive: %s", out)
	}
}

func TestNormalizeItemSecureNoteNullLogin(t *testing.T) {
	// type 2 (secure note): login is null — must not panic; notes + custom fields survive.
	n, err := normalizeItem(`{"name":"SN","type":2,"notes":"secret note","login":null,"fields":[{"name":"k","value":"v","type":1}]}`)
	if err != nil {
		t.Fatalf("normalizeItem(null login): %v", err)
	}
	if n.Name != "SN" || n.Notes != "secret note" || n.Fields["k"] != "v" {
		t.Fatalf("secure-note normalize wrong: %+v", n)
	}
	if n.Username != "" || n.Password != "" || n.TOTP {
		t.Fatalf("login fields must be empty for a login-less item: %+v", n)
	}
}

func TestNormalizeItemDuplicateCustomNames(t *testing.T) {
	// Bitwarden permits duplicate custom-field names; a JSON object can't hold
	// dups, so last-wins (documented).
	n, err := normalizeItem(`{"name":"D","fields":[{"name":"k","value":"first","type":0},{"name":"k","value":"second","type":0}]}`)
	if err != nil {
		t.Fatalf("normalizeItem: %v", err)
	}
	if n.Fields["k"] != "second" {
		t.Fatalf("duplicate custom names must be last-wins, got %q", n.Fields["k"])
	}
}

func TestNormalizeItemLinkedFieldSkipped(t *testing.T) {
	// type 3 (linked) fields reference another field and carry a null value —
	// they are not real data and must be skipped.
	n, err := normalizeItem(`{"name":"L","login":{"username":"u"},"fields":[{"name":"linked","value":null,"type":3},{"name":"real","value":"r","type":0}]}`)
	if err != nil {
		t.Fatalf("normalizeItem: %v", err)
	}
	if _, ok := n.Fields["linked"]; ok {
		t.Fatalf("linked field must be skipped: %v", n.Fields)
	}
	if n.Fields["real"] != "r" {
		t.Fatalf("real custom field dropped: %v", n.Fields)
	}
}

func TestNormalizeItemMalformed(t *testing.T) {
	if _, err := normalizeItem("not json"); err == nil {
		t.Fatal("malformed item JSON must error")
	}
}

// getItem opens a session and runs `bw get item <name>`, returning raw JSON.
func TestGetItemFlow(t *testing.T) {
	f := &fakeRunner{out: map[string]string{
		"vault kv get -field=vaultwarden_master_password secret/workstation/claude-users/emo": "pw",
		"vault kv get -field=vaultwarden_client_id secret/workstation/claude-users/emo":       "user.x",
		"vault kv get -field=vaultwarden_client_secret secret/workstation/claude-users/emo":   "cs",
		"bw status":          `{"status":"locked"}`,
		"bw unlock":          "SESS",
		"bw get item github": sampleLoginItemJSON,
	}}
	uid := fmt.Sprintf("%d", os.Getuid())
	raw, err := getItem(f.run, "emo", uid, "github")
	if err != nil || !strings.Contains(raw, `"name":"GitHub"`) {
		t.Fatalf("getItem = %q, %v", raw, err)
	}
	// The session key must reach bw via env, never argv.
	for _, call := range f.calls {
		for _, arg := range call {
			if strings.Contains(arg, "SESS") {
				t.Errorf("session leaked into argv: %v", call)
			}
		}
	}
}

func TestVaultHelpMentionsAll(t *testing.T) {
	if !strings.Contains(vaultHelp(), "--all") {
		t.Error("vault help must document --all")
	}
}

// --- bw sync on read (freshness) ------------------------------------------

func TestBwSyncArgs(t *testing.T) {
	if got := bwSyncArgs(); !reflect.DeepEqual(got, []string{"sync"}) {
		t.Fatalf("bwSyncArgs = %v", got)
	}
}

// Every read opens a session that first `bw sync`s, so reads reflect the latest
// server-side values: `bw unlock` is local-only, so without a sync a persisted
// (already-logged-in) session serves a stale local cache.
func TestOpenSessionSyncsBeforeRead(t *testing.T) {
	f := &fakeRunner{out: map[string]string{
		"vault kv get -field=vaultwarden_master_password secret/workstation/claude-users/emo": "pw",
		"vault kv get -field=vaultwarden_client_id secret/workstation/claude-users/emo":       "user.x",
		"vault kv get -field=vaultwarden_client_secret secret/workstation/claude-users/emo":   "cs",
		"bw status":              `{"status":"locked"}`,
		"bw unlock":              "SESS",
		"bw sync":                "Syncing complete.",
		"bw get password github": "p@ss",
	}}
	uid := fmt.Sprintf("%d", os.Getuid())
	if _, err := getValue(f.run, "emo", uid, getOpts{name: "github", field: "password"}); err != nil {
		t.Fatalf("getValue: %v", err)
	}
	idx := func(prefix string) int {
		for i, c := range f.calls {
			if strings.HasPrefix(strings.Join(c, " "), prefix) {
				return i
			}
		}
		return -1
	}
	syncAt, unlockAt, getAt := idx("bw sync"), idx("bw unlock"), idx("bw get password github")
	if syncAt < 0 {
		t.Fatal("expected a `bw sync` before the read")
	}
	if !(unlockAt < syncAt && syncAt < getAt) {
		t.Fatalf("order wrong: unlock=%d sync=%d get=%d (want unlock<sync<get)", unlockAt, syncAt, getAt)
	}
}

// Sync is best-effort: a transient sync failure must NOT fail the read — the
// cached value is still returned (a stderr warning is emitted, not asserted here).
func TestReadSucceedsWhenSyncFails(t *testing.T) {
	f := &fakeRunner{
		out: map[string]string{
			"vault kv get -field=vaultwarden_master_password secret/workstation/claude-users/emo": "pw",
			"vault kv get -field=vaultwarden_client_id secret/workstation/claude-users/emo":       "user.x",
			"vault kv get -field=vaultwarden_client_secret secret/workstation/claude-users/emo":   "cs",
			"bw status":              `{"status":"locked"}`,
			"bw unlock":              "SESS",
			"bw get password github": "p@ss",
		},
		err: map[string]error{"bw sync": errors.New("Failed to sync: network error")},
	}
	uid := fmt.Sprintf("%d", os.Getuid())
	val, err := getValue(f.run, "emo", uid, getOpts{name: "github", field: "password"})
	if err != nil || val != "p@ss" {
		t.Fatalf("read must succeed despite a sync failure: val=%q err=%v", val, err)
	}
}
