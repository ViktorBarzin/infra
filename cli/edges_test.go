package main

import (
	"strings"
	"testing"
)

func TestParseEdgesArgs(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want edgesOpts
	}{
		{"defaults", nil, edgesOpts{limit: 200}},
		{"ns", []string{"--ns", "immich"}, edgesOpts{ns: "immich", limit: 200}},
		{"ns equals", []string{"--ns=immich"}, edgesOpts{ns: "immich", limit: 200}},
		{"src dst", []string{"--src", "a", "--dst", "b"}, edgesOpts{src: "a", dst: "b", limit: 200}},
		{"peers-of", []string{"--peers-of", "authentik"}, edgesOpts{peersOf: "authentik", limit: 200}},
		{"denied json", []string{"--denied", "--json"}, edgesOpts{denied: true, asJSON: true, limit: 200}},
		{"new-since", []string{"--new-since", "24h"}, edgesOpts{newSince: "24h", limit: 200}},
		{"limit", []string{"--limit", "50"}, edgesOpts{limit: 50}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseEdgesArgs(c.args)
			if err != nil {
				t.Fatalf("parseEdgesArgs(%v) error: %v", c.args, err)
			}
			if got != c.want {
				t.Fatalf("parseEdgesArgs(%v) = %+v, want %+v", c.args, got, c.want)
			}
		})
	}
}

func TestParseEdgesArgsErrors(t *testing.T) {
	for _, args := range [][]string{
		{"--limit", "abc"},
		{"--bogus"},
	} {
		if _, err := parseEdgesArgs(args); err == nil {
			t.Errorf("parseEdgesArgs(%v) expected error, got nil", args)
		}
	}
}

func TestBuildEdgesQueryDefaults(t *testing.T) {
	q, err := buildEdgesQuery(edgesOpts{limit: 200})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"FROM edge", "ORDER BY first_seen DESC", "LIMIT 200"} {
		if !strings.Contains(q, want) {
			t.Errorf("query %q missing %q", q, want)
		}
	}
	if strings.Contains(q, "WHERE") {
		t.Errorf("no-filter query should have no WHERE: %q", q)
	}
}

func TestBuildEdgesQueryFilters(t *testing.T) {
	cases := []struct {
		name string
		o    edgesOpts
		want string
	}{
		{"ns both directions", edgesOpts{ns: "immich", limit: 10}, "(src_ns = 'immich' OR dst_ns = 'immich')"},
		{"src only", edgesOpts{src: "authentik", limit: 10}, "src_ns = 'authentik'"},
		{"dst only", edgesOpts{dst: "dbaas", limit: 10}, "dst_ns = 'dbaas'"},
		{"denied", edgesOpts{denied: true, limit: 10}, "action = 'deny'"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			q, err := buildEdgesQuery(c.o)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(q, "WHERE") || !strings.Contains(q, c.want) {
				t.Errorf("query %q missing WHERE/%q", q, c.want)
			}
		})
	}
}

func TestBuildEdgesQueryCombinedFiltersAnded(t *testing.T) {
	q, err := buildEdgesQuery(edgesOpts{src: "a", denied: true, limit: 5})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(q, "src_ns = 'a' AND action = 'deny'") {
		t.Errorf("combined filters not AND'd: %q", q)
	}
}

func TestBuildEdgesQueryPeersOf(t *testing.T) {
	q, err := buildEdgesQuery(edgesOpts{peersOf: "authentik", limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"DISTINCT", "src_ns = 'authentik'", "dst_ns = 'authentik'", "UNION"} {
		if !strings.Contains(q, want) {
			t.Errorf("peers-of query %q missing %q", q, want)
		}
	}
}

func TestBuildEdgesQueryJSON(t *testing.T) {
	q, err := buildEdgesQuery(edgesOpts{asJSON: true, limit: 200})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(q, "json_agg") || !strings.Contains(q, "row_to_json") {
		t.Errorf("json query missing json_agg wrapper: %q", q)
	}
}

func TestBuildEdgesQueryRejectsInjection(t *testing.T) {
	for _, bad := range []string{"a'; DROP TABLE edge;--", "a b", "a;b", "a\"b"} {
		if _, err := buildEdgesQuery(edgesOpts{ns: bad, limit: 10}); err == nil {
			t.Errorf("buildEdgesQuery(ns=%q) expected validation error, got nil", bad)
		}
	}
}

func TestNewSinceCond(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"24h", "first_seen >= now() - interval '24 hours'"},
		{"7d", "first_seen >= now() - interval '7 days'"},
		{"30m", "first_seen >= now() - interval '30 minutes'"},
		{"2026-06-28", "first_seen >= '2026-06-28'"},
	}
	for _, c := range cases {
		got, err := newSinceCond(c.in)
		if err != nil {
			t.Fatalf("newSinceCond(%q) error: %v", c.in, err)
		}
		if got != c.want {
			t.Errorf("newSinceCond(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	for _, bad := range []string{"yesterday", "1y", "'; DROP", ""} {
		if _, err := newSinceCond(bad); err == nil {
			t.Errorf("newSinceCond(%q) expected error, got nil", bad)
		}
	}
}

func TestValidateNS(t *testing.T) {
	for _, ok := range []string{"immich", "calico-system", "kube-system", "Global", "pg-cluster-rw"} {
		if err := validateNS(ok); err != nil {
			t.Errorf("validateNS(%q) unexpected error: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "a b", "a'b", "a;b", "../x", "a$b"} {
		if err := validateNS(bad); err == nil {
			t.Errorf("validateNS(%q) expected error, got nil", bad)
		}
	}
}
