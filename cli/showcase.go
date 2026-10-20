package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// The Showcase (ADR-0037) is the public page that shows the homelab to other
// homelabbers. Everything on it comes from one generated Snapshot, built from
// live state, so the page never needs a hand edit. This file holds the pure
// half: turning raw listings into Snapshot rows. cmd_showcase.go does the I/O.

const (
	showcaseHiddenAnnotation = "showcase.viktorbarzin.me/hidden"
	githubInfraBlob          = "https://github.com/ViktorBarzin/infra/blob/master/"
)

// Access states. The page never calls a service "public" or "no login": a
// list of hosts tagged that way reads as a target list (ADR-0037). A service
// without SSO or a LAN restriction has its own login, as far as a visitor is
// concerned.
const (
	accessSSO = "sso"
	accessApp = "app"
	accessLAN = "lan"
)

// stackOverrides maps the namespaces whose stack directory has a different
// name. Everything else resolves namespace == stack; a namespace that resolves
// to neither fails the build (see parseShowcaseServices).
var stackOverrides = map[string]string{
	"aiostreams":           "servarr",
	"calico-system":        "calico",
	"kubernetes-dashboard": "k8s-dashboard",
	"realestate-crawler":   "real-estate-crawler",
	"webhook-handler":      "webhook_handler",
	"website":              "blog",
}

func showcaseStack(ns string, stacks map[string]bool) (string, bool) {
	if s, ok := stackOverrides[ns]; ok && stacks[s] {
		return s, true
	}
	if stacks[ns] {
		return ns, true
	}
	return "", false
}

// route is what a request to a service passes through, in order, for the
// "follow a request" Variant. DNS is the cloudflare.viktorbarzin.me/dns-type
// value: proxied (Cloudflare tunnel), non-proxied (straight to the home IP),
// internal (a LAN address) or none.
type route struct {
	DNS     string   `json:"dns"`
	Gates   []string `json:"gates"`
	Storage []string `json:"storage"`
}

// gateOrder lists the middleware gates in the order a request meets them,
// keyed by a substring of the Traefik middleware name. CrowdSec is not in the
// per-ingress list: it sits on the websecure entrypoint, so every request
// meets it first.
var gateOrder = []struct{ gate, match string }{
	{"turnstile", "turnstile-gate-auth"},
	{"anubis", "turnstile-gate-anubis"},
	{"ai-bot-block", "ai-bot-block"},
	{"rate-limit", "rate-limit"},
	{"lan-only", "local-only"},
	{"lan-only", "home-lans-only"},
	{"authentik", "authentik-forward-auth"},
}

func routeFor(dnsType, middlewares string) route {
	if dnsType == "" {
		dnsType = "none"
	}
	r := route{DNS: dnsType, Gates: []string{"crowdsec"}}
	seen := map[string]bool{}
	for _, g := range gateOrder {
		if !seen[g.gate] && strings.Contains(middlewares, g.match) {
			seen[g.gate] = true
			r.Gates = append(r.Gates, g.gate)
		}
	}
	return r
}

func accessState(middlewares string) string {
	switch {
	case strings.Contains(middlewares, "authentik-forward-auth"):
		return accessSSO
	case strings.Contains(middlewares, "local-only"), strings.Contains(middlewares, "home-lans-only"):
		return accessLAN
	}
	return accessApp
}

// showcaseService is one catalog card. Annotations are read by name and never
// copied wholesale: some ingresses carry Homepage widget credentials.
type showcaseService struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Group       string `json:"group"`
	Icon        string `json:"icon"`
	Host        string `json:"host"`
	Namespace   string `json:"namespace"`
	Stack       string `json:"stack"`
	StackURL    string `json:"stack_url"`
	Access      string `json:"access"`
	Route       route  `json:"route"`
}

