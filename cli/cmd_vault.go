package main

import "fmt"

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

func vaultSetup(args []string) error  { return fmt.Errorf("not implemented") }
func vaultStatus(args []string) error { return fmt.Errorf("not implemented") }
func vaultList(args []string) error   { return fmt.Errorf("not implemented") }
func vaultGet(args []string) error    { return fmt.Errorf("not implemented") }
func vaultSearch(args []string) error { return fmt.Errorf("not implemented") }
func vaultCode(args []string) error   { return fmt.Errorf("not implemented") }
func vaultLock(args []string) error   { return fmt.Errorf("not implemented") }
