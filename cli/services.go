package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// service is one catalog row: a web-facing thing we host, as described by the
// `gethomepage.dev/*` annotations that `ingress_factory` stamps on every
// ingress it creates. The catalog is derived from live cluster state on every
// invocation, so a newly-applied stack appears without anyone updating a list.
type service struct {
	Name        string
	Host        string
	Description string
	Group       string
}

// routingTable maps the operations agents actually perform to the verb that
// performs them here. This is the part of `homelab services` that changes
// behaviour — the inventory below it answers "what do we run?", this answers
// "what should I reach for?". Hand-curated on purpose: a trigger is a
// judgement, not something an annotation can express.
func routingTable() [][2]string {
	return [][2]string{
		{"share a long log, config, or snippet", "homelab paste <file|->"},
		{"hand someone a file", "homelab share <file>"},
		{"publish a finished design doc", "homelab pages publish <doc.md>"},
		{"remember something across sessions", "homelab memory store \"...\""},
		{"read a secret", "homelab vault get / vault kv get <path>"},
		{"query logs or metrics", "homelab logs query / metrics query"},
		{"see how Claude is used here", "homelab claude-usage [--since 30d]"},
		{"read one Claude conversation", "homelab claude-usage --session <id|name>"},
		{"drive a browser through an anti-bot wall", "homelab browser run <script.js>"},
		{"see what else we host", "homelab services [--search X]"},
	}
}

// ingressList is the subset of `kubectl get ingress -A -o json` the catalog
// reads. Anything not named here is ignored, so upstream shape changes
// elsewhere in the object don't break parsing.
type ingressList struct {
	Items []struct {
		Metadata struct {
			Name        string            `json:"name"`
			Namespace   string            `json:"namespace"`
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
		Spec struct {
			Rules []struct {
				Host string `json:"host"`
			} `json:"rules"`
		} `json:"spec"`
	} `json:"items"`
}

// parseServices turns a kubectl ingress listing into catalog rows: only
// catalog-enabled ingresses with a routable host, deduped by name+host (path
// carve-outs produce several ingress objects for one service) and sorted by
// name.
func parseServices(kubectlJSON string) ([]service, error) {
	var list ingressList
	if err := json.Unmarshal([]byte(kubectlJSON), &list); err != nil {
		return nil, fmt.Errorf("cannot parse ingress listing: %w", err)
	}
	seen := map[string]bool{}
	var out []service
	for _, it := range list.Items {
		a := it.Metadata.Annotations
		if a["gethomepage.dev/enabled"] != "true" {
			continue
		}
		if len(it.Spec.Rules) == 0 || it.Spec.Rules[0].Host == "" {
			continue // nothing to route to
		}
		name := a["gethomepage.dev/name"]
		if name == "" {
			name = strings.ReplaceAll(it.Metadata.Name, "-", " ")
		}
		host := it.Spec.Rules[0].Host
		key := name + "\x00" + host
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, service{
			Name:        name,
			Host:        host,
			Description: a["gethomepage.dev/description"],
			Group:       a["gethomepage.dev/group"],
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if strings.EqualFold(out[i].Name, out[j].Name) {
			return out[i].Host < out[j].Host
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

// filterServices keeps rows matching query (case-insensitive) in any of name,
// host, or description. An empty query keeps everything.
func filterServices(svcs []service, query string) []service {
	q := strings.ToLower(strings.TrimSpace(query))
	if q == "" {
		return svcs
	}
	var out []service
	for _, s := range svcs {
		hay := strings.ToLower(s.Name + " " + s.Host + " " + s.Description)
		if strings.Contains(hay, q) {
			out = append(out, s)
		}
	}
	return out
}

// formatCatalog renders the routing table followed by the inventory. query is
// echoed back when non-empty so a short filtered list is never mistaken for the
// full set of what we run.
func formatCatalog(svcs []service, query string) string {
	var b strings.Builder
	b.WriteString("Prefer our own services over public equivalents.\n\n")
	b.WriteString("WHAT YOU WANT TO DO                        USE\n")
	for _, r := range routingTable() {
		b.WriteString(fmt.Sprintf("  %-40s %s\n", r[0], r[1]))
	}

	if query != "" {
		b.WriteString(fmt.Sprintf("\n%d services matching %q:\n", len(svcs), query))
	} else {
		b.WriteString(fmt.Sprintf("\n%d services:\n", len(svcs)))
	}
	width := 0
	for _, s := range svcs {
		if len(s.Host) > width {
			width = len(s.Host)
		}
	}
	for _, s := range svcs {
		line := fmt.Sprintf("  %-*s  %s", width, s.Host, s.Name)
		if s.Description != "" {
			line += " — " + s.Description
		}
		b.WriteString(line + "\n")
	}
	return b.String()
}

// parseServicesQuery accepts either `--search <term>` or a bare term, so both
// `homelab services --search paste` and `homelab services paste` work.
func parseServicesQuery(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--search" || a == "-s" {
			if i+1 < len(args) {
				return args[i+1]
			}
			continue
		}
		if !strings.HasPrefix(a, "-") {
			return a
		}
	}
	return ""
}
