package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// ingressJSON builds a minimal `kubectl get ingress -A -o json` payload from
// (namespace, name, host, annotations) tuples, so tests exercise the real
// parser against the real shape rather than a hand-rolled struct.
func ingressJSON(items ...string) string {
	return `{"items":[` + strings.Join(items, ",") + `]}`
}

func ingressItem(ns, name, host string, ann string) string {
	return `{"metadata":{"namespace":"` + ns + `","name":"` + name + `","annotations":{` + ann + `}},` +
		`"spec":{"rules":[{"host":"` + host + `"}]}}`
}

const annEnabled = `"gethomepage.dev/enabled":"true"`

func TestParseServicesKeepsOnlyEnabled(t *testing.T) {
	in := ingressJSON(
		ingressItem("privatebin", "privatebin", "pb.viktorbarzin.me",
			annEnabled+`,"gethomepage.dev/name":"PrivateBin","gethomepage.dev/description":"Encrypted pastebin","gethomepage.dev/group":"Productivity"`),
		ingressItem("secret-ns", "hidden", "hidden.viktorbarzin.me", `"gethomepage.dev/enabled":"false"`),
		ingressItem("no-ann", "bare", "bare.viktorbarzin.me", `"other":"x"`),
	)
	got, err := parseServices(in)
	if err != nil {
		t.Fatalf("parseServices: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 enabled service, got %d: %+v", len(got), got)
	}
	s := got[0]
	if s.Name != "PrivateBin" || s.Host != "pb.viktorbarzin.me" || s.Description != "Encrypted pastebin" || s.Group != "Productivity" {
		t.Errorf("unexpected parse: %+v", s)
	}
}

func TestParseServicesFallsBackToIngressName(t *testing.T) {
	in := ingressJSON(ingressItem("ns", "my-app", "my-app.viktorbarzin.me", annEnabled))
	got, err := parseServices(in)
	if err != nil {
		t.Fatalf("parseServices: %v", err)
	}
	if len(got) != 1 || got[0].Name != "my app" {
		t.Fatalf("want hyphens turned into spaces, got %+v", got)
	}
	if got[0].Description != "" {
		t.Errorf("missing description should stay empty, got %q", got[0].Description)
	}
}

func TestParseServicesDedupes(t *testing.T) {
	// The same host is often served by more than one ingress object (path
	// carve-outs). The catalog should list it once.
	item := ingressItem("learn", "learn", "learn.viktorbarzin.me", annEnabled+`,"gethomepage.dev/name":"Learn"`)
	got, err := parseServices(ingressJSON(item, item))
	if err != nil {
		t.Fatalf("parseServices: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want deduped to 1, got %d", len(got))
	}
}

func TestParseServicesSortsByName(t *testing.T) {
	in := ingressJSON(
		ingressItem("z", "zulu", "z.viktorbarzin.me", annEnabled+`,"gethomepage.dev/name":"Zulu"`),
		ingressItem("a", "alpha", "a.viktorbarzin.me", annEnabled+`,"gethomepage.dev/name":"Alpha"`),
	)
	got, _ := parseServices(in)
	if len(got) != 2 || got[0].Name != "Alpha" {
		t.Fatalf("want name-sorted, got %+v", got)
	}
}

