package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// findInfraRoot walks up from start to the infra repo root — the directory
// holding both terragrunt.hcl and a stacks/ directory.
func findInfraRoot(start string) (string, error) {
	dir := start
	for {
		if isFile(filepath.Join(dir, "terragrunt.hcl")) && isDir(filepath.Join(dir, "stacks")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside an infra checkout (no terragrunt.hcl + stacks/ found above %s)", start)
		}
		dir = parent
	}
}

// resolveStack maps a bare stack name to its directory under <infraRoot>/stacks.
func resolveStack(infraRoot, name string) (string, error) {
	dir := filepath.Join(infraRoot, "stacks", name)
	if isDir(dir) {
		return dir, nil
	}
	avail := listStacks(infraRoot)
	return "", fmt.Errorf("stack %q not found under stacks/; available: %s", name, strings.Join(avail, ", "))
}

// listStacks returns the sorted names of every directory under <infraRoot>/stacks.
func listStacks(infraRoot string) []string {
	entries, err := os.ReadDir(filepath.Join(infraRoot, "stacks"))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

func isFile(p string) bool { fi, err := os.Stat(p); return err == nil && !fi.IsDir() }
func isDir(p string) bool  { fi, err := os.Stat(p); return err == nil && fi.IsDir() }
