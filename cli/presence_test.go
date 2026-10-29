package main

import "testing"

func TestValidateLabelAcceptsTaxonomy(t *testing.T) {
	good := []string{
		"stack:vault", "service:health", "node:k8s-node1", "db:pg-cluster",
		"infra:gpu-operator", "host:proxmox-1", "pvc:dbaas/data",
	}
	for _, l := range good {
		if err := validateLabel(l); err != nil {
			t.Errorf("validateLabel(%q) = %v, want nil", l, err)
		}
	}
}

func TestValidateLabelRejectsBadLabels(t *testing.T) {
	bad := []string{"vault", "stack:", "bogus:x", ":x", "stack", ""}
	for _, l := range bad {
		if err := validateLabel(l); err == nil {
			t.Errorf("validateLabel(%q) = nil, want error", l)
		}
	}
}

func TestResolvePresence(t *testing.T) {
	installed := func(p string) bool { return p == machinePresence }
	missing := func(string) bool { return false }
	cases := []struct {
		name     string
		override string
		exists   func(string) bool
		home     string
		want     string
	}{
		{"override wins", "/opt/presence", installed, "/home/emo", "/opt/presence"},
		{"machine-wide install", "", installed, "/home/emo", machinePresence},
		{"old monorepo copy when not installed", "", missing, "/home/wizard", "/home/wizard/code/scripts/presence"},
		{"bare name with no home", "", missing, "", "presence"},
	}
	for _, c := range cases {
		if got := resolvePresence(c.override, c.exists, c.home); got != c.want {
			t.Errorf("%s: resolvePresence = %q, want %q", c.name, got, c.want)
		}
	}
}