func TestParseServicesSkipsHostlessIngress(t *testing.T) {
	in := `{"items":[{"metadata":{"namespace":"n","name":"x","annotations":{` + annEnabled + `}},"spec":{"rules":[]}}]}`
	got, err := parseServices(in)
	if err != nil {
		t.Fatalf("parseServices: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("an ingress with no host cannot be routed to, want 0, got %+v", got)
	}
}

func TestFilterServicesMatchesAllFields(t *testing.T) {
	svcs := []service{
		{Name: "PrivateBin", Host: "pb.viktorbarzin.me", Description: "Encrypted pastebin"},
		{Name: "Immich", Host: "immich.viktorbarzin.me", Description: "Photo library"},
	}
	for _, tc := range []struct{ query, want string }{
		{"privatebin", "PrivateBin"}, // name, case-insensitive
		{"pb.viktor", "PrivateBin"},  // host substring
		{"pastebin", "PrivateBin"},   // description
		{"PHOTO", "Immich"},          // description, case-insensitive
	} {
		got := filterServices(svcs, tc.query)
		if len(got) != 1 || got[0].Name != tc.want {
			t.Errorf("filter(%q) = %+v, want just %s", tc.query, got, tc.want)
		}
	}
	if got := filterServices(svcs, ""); len(got) != 2 {
		t.Errorf("empty query should not filter, got %d", len(got))
	}
	if got := filterServices(svcs, "nothing-matches"); len(got) != 0 {
		t.Errorf("want no matches, got %+v", got)
	}
}

func TestFormatCatalogLeadsWithRoutingTable(t *testing.T) {
	out := formatCatalog([]service{{Name: "PrivateBin", Host: "pb.viktorbarzin.me", Description: "Encrypted pastebin"}}, "")
	// The routing table is the part that changes behaviour, so it must come
	// before the inventory an agent would otherwise have to read through.
	ri := strings.Index(out, "homelab paste")
	ii := strings.Index(out, "pb.viktorbarzin.me")
	if ri < 0 || ii < 0 {
		t.Fatalf("want both routing table and inventory in output:\n%s", out)
	}
	if ri > ii {
		t.Errorf("routing table must precede the inventory")
	}
	for _, want := range []string{"homelab paste", "homelab share", "homelab pages publish"} {
		if !strings.Contains(out, want) {
			t.Errorf("routing table missing %q", want)
		}
	}
}

func TestFormatCatalogShowsCountAndFilter(t *testing.T) {
	svcs := []service{
		{Name: "A", Host: "a.viktorbarzin.me"},
		{Name: "B", Host: "b.viktorbarzin.me"},
	}
	if out := formatCatalog(svcs, ""); !strings.Contains(out, "2 services") {
		t.Errorf("want a total count, got:\n%s", out)
	}
	// A filtered listing must say what it filtered on, so a short result is not
	// mistaken for "this is everything we run".
	out := formatCatalog(svcs[:1], "a")
	if !strings.Contains(out, `matching "a"`) {
		t.Errorf("filtered output must name the filter, got:\n%s", out)
	}
}

func TestFormatCatalogMarksMissingDescription(t *testing.T) {
	out := formatCatalog([]service{{Name: "Bare", Host: "bare.viktorbarzin.me"}}, "")
	if !strings.Contains(out, "Bare") || !strings.Contains(out, "bare.viktorbarzin.me") {
		t.Errorf("a description-less service must still be listed, got:\n%s", out)
	}
}

func TestServicesArgsParsing(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{}, ""},
		{[]string{"--search", "paste"}, "paste"},
		{[]string{"paste"}, "paste"}, // bare word is a search term too
	} {
		if got := parseServicesQuery(tc.args); got != tc.want {
			t.Errorf("parseServicesQuery(%v) = %q, want %q", tc.args, got, tc.want)
		}
	}
}

// --json exists so a script can consume the inventory. It emits ONLY the
// inventory: the routing table above it is prose for a human and would have to
// be stripped back out by every consumer.

func TestCatalogJSONEmitsOneRowPerService(t *testing.T) {
	svcs := []service{
		{Name: "PrivateBin", Host: "pb.viktorbarzin.me", Description: "Encrypted pastebin", Group: "Productivity"},
		{Name: "VPN egress (UK)", Host: "proxy-egress-uk.proxy.svc.cluster.local:8888", Internal: true},
	}
	out, err := catalogJSON(svcs)
	if err != nil {
		t.Fatalf("catalogJSON: %v", err)
	}
	var got []map[string]interface{}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("output is not a JSON array: %v\n%s", err, out)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows, got %d: %s", len(got), out)
	}
	if got[0]["name"] != "PrivateBin" || got[0]["host"] != "pb.viktorbarzin.me" ||
		got[0]["description"] != "Encrypted pastebin" || got[0]["group"] != "Productivity" {
		t.Errorf("first row = %+v", got[0])
	}
	// The in-cluster marker must survive into JSON. Without it a consumer
	// treats an in-cluster address as a URL and reports the service down.
	if got[0]["in_cluster"] != false {
		t.Errorf("ingress-backed row should not be in_cluster: %+v", got[0])
	}
	if got[1]["in_cluster"] != true {
		t.Errorf("ClusterIP-backed row should be in_cluster: %+v", got[1])
	}
}

func TestCatalogJSONKeepsKeysWhenValuesAreEmpty(t *testing.T) {
	// A script indexes by key. Dropping absent descriptions would make every
	// consumer handle a missing key instead of an empty string.
	out, err := catalogJSON([]service{{Name: "bare", Host: "bare.viktorbarzin.me"}})
	if err != nil {
		t.Fatalf("catalogJSON: %v", err)
	}
	var got []map[string]interface{}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, k := range []string{"name", "host", "description", "group", "in_cluster"} {
		if _, ok := got[0][k]; !ok {
			t.Errorf("key %q missing: %s", k, out)
		}
	}
}

func TestCatalogJSONEmptyResultIsAnEmptyArray(t *testing.T) {
	// `--search nope --json | jq length` must yield 0, not choke on `null`.
	out, err := catalogJSON(nil)
	if err != nil {
		t.Fatalf("catalogJSON: %v", err)
	}
	if strings.TrimSpace(out) != "[]" {
		t.Errorf("want [], got %q", out)
	}
}

func TestParseServicesQueryIgnoresTheJSONFlag(t *testing.T) {
	// --json must not be mistaken for a search term, in either position.
	if q := parseServicesQuery([]string{"--json"}); q != "" {
		t.Errorf("query = %q, want empty", q)
	}
	if q := parseServicesQuery([]string{"--json", "paste"}); q != "paste" {
		t.Errorf("query = %q, want \"paste\"", q)
	}
	if q := parseServicesQuery([]string{"--search", "paste", "--json"}); q != "paste" {
		t.Errorf("query = %q, want \"paste\"", q)
	}
}
