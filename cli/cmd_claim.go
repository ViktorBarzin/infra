package main

import (
	"fmt"
	"strings"
)

func claimCommands() []Command {
	return []Command{
		{Path: []string{"claim"}, Tier: TierWrite,
			Summary: "claim a shared infra resource on the presence board",
			Run:     runClaim},
		{Path: []string{"release"}, Tier: TierWrite,
			Summary: "release a presence claim",
			Run:     runRelease},
	}
}

// runClaim parses `<kind>:<name> --purpose "..."` in either order (the presence
// script takes the label first, so we can't rely on Go's flag package which
// stops at the first positional).
func runClaim(args []string) error {
	var label, purpose string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--purpose" || a == "-purpose":
			if i+1 < len(args) {
				purpose = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--purpose="):
			purpose = strings.TrimPrefix(a, "--purpose=")
		case !strings.HasPrefix(a, "-") && label == "":
			label = a
		}
	}
	if label == "" {
		return fmt.Errorf(`usage: homelab claim <kind>:<name> --purpose "what + why"`)
	}
	return presenceClaim(label, purpose)
}

func runRelease(args []string) error {
	var label string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			label = a
			break
		}
	}
	if label == "" {
		return fmt.Errorf("usage: homelab release <kind>:<name>")
	}
	return presenceRelease(label)
}
