package main

import (
	"encoding/base64"
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
		"vault kv get -field=vaultwarden_email secret/workstation/claude-users/emo":          "emo@x.me",
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
