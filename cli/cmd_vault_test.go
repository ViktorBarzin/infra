package main

import "testing"

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
