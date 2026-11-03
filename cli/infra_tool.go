package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// infraCheckoutCandidates are the places an infra clone sits in a user's home.
// The devvm has two layouts: a workspace, where ~/code holds per-project clones
// and infra is ~/code/infra, and a single layout, where ~/code IS the infra
// clone. The workspace clone is tried first.
func infraCheckoutCandidates(home string) []string {
	return []string{
		filepath.Join(home, "code", "infra"),
		filepath.Join(home, "code"),
	}
}

// findInfraTool locates a script shipped in infra under scripts/<rel>, for the
// verbs that drive Python tooling (reflect, quality). A candidate only counts
// when it is an infra checkout (terragrunt.hcl + stacks/), so a workspace
// directory that happens to have a scripts/ folder is not mistaken for one.
//
// The tooling writes its history snapshots next to itself, so the snapshot
// lands in the same infra checkout and is committed there.
func findInfraTool(home, rel string) (string, error) {
	var looked []string
	for _, root := range infraCheckoutCandidates(home) {
		p := filepath.Join(root, "scripts", rel)
		looked = append(looked, p)
		if isFile(filepath.Join(root, "terragrunt.hcl")) && isDir(filepath.Join(root, "stacks")) && isFile(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("%s not found (looked in %s); it ships in the infra repo at scripts/%s, "+
		"so pull your infra clone", filepath.Base(rel), strings.Join(looked, ", "), rel)
}
