package main

import (
	"fmt"
	"os/exec"
)

func servicesCommands() []Command {
	return []Command{
		{Path: []string{"services"}, Tier: TierRead,
			Summary: "what we self-host + which verb to reach for: services [--search X]", Run: servicesList},
	}
}

// servicesList prints the routing table and the live service inventory. The
// inventory is read from ingress annotations at call time rather than a stored
// list, so it cannot drift from what is actually deployed.
func servicesList(args []string) error {
	out, err := exec.Command("kubectl", "get", "ingress", "-A", "-o", "json").Output()
	if err != nil {
		return fmt.Errorf("cannot list ingresses (need cluster read access): %w", err)
	}
	svcs, err := parseServices(string(out))
	if err != nil {
		return err
	}
	query := parseServicesQuery(args)
	fmt.Print(formatCatalog(filterServices(svcs, query), query))
	return nil
}
