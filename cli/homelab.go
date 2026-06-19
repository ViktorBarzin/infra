package main

import (
	"fmt"
	"strings"
)

// version is stamped at build time via -ldflags "-X main.version=vX.Y.Z".
var version = "dev"

// buildRegistry returns every homelab verb. New verb-groups append here.
func buildRegistry() []Command {
	var reg []Command
	reg = append(reg, claimCommands()...)
	reg = append(reg, tfCommands()...)
	reg = append(reg, workCommands()...)
	reg = append(reg, k8sCommands()...)
	reg = append(reg, memoryCommands()...)
	return reg
}

// dispatchTop handles the homelab verb surface. handled=false means the args are
// not a homelab verb, so main() falls back to the legacy -use-case path.
func dispatchTop(args []string) (handled bool, err error) {
	if len(args) == 0 {
		fmt.Print(usage())
		return true, nil
	}
	switch args[0] {
	case "help", "-h", "--help":
		fmt.Print(usage())
		return true, nil
	case "version", "--version":
		fmt.Println("homelab " + version)
		return true, nil
	case "manifest":
		reg := buildRegistry()
		if containsArg(args[1:], "--json") {
			out, err := manifestJSON(reg)
			if err != nil {
				return true, err
			}
			fmt.Println(out)
			return true, nil
		}
		fmt.Print(manifestText(reg))
		return true, nil
	}
	if strings.HasPrefix(args[0], "-") {
		return false, nil
	}
	reg := buildRegistry()
	if !isCommandGroup(reg, args[0]) {
		return false, nil
	}
	return true, dispatch(reg, args)
}

func isCommandGroup(reg []Command, group string) bool {
	for _, c := range reg {
		if len(c.Path) > 0 && c.Path[0] == group {
			return true
		}
	}
	return false
}

func containsArg(args []string, want string) bool {
	for _, a := range args {
		if a == want {
			return true
		}
	}
	return false
}

func usage() string {
	var b strings.Builder
	fmt.Fprintf(&b, "homelab %s — unified homelab operations CLI\n\n", version)
	b.WriteString("Usage:\n  homelab <command> [args]\n\nCommands:\n")
	for _, line := range strings.Split(strings.TrimRight(manifestText(buildRegistry()), "\n"), "\n") {
		if line != "" {
			b.WriteString("  " + line + "\n")
		}
	}
	b.WriteString("\n  manifest [--json]   list all commands (machine-readable with --json)\n")
	b.WriteString("  version             print version\n")
	b.WriteString("\nLegacy webhook use-cases remain available via -use-case=<name>.\n")
	return b.String()
}
