package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// Tracer bullet: the dispatcher must route `homelab <path...> <args...>` to the
// command whose Path is the longest matching prefix of the input tokens, and
// hand the command the remaining args.
func TestDispatchRoutesToLongestPrefixMatch(t *testing.T) {
	var gotArgs []string
	ran := ""
	reg := []Command{
		{Path: []string{"claim"}, Tier: TierWrite, Summary: "claim a resource",
			Run: func(a []string) error { ran = "claim"; gotArgs = a; return nil }},
		{Path: []string{"tf", "plan"}, Tier: TierRead, Summary: "plan a stack",
			Run: func(a []string) error { ran = "tf plan"; gotArgs = a; return nil }},
	}

	if err := dispatch(reg, []string{"tf", "plan", "vault", "--json"}); err != nil {
		t.Fatalf("dispatch returned error: %v", err)
	}
	if ran != "tf plan" {
		t.Fatalf("routed to %q, want %q", ran, "tf plan")
	}
	if want := []string{"vault", "--json"}; !reflect.DeepEqual(gotArgs, want) {
		t.Fatalf("command got args %v, want %v", gotArgs, want)
	}
}

func TestDispatchUnknownCommandErrors(t *testing.T) {
	reg := []Command{{Path: []string{"claim"}, Run: func(a []string) error { return nil }}}
	if err := dispatch(reg, []string{"bogus"}); err == nil {
		t.Fatal("expected error for unknown command, got nil")
	}
}

// The manifest is the progressive-discovery entrypoint: one line per command
// showing the full verb path, its tier, and summary, sorted for stable output.
func TestManifestTextListsEveryCommandWithTier(t *testing.T) {
	reg := []Command{
		{Path: []string{"tf", "plan"}, Tier: TierRead, Summary: "plan a stack"},
		{Path: []string{"claim"}, Tier: TierWrite, Summary: "claim a resource"},
	}
	out := manifestText(reg)
	for _, want := range []string{"claim", "tf plan", "read", "write", "plan a stack", "claim a resource"} {
		if !strings.Contains(out, want) {
			t.Errorf("manifest text missing %q\n---\n%s", want, out)
		}
	}
	// sorted: claim (c) must appear before tf plan (t)
	if strings.Index(out, "claim") > strings.Index(out, "tf plan") {
		t.Errorf("manifest not sorted by path:\n%s", out)
	}
}

func TestManifestJSONIsParsableAndTagged(t *testing.T) {
	reg := []Command{{Path: []string{"tf", "apply"}, Tier: TierWrite, Summary: "apply a stack"}}
	out, err := manifestJSON(reg)
	if err != nil {
		t.Fatalf("manifestJSON error: %v", err)
	}
	var got []map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("manifest JSON not parsable: %v\n%s", err, out)
	}
	if len(got) != 1 || got[0]["command"] != "tf apply" || got[0]["tier"] != "write" {
		t.Fatalf("unexpected manifest JSON: %v", got)
	}
}
