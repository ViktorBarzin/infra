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
	// Internal marks a row that came from a cluster-internal Service rather
	// than an Ingress. Its Host is an in-cluster address, not something a
	// browser can open, and the catalog must say so — otherwise an agent reads
	// it as a URL and reports the service broken when it does not resolve.
	Internal bool
}

// The task-keyed capability index that used to live here as routingTable() now
// lives in capabilities.go, keyed by the task rather than the service, with the
// built-in competitor named on every row that has one. routingTable() is still
// the two-column contract formatCatalog renders; it derives from capabilities().

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

// serviceList is the subset of `kubectl get svc -A -o json` the catalog reads.
type serviceList struct {
	Items []struct {
		Metadata struct {
			Name        string            `json:"name"`
			Namespace   string            `json:"namespace"`
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
		Spec struct {
			ClusterIP string `json:"clusterIP"`
		} `json:"spec"`
	} `json:"items"`
}

// parseInternalServices catalogues cluster-internal Services that carry the
// same `gethomepage.dev/*` annotations as ingresses.
//
// Some capabilities have no web page and must not get one — the VPN egress
// proxy is a ClusterIP precisely so an open, unauthenticated proxy is never
// published through Traefik. Ingress-only discovery made those invisible to
// agents, which is how a working capability goes unused.
//
// The connectable address comes from the `homelab/endpoint` annotation rather
// than being derived: a Service may expose several ports (the egress proxy
// serves HTTP on 8888 and SOCKS5 on 1080) and only the owner knows which one a
// consumer should be told about.
func parseInternalServices(kubectlJSON string) ([]service, error) {
	var list serviceList
	if err := json.Unmarshal([]byte(kubectlJSON), &list); err != nil {
		return nil, fmt.Errorf("cannot parse service listing: %w", err)
	}
	var out []service
	for _, it := range list.Items {
		a := it.Metadata.Annotations
		if a["gethomepage.dev/enabled"] != "true" {
			continue
		}
		// Headless Services have no address to hand out.
		if it.Spec.ClusterIP == "" || it.Spec.ClusterIP == "None" {
			continue
		}
		endpoint := a["homelab/endpoint"]
		if endpoint == "" {
			endpoint = fmt.Sprintf("%s.%s.svc.cluster.local", it.Metadata.Name, it.Metadata.Namespace)
		}
		name := a["gethomepage.dev/name"]
		if name == "" {
			name = strings.ReplaceAll(it.Metadata.Name, "-", " ")
		}
		out = append(out, service{
			Name:        name,
			Host:        endpoint,
			Description: a["gethomepage.dev/description"],
			Group:       a["gethomepage.dev/group"],
			Internal:    true,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
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
// host, or description, PLUS rows a matching capability points at.
//
// The second half is why `--search mobile|phone|touch|reproduce` finds the
// Android emulator. Before the 2026-08-31 study, only `android|emulator`
// matched, which requires already knowing the answer — the exact shape of the
// miss the study measured. Task words now route through capabilities.go.
func filterServices(svcs []service, query string) []service {
	q := strings.ToLower(strings.TrimSpace(query))
	if q == "" {
		return svcs
	}
	// Hosts and names named by any capability whose task words match the query.
	pointed := map[string]bool{}
	for _, c := range matchCapabilities(capabilities(), q) {
		blob := strings.ToLower(c.Use + " " + strings.Join(c.Detail, " "))
		for _, s := range svcs {
			if s.Host != "" && strings.Contains(blob, strings.ToLower(s.Host)) {
				pointed[s.Host] = true
			}
		}
	}
	var out []service
	for _, s := range svcs {
		hay := strings.ToLower(s.Name + " " + s.Host + " " + s.Description)
		if strings.Contains(hay, q) || pointed[s.Host] {
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
		if s.Internal {
			// Say it plainly: this address is reachable from inside the
			// cluster only, so nobody pastes it into a browser and concludes
			// the service is down.
			line += " [in-cluster]"
		}
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
