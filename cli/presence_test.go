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
