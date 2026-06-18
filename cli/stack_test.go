package main

import (
	"os"
	"path/filepath"
	"testing"
)

func newInfraTree(t *testing.T, stacks ...string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "terragrunt.hcl"), []byte("# root"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, s := range stacks {
		if err := os.MkdirAll(filepath.Join(root, "stacks", s), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestFindInfraRootWalksUp(t *testing.T) {
	root := newInfraTree(t, "vault")
	got, err := findInfraRoot(filepath.Join(root, "stacks", "vault"))
	if err != nil {
		t.Fatalf("findInfraRoot error: %v", err)
	}
	if got != root {
		t.Fatalf("findInfraRoot = %q, want %q", got, root)
	}
}

func TestFindInfraRootErrorsOutsideInfra(t *testing.T) {
	if _, err := findInfraRoot(t.TempDir()); err == nil {
		t.Fatal("expected error outside an infra checkout")
	}
}

func TestResolveStack(t *testing.T) {
	root := newInfraTree(t, "vault", "monitoring")
	dir, err := resolveStack(root, "vault")
	if err != nil {
		t.Fatalf("resolveStack error: %v", err)
	}
	if want := filepath.Join(root, "stacks", "vault"); dir != want {
		t.Fatalf("resolveStack = %q, want %q", dir, want)
	}
	if _, err := resolveStack(root, "nonesuch"); err == nil {
		t.Fatal("expected error for unknown stack")
	}
}
