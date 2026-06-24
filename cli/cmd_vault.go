package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// vault verbs give each unix user no-HITL access to THEIR OWN Vaultwarden vault.
// Identity is the kernel UID; per-user creds live in that user's isolated Vault
// path (secret/workstation/claude-users/<user>) read via their scoped token, and
// decryption is done by the official `bw` CLI. See
// docs/superpowers/specs/2026-06-24-homelab-vault-design.md.
func vaultCommands() []Command {
	return []Command{
		{Path: []string{"vault", "setup"}, Tier: TierWrite,
			Summary: "one-time: store your Vaultwarden master password + API key in your Vault path", Run: vaultSetup},
		{Path: []string{"vault", "status"}, Tier: TierRead,
			Summary: "show whether your vault is configured/reachable (no secrets)", Run: vaultStatus},
		{Path: []string{"vault", "list"}, Tier: TierRead,
			Summary: "list your item names: vault list [--search Q]", Run: vaultList},
		{Path: []string{"vault", "get"}, Tier: TierRead,
			Summary: "fetch one item: vault get <name> [--field password|username|uri|notes] [--json]", Run: vaultGet},
		{Path: []string{"vault", "search"}, Tier: TierRead,
			Summary: "search your item names: vault search <query>", Run: vaultSearch},
		{Path: []string{"vault", "code"}, Tier: TierRead,
			Summary: "current TOTP code for an item: vault code <name>", Run: vaultCode},
		{Path: []string{"vault", "lock"}, Tier: TierWrite,
			Summary: "lock/log out the local bw session", Run: vaultLock},
	}
}

const vwUserPathPrefix = "secret/workstation/claude-users/"

// vwCreds is one user's Vaultwarden auth material, read from their Vault path.
type vwCreds struct {
	Email          string
	MasterPassword string
	ClientID       string
	ClientSecret   string
}

// cmdRunner shells out to an external command with an explicit environment and
// returns trimmed stdout. Secrets are passed via envv, NEVER argv. Tests inject
// a fake; realRunner is the production implementation.
type cmdRunner func(name string, argv, envv []string) (string, error)

func realRunner(name string, argv, envv []string) (string, error) {
	cmd := exec.Command(name, argv...)
	if envv != nil {
		cmd.Env = envv
	}
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func vwCredsPath(user string) string { return vwUserPathPrefix + user }

func bwAppDataDir(uid string) string { return "/run/user/" + uid + "/homelab-bw" }

// readVaultField returns one field from a KV-v2 path, "" if absent/error.
func readVaultField(run cmdRunner, field, path string) string {
	out, err := run("vault", []string{"kv", "get", "-field=" + field, path}, nil)
	if err != nil {
		return ""
	}
	return out
}

// loadCreds reads the four vaultwarden_* keys from the user's isolated path.
// A missing master password means the user hasn't onboarded.
func loadCreds(run cmdRunner, user string) (vwCreds, error) {
	p := vwCredsPath(user)
	c := vwCreds{
		Email:          readVaultField(run, "vaultwarden_email", p),
		MasterPassword: readVaultField(run, "vaultwarden_master_password", p),
		ClientID:       readVaultField(run, "vaultwarden_client_id", p),
		ClientSecret:   readVaultField(run, "vaultwarden_client_secret", p),
	}
	if c.MasterPassword == "" {
		return vwCreds{}, fmt.Errorf("vault not configured for this user — run `homelab vault setup`")
	}
	return c, nil
}

// vaultCurrentUser/vaultCurrentUID are seams for tests (avoid conflict with repo.go's currentUser func).
var vaultCurrentUser = func() string { return os.Getenv("USER") }
var vaultCurrentUID = func() string { return fmt.Sprintf("%d", os.Getuid()) }

func vaultSetup(args []string) error  { return fmt.Errorf("not implemented") }
func vaultStatus(args []string) error { return fmt.Errorf("not implemented") }
func vaultList(args []string) error   { return fmt.Errorf("not implemented") }
func vaultGet(args []string) error    { return fmt.Errorf("not implemented") }
func vaultSearch(args []string) error { return fmt.Errorf("not implemented") }
func vaultCode(args []string) error   { return fmt.Errorf("not implemented") }
func vaultLock(args []string) error   { return fmt.Errorf("not implemented") }