// parseShowcaseServices turns a kubectl ingress listing into catalog cards:
// catalog-enabled ingresses with a host, minus anything opted out on the
// ingress or its namespace. A visible service whose namespace resolves to no
// stack is an error, so the page never publishes a dead Terraform link.
func parseShowcaseServices(kubectlJSON string, stacks, hiddenNS map[string]bool) ([]showcaseService, error) {
	var list ingressList
	if err := json.Unmarshal([]byte(kubectlJSON), &list); err != nil {
		return nil, fmt.Errorf("cannot parse ingress listing: %w", err)
	}
	seen := map[string]bool{}
	var out []showcaseService
	var unresolved []string
	for _, it := range list.Items {
		a := it.Metadata.Annotations
		ns := it.Metadata.Namespace
		if a["gethomepage.dev/enabled"] != "true" || a[showcaseHiddenAnnotation] == "true" || hiddenNS[ns] {
			continue
		}
		if len(it.Spec.Rules) == 0 || it.Spec.Rules[0].Host == "" {
			continue
		}
		name := a["gethomepage.dev/name"]
		if name == "" {
			name = strings.ReplaceAll(it.Metadata.Name, "-", " ")
		}
		host := it.Spec.Rules[0].Host
		if key := name + "\x00" + host; seen[key] {
			continue
		} else {
			seen[key] = true
		}
		stack, ok := showcaseStack(ns, stacks)
		if !ok {
			unresolved = append(unresolved, ns)
			continue
		}
		mw := a["traefik.ingress.kubernetes.io/router.middlewares"]
		out = append(out, showcaseService{
			Name:        name,
			Description: a["gethomepage.dev/description"],
			Group:       a["gethomepage.dev/group"],
			Icon:        a["gethomepage.dev/icon"],
			Host:        host,
			Namespace:   ns,
			Stack:       stack,
			StackURL:    githubInfraBlob + "stacks/" + stack + "/main.tf",
			Access:      accessState(mw),
			Route:       routeFor(a["cloudflare.viktorbarzin.me/dns-type"], mw),
		})
	}
	if len(unresolved) > 0 {
		sort.Strings(unresolved)
		return nil, fmt.Errorf("namespaces with no stack under stacks/ (add them to stackOverrides): %s",
			strings.Join(unresolved, ", "))
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out, nil
}

var (
	summaryRE = regexp.MustCompile(`<!--\s*showcase:\s*(.*?)\s*-->`)
	digitRE   = regexp.MustCompile(`\d`)
)

// docSummary returns a doc's required `<!-- showcase: ... -->` line. Summaries
// carry no digits: a count written into prose goes stale and then contradicts
// the live stats shown beside it (overview.md still says "70+ services").
func docSummary(md string) (string, error) {
	m := summaryRE.FindStringSubmatch(md)
	if m == nil || m[1] == "" {
		return "", fmt.Errorf("no <!-- showcase: ... --> summary")
	}
	if digitRE.MatchString(m[1]) {
		return "", fmt.Errorf("showcase summary contains a number: %q", m[1])
	}
	return m[1], nil
}

func docTitle(md string) string {
	for _, l := range strings.Split(md, "\n") {
		if strings.HasPrefix(l, "# ") {
			return strings.TrimSpace(strings.TrimPrefix(l, "# "))
		}
	}
	return ""
}

// showcaseLayers is the layer-to-doc mapping from the design doc. The apps
// layer is the catalog itself, so it has no docs.
var showcaseLayers = []struct {
	ID, Title string
	Docs      []string
}{
	{"hardware", "Hardware", []string{"compute", "london-site", "storage"}},
	{"network", "Network", []string{"networking", "vpn", "dns", "security"}},
	{"platform", "Platform", []string{"overview", "databases", "secrets", "authentication", "monitoring", "backup-dr"}},
	{"operations", "How it is run", []string{"ci-cd", "automated-upgrades", "incident-response", "multi-tenancy"}},
	{"apps", "Apps", nil},
}

type layerDoc struct {
	Title   string `json:"title"`
	Summary string `json:"summary"`
	URL     string `json:"url"`
}

type layer struct {
	ID    string     `json:"id"`
	Title string     `json:"title"`
	Docs  []layerDoc `json:"docs"`
}

// buildLayers reads each mapped doc through read (path relative to the repo
// root) and collects every missing summary into one error.
func buildLayers(read func(path string) (string, error)) ([]layer, error) {
	var out []layer
	var errs []string
	for _, l := range showcaseLayers {
		ly := layer{ID: l.ID, Title: l.Title, Docs: []layerDoc{}}
		for _, d := range l.Docs {
			p := "docs/architecture/" + d + ".md"
			md, err := read(p)
			if err != nil {
				errs = append(errs, fmt.Sprintf("%s: %v", p, err))
				continue
			}
			s, err := docSummary(md)
			if err != nil {
				errs = append(errs, fmt.Sprintf("%s: %v", p, err))
				continue
			}
			ly.Docs = append(ly.Docs, layerDoc{Title: docTitle(md), Summary: s, URL: githubInfraBlob + p})
		}
		out = append(out, ly)
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("layer docs:\n  %s", strings.Join(errs, "\n  "))
	}
	return out, nil
}

// edgeRow is one namespace pair and destination port from goldmane_edges,
// already limited to allowed flows seen in the last 30 days.
type edgeRow struct {
	Src   string `json:"src_ns"`
	Dst   string `json:"dst_ns"`
	Port  int    `json:"dst_port"`
	Flows int64  `json:"flows"`
}

type graphEdge struct {
	Src   string `json:"src"`
	Dst   string `json:"dst"`
	Flows int64  `json:"flows"`
}

type graph struct {
	Nodes  []string            `json:"nodes"`
	Edges  []graphEdge         `json:"edges"`
	Badges map[string][]string `json:"badges"`
}

// plumbingNS are Plumbing edge namespaces: their flows touch almost every
// namespace and say nothing about how the homelab fits together. "-" is host
// traffic (kubelet probes and node-level clients).
var plumbingNS = map[string]bool{
	"-": true, "kube-system": true, "monitoring": true, "uptime-kuma": true,
	"verify": true, "traefik": true, "calico-system": true,
}

// badgeFor reduces shared infrastructure to a "uses X" badge instead of an
// edge, so the public graph never draws who can reach Vault or the databases
// (ADR-0037).
func badgeFor(dst string, port int) string {
	if !infraNS[dst] {
		return ""
	}
	switch dst {
	case "dbaas":
		if port == 3306 {
			return "mysql"
		}
		return "postgres"
	case "redis":
		return "redis"
	case "vault":
		return "vault"
	case "mailserver":
		return "mail"
	}
	return ""
}

// infraNS are the shared-infrastructure namespaces that badgeFor reduces to
// badges. They are never nodes, even when they also host a catalog service.
var infraNS = map[string]bool{"dbaas": true, "redis": true, "vault": true, "mailserver": true}

// buildGraph keeps flows between visible namespaces only: both ends must have
// a catalog service on the page. Everything else is dropped or reduced to a
// badge on the source.
func buildGraph(rows []edgeRow, visible map[string]bool) graph {
	pair := map[[2]string]int64{}
	badges := map[string]map[string]bool{}
	for _, r := range rows {
		if r.Port == 53 || plumbingNS[r.Src] || plumbingNS[r.Dst] || r.Src == r.Dst || !visible[r.Src] || infraNS[r.Src] {
			continue
		}
		if b := badgeFor(r.Dst, r.Port); b != "" {
			if badges[r.Src] == nil {
				badges[r.Src] = map[string]bool{}
			}
			badges[r.Src][b] = true
			continue
		}
		if visible[r.Dst] {
			pair[[2]string{r.Src, r.Dst}] += r.Flows
		}
	}
	g := graph{Edges: []graphEdge{}, Badges: map[string][]string{}}
	for k, n := range pair {
		g.Edges = append(g.Edges, graphEdge{Src: k[0], Dst: k[1], Flows: n})
	}
	sort.Slice(g.Edges, func(i, j int) bool {
		if g.Edges[i].Src != g.Edges[j].Src {
			return g.Edges[i].Src < g.Edges[j].Src
		}
		return g.Edges[i].Dst < g.Edges[j].Dst
	})
	for ns, set := range badges {
		for b := range set {
			g.Badges[ns] = append(g.Badges[ns], b)
		}
		sort.Strings(g.Badges[ns])
	}
	for ns := range visible {
		if !infraNS[ns] {
			g.Nodes = append(g.Nodes, ns)
		}
	}
	sort.Strings(g.Nodes)
	return g
}

type hardwareKit struct {
	Name string `yaml:"name" json:"name"`
	Role string `yaml:"role" json:"role"`
	// Live names the exporter that fills in this box's numbers ("proxmox").
	Live string `yaml:"live" json:"live,omitempty"`
}

type hardwareSite struct {
	Name string        `yaml:"name" json:"name"`
	Role string        `yaml:"role" json:"role"`
	Kit  []hardwareKit `yaml:"kit" json:"kit"`
}

func parseHardware(b []byte) ([]hardwareSite, error) {
	var doc struct {
		Sites []hardwareSite `yaml:"sites"`
	}
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("cannot parse hardware.yaml: %w", err)
	}
	return doc.Sites, nil
}
