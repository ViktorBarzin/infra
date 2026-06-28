package main

import "fmt"

func edgesCommands() []Command {
	return []Command{
		{Path: []string{"edges"}, Tier: TierRead,
			Summary: "who-talks-to-whom trail: edges [--ns|--src|--dst|--peers-of N] [--new-since 24h] [--denied] [--json] [--limit N]",
			Run:     edgesRun},
	}
}

// edgesRun renders the filter flags to SQL and runs it read-only against the
// goldmane_edges CNPG DB via the dbaas primary pod (same exec path as `k8s db`).
func edgesRun(args []string) error {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			fmt.Print(edgesUsage())
			return nil
		}
	}
	o, err := parseEdgesArgs(args)
	if err != nil {
		return fmt.Errorf("%w\n\n%s", err, edgesUsage())
	}
	sql, err := buildEdgesQuery(o)
	if err != nil {
		return err
	}
	// pg-cluster-rw is a Service (not exec-able); resolve the primary POD.
	pod, err := kubectlCapture("dbaas", "get", "pod", "-l", "cnpg.io/instanceRole=primary",
		"-o", "jsonpath={.items[0].metadata.name}")
	if err != nil || pod == "" {
		return fmt.Errorf("could not resolve CNPG primary pod in dbaas: %v", err)
	}
	exec := []string{"exec", pod, "-c", "postgres", "--", "psql", "-U", "postgres", "-d", "goldmane_edges"}
	if o.asJSON {
		exec = append(exec, "-tAc", sql) // raw tuple → the JSON array
	} else {
		exec = append(exec, "-P", "pager=off", "-c", sql) // aligned table for humans
	}
	return kubectlStream("dbaas", exec...)
}

func edgesUsage() string {
	return `homelab edges — query the who-talks-to-whom trail (goldmane_edges, ADR-0014)

Usage: homelab edges [filters]

Filters (AND-combined; namespace values are validated to the k8s name charset):
  --ns NAME         edges touching NAME (either direction)
  --src NAME        edges where source namespace = NAME
  --dst NAME        edges where destination namespace = NAME
  --peers-of NAME   distinct peer namespaces of NAME (both directions)
  --new-since SPEC  first seen since SPEC: a duration (24h, 7d, 30m, 90s) or a date (YYYY-MM-DD)
  --denied          only denied (action='deny') edges — blocked / lateral-movement attempts
  --json            output a JSON array (for agents/pipelines)
  --limit N         cap rows (default 200)

Examples:
  homelab edges --ns immich                # everything immich talks to / is talked to by
  homelab edges --peers-of authentik       # authentik's peer namespaces
  homelab edges --src recruiter-responder  # that namespace's egress peers
  homelab edges --new-since 24h            # edges first seen in the last day
  homelab edges --denied --json            # blocked flows, machine-readable

Read-only SELECT against CNPG DB goldmane_edges via the dbaas primary pod.
`
}
