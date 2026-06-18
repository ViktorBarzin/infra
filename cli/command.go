package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Tier classifies whether a command observes (read) or mutates (write) state.
// v0.1 allows everything; the tier is recorded so a classifier hook can gate
// writes later without restructuring (see docs/adr/0005).
type Tier string

const (
	TierRead  Tier = "read"
	TierWrite Tier = "write"
)

// Command is one homelab verb. Path is the token sequence that selects it,
// e.g. ["claim"] or ["tf", "plan"]. Run receives the args after the path.
type Command struct {
	Path    []string
	Tier    Tier
	Summary string
	Run     func(args []string) error
}

// dispatch routes args to the command whose Path is the longest matching prefix
// of args, passing the remaining args to its Run.
func dispatch(reg []Command, args []string) error {
	best := -1
	bestLen := 0
	for i, c := range reg {
		if len(c.Path) > len(args) {
			continue
		}
		match := true
		for j, p := range c.Path {
			if args[j] != p {
				match = false
				break
			}
		}
		if match && len(c.Path) >= bestLen {
			best = i
			bestLen = len(c.Path)
		}
	}
	if best < 0 {
		return fmt.Errorf("unknown command: %q", strings.Join(args, " "))
	}
	return reg[best].Run(args[bestLen:])
}

// name is the space-joined verb path, e.g. "tf plan".
func (c Command) name() string { return strings.Join(c.Path, " ") }

// sortedByName returns a copy of reg ordered by verb path for stable output.
func sortedByName(reg []Command) []Command {
	out := make([]Command, len(reg))
	copy(out, reg)
	sort.Slice(out, func(i, j int) bool { return out[i].name() < out[j].name() })
	return out
}

// manifestText renders one aligned line per command: "<path>  <tier>  <summary>".
// This is the cheap progressive-discovery entrypoint (see docs/adr/0004).
func manifestText(reg []Command) string {
	cmds := sortedByName(reg)
	width := 0
	for _, c := range cmds {
		if n := len(c.name()); n > width {
			width = n
		}
	}
	var b strings.Builder
	for _, c := range cmds {
		fmt.Fprintf(&b, "%-*s  %-5s  %s\n", width, c.name(), c.Tier, c.Summary)
	}
	return b.String()
}

// manifestJSON renders the registry as a JSON array of {command, tier, summary}
// so agents can parse the full surface in one call.
func manifestJSON(reg []Command) (string, error) {
	type entry struct {
		Command string `json:"command"`
		Tier    string `json:"tier"`
		Summary string `json:"summary"`
	}
	entries := make([]entry, 0, len(reg))
	for _, c := range sortedByName(reg) {
		entries = append(entries, entry{Command: c.name(), Tier: string(c.Tier), Summary: c.Summary})
	}
	b, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return "", err
	}
	return string(b), nil
}
