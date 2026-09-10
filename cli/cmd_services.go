package main

import (
	"fmt"
	"os/exec"
	"strings"
)

func servicesCommands() []Command {
	return []Command{
		{Path: []string{"services"}, Tier: TierRead,
			Summary: "what we self-host + which verb to reach for: services [--search X] [--json]", Run: servicesList},
		{Path: []string{"how"}, Tier: TierRead,
			Summary: "which capability does this task: how \"<what you are trying to do>\"", Run: howTo},
	}
}

// howTo answers "what should I reach for to do X" from the task-keyed index in
// capabilities.go. It exists because the inventory `services` prints answers
// "what do we run", which is a different question and the wrong one at the
// moment a tool is being chosen — see the 2026-08-31 session study.
func howTo(args []string) error {
	task := strings.TrimSpace(strings.Join(args, " "))
	if task == "" {
		fmt.Println("usage: homelab how \"<what you are trying to do>\"")
		fmt.Println("   e.g. homelab how \"reproduce a bug someone saw on their phone\"")
		fmt.Println("        homelab how \"read the journal of this box\"")
		fmt.Println("        homelab how \"find a credential for a third-party API\"")
		return nil
	}
	fmt.Print(formatHow(matchCapabilities(capabilities(), task), task))
	return nil
}

// servicesList prints the routing table and the live service inventory. The
// inventory is read from ingress annotations at call time rather than a stored
// list, so it cannot drift from what is actually deployed.
//
// --json prints the inventory alone, as a JSON array, for a script to consume.
func servicesList(args []string) error {
	out, err := exec.Command("kubectl", "get", "ingress", "-A", "-o", "json").Output()
	if err != nil {
		return fmt.Errorf("cannot list ingresses (need cluster read access): %w", err)
	}
	svcs, err := parseServices(string(out))
	if err != nil {
		return err
	}
	// Also catalogue cluster-internal Services carrying the same annotations.
	// Some capabilities deliberately have no ingress — the VPN egress proxy is
	// a ClusterIP so an open proxy is never published through Traefik — and
	// ingress-only discovery left those invisible. A failure here is not fatal:
	// the web-facing inventory is still worth printing.
	if sout, serr := exec.Command("kubectl", "get", "svc", "-A", "-o", "json").Output(); serr == nil {
		if internal, ierr := parseInternalServices(string(sout)); ierr == nil {
			svcs = append(svcs, internal...)
		}
	}
	query := parseServicesQuery(args)
	svcs = filterServices(svcs, query)
	if containsArg(args, "--json") {
		out, err := catalogJSON(svcs)
		if err != nil {
			return err
		}
		fmt.Println(out)
		return nil
	}
	fmt.Print(formatCatalog(svcs, query))
	return nil
}
