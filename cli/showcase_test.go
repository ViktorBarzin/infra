package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// showcaseIngressJSON builds a one-item kubectl ingress listing for the showcase tests.
func showcaseIngressJSON(t *testing.T, ns, name, host string, ann map[string]string) string {
	t.Helper()
	item := map[string]any{
		"metadata": map[string]any{"name": name, "namespace": ns, "annotations": ann},
		"spec":     map[string]any{"rules": []any{map[string]any{"host": host}}},
	}
	b, err := json.Marshal(map[string]any{"items": []any{item}})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func catalogAnn(extra map[string]string) map[string]string {
	a := map[string]string{
		"gethomepage.dev/enabled":     "true",
		"gethomepage.dev/name":        "Immich",
		"gethomepage.dev/description": "Photos",
		"gethomepage.dev/group":       "Media",
		"gethomepage.dev/icon":        "immich.png",
	}
	for k, v := range extra {
		a[k] = v
	}
	return a
}

func TestShowcaseStack(t *testing.T) {
	stacks := map[string]bool{"immich": true, "servarr": true, "blog": true, "real-estate-crawler": true}
	cases := []struct {
		ns, want string
		ok       bool
	}{
		{"immich", "immich", true},
		{"aiostreams", "servarr", true},
		{"website", "blog", true},
		{"realestate-crawler", "real-estate-crawler", true},
		{"nowhere", "", false},
	}
	for _, c := range cases {
		got, ok := showcaseStack(c.ns, stacks)
		if got != c.want || ok != c.ok {
			t.Errorf("showcaseStack(%q) = %q, %v; want %q, %v", c.ns, got, ok, c.want, c.ok)
		}
	}
}

func TestAccessState(t *testing.T) {
	cases := []struct{ mw, want string }{
		{"traefik-retry@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd", accessSSO},
		{"traefik-retry@kubernetescrd,traefik-home-lans-only@kubernetescrd", accessLAN},
		{"traefik-local-only@kubernetescrd", accessLAN},
		{"traefik-retry@kubernetescrd,turnstile-gate-auth-standard@kubernetescrd", accessApp},
		{"", accessApp},
	}
	for _, c := range cases {
		if got := accessState(c.mw); got != c.want {
			t.Errorf("accessState(%q) = %q, want %q", c.mw, got, c.want)
		}
	}
}

// The page must never call a service "public": a reader would take it as a
// list of unauthenticated targets (ADR-0037).
func TestAccessStateNeverPublic(t *testing.T) {
	for _, mw := range []string{"", "traefik-authentik-forward-auth-public@kubernetescrd", "x"} {
		switch accessState(mw) {
		case accessSSO, accessApp, accessLAN:
		default:
			t.Errorf("accessState(%q) produced an unknown state", mw)
		}
	}
}

func TestRouteFor(t *testing.T) {
	mw := "traefik-retry@kubernetescrd,turnstile-gate-auth-standard@kubernetescrd,traefik-rate-limit@kubernetescrd," +
		"traefik-ai-bot-block@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd"
	got := routeFor("proxied", mw)
	want := route{DNS: "proxied", Gates: []string{"crowdsec", "turnstile", "ai-bot-block", "rate-limit", "authentik"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("routeFor = %+v, want %+v", got, want)
	}
	if lan := routeFor("internal", "traefik-home-lans-only@kubernetescrd"); !reflect.DeepEqual(lan.Gates, []string{"crowdsec", "lan-only"}) {
		t.Fatalf("lan gates = %v", lan.Gates)
	}
}

func TestParseShowcaseServices(t *testing.T) {
	stacks := map[string]bool{"immich": true}
	raw := showcaseIngressJSON(t, "immich", "immich", "immich.viktorbarzin.me", catalogAnn(map[string]string{
		"cloudflare.viktorbarzin.me/dns-type":              "non-proxied",
		"traefik.ingress.kubernetes.io/router.middlewares": "traefik-rate-limit@kubernetescrd",
		"gethomepage.dev/widget.password":                  "hunter2",
	}))
	svcs, err := parseShowcaseServices(raw, stacks, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(svcs) != 1 {
		t.Fatalf("got %d services, want 1", len(svcs))
	}
	s := svcs[0]
	if s.Name != "Immich" || s.Namespace != "immich" || s.Stack != "immich" || s.Access != accessApp {
		t.Fatalf("unexpected service %+v", s)
	}
	if s.StackURL != "https://github.com/ViktorBarzin/infra/blob/master/stacks/immich/main.tf" {
		t.Fatalf("stack url = %q", s.StackURL)
	}
	if s.Route.DNS != "non-proxied" {
		t.Fatalf("route dns = %q", s.Route.DNS)
	}
	// Annotations are read by name, never copied: widget credentials live on
	// some ingresses and must not reach a public page.
	b, _ := json.Marshal(svcs)
	if strings.Contains(string(b), "hunter2") {
		t.Fatal("snapshot leaked an annotation value it does not read")
	}
}

func TestParseShowcaseServicesOptOut(t *testing.T) {
	stacks := map[string]bool{"immich": true}
	hidden := showcaseIngressJSON(t, "immich", "immich", "immich.viktorbarzin.me",
		catalogAnn(map[string]string{showcaseHiddenAnnotation: "true"}))
	if svcs, _ := parseShowcaseServices(hidden, stacks, nil); len(svcs) != 0 {
		t.Fatalf("ingress opt-out ignored: %+v", svcs)
	}
	plain := showcaseIngressJSON(t, "immich", "immich", "immich.viktorbarzin.me", catalogAnn(nil))
	if svcs, _ := parseShowcaseServices(plain, stacks, map[string]bool{"immich": true}); len(svcs) != 0 {
		t.Fatalf("namespace opt-out ignored: %+v", svcs)
	}
}

// Every visible service must link to a real stack; a miss fails the build
// rather than publishing a dead GitHub link.
func TestParseShowcaseServicesUnresolvedStack(t *testing.T) {
	raw := showcaseIngressJSON(t, "nowhere", "x", "x.viktorbarzin.me", catalogAnn(nil))
	if _, err := parseShowcaseServices(raw, map[string]bool{}, nil); err == nil {
		t.Fatal("want an error for a namespace with no stack")
	}
}

func TestDocSummary(t *testing.T) {
	got, err := docSummary("# Storage\n\n<!-- showcase: Databases get block volumes. -->\n\nLast updated: 2026-05-24\n")
	if err != nil || got != "Databases get block volumes." {
		t.Fatalf("docSummary = %q, %v", got, err)
	}
	if _, err := docSummary("# Storage\n\nLast updated: 2026-05-24\n"); err == nil {
		t.Fatal("want an error when the summary is missing")
	}
	// Numbers go stale and would contradict the live stats beside them.
	if _, err := docSummary("# X\n<!-- showcase: Runs 70+ services. -->\n"); err == nil {
		t.Fatal("want an error for a summary containing a number")
	}
}

func TestDocTitle(t *testing.T) {
	if got := docTitle("intro\n# Storage Architecture\n## Overview"); got != "Storage Architecture" {
		t.Fatalf("docTitle = %q", got)
	}
}

func TestBuildGraph(t *testing.T) {
	visible := map[string]bool{"immich": true, "frigate": true, "authentik": true}
	rows := []edgeRow{
		{Src: "immich", Dst: "dbaas", Port: 5432, Flows: 10},
		{Src: "immich", Dst: "redis", Port: 6379, Flows: 5},
		{Src: "immich", Dst: "authentik", Port: 9000, Flows: 3},
		{Src: "frigate", Dst: "immich", Port: 80, Flows: 1},
		{Src: "monitoring", Dst: "immich", Port: 8080, Flows: 99}, // scrape
		{Src: "traefik", Dst: "immich", Port: 2283, Flows: 99},    // ingress
		{Src: "-", Dst: "immich", Port: 2283, Flows: 9},           // host traffic
		{Src: "immich", Dst: "kube-system", Port: 53, Flows: 50},  // DNS
		{Src: "immich", Dst: "immich", Port: 3003, Flows: 7},      // self
		{Src: "payslip", Dst: "immich", Port: 80, Flows: 2},       // not visible
		{Src: "immich", Dst: "vault", Port: 8200, Flows: 1},
	}
	g := buildGraph(rows, visible)
	wantEdges := []graphEdge{
		{Src: "frigate", Dst: "immich", Flows: 1},
		{Src: "immich", Dst: "authentik", Flows: 3},
	}
	if !reflect.DeepEqual(g.Edges, wantEdges) {
		t.Fatalf("edges = %+v, want %+v", g.Edges, wantEdges)
	}
	if !reflect.DeepEqual(g.Badges["immich"], []string{"postgres", "redis", "vault"}) {
		t.Fatalf("badges = %v", g.Badges["immich"])
	}
	for _, n := range g.Nodes {
		if n == "payslip" || n == "monitoring" || n == "dbaas" {
			t.Fatalf("node %q must not be published", n)
		}
	}
}

// Shared infrastructure is only ever a badge, even when its namespace also
// hosts a catalog service (dbaas runs pgAdmin): no node, no edges out of it.
func TestBuildGraphInfraNamespacesAreNeverNodes(t *testing.T) {
	visible := map[string]bool{"dbaas": true, "vault": true, "n8n": true}
	rows := []edgeRow{
		{Src: "dbaas", Dst: "n8n", Port: 5678, Flows: 2},
		{Src: "n8n", Dst: "dbaas", Port: 5432, Flows: 9},
	}
	g := buildGraph(rows, visible)
	if len(g.Edges) != 0 {
		t.Fatalf("edges = %+v, want none", g.Edges)
	}
	if !reflect.DeepEqual(g.Nodes, []string{"n8n"}) {
		t.Fatalf("nodes = %v, want [n8n]", g.Nodes)
	}
}

func TestParseHardware(t *testing.T) {
	hw, err := parseHardware([]byte("sites:\n  - name: Sofia\n    role: Main site.\n    kit:\n      - name: Dell PowerEdge R730\n        role: The one server.\n        live: proxmox\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(hw) != 1 || hw[0].Name != "Sofia" || hw[0].Kit[0].Live != "proxmox" {
		t.Fatalf("parseHardware = %+v", hw)
	}
}
