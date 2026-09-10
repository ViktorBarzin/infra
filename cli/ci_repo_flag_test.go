package main

import "testing"

// The 2026-08-31 session study counted 37 turns hand-rolling the Woodpecker API
// across 46 occurrences, with repo 82 (infra) the target in 26 of them. The verb
// could only ever address the repo you were standing in, so asking about another
// repo's pipeline meant curl and a numeric repo id looked up by hand.
func TestParseRepoFlagAcceptsOwnerNameAndBareName(t *testing.T) {
	cases := []struct{ in, owner, repo string }{
		{"viktor/infra", "viktor", "infra"},
		{"ViktorBarzin/tripit", "ViktorBarzin", "tripit"},
		// A bare name is the common shorthand; default the owner rather than
		// erroring, since every first-party repo here is under one owner.
		{"infra", defaultRepoOwner, "infra"},
		{"  viktor/infra  ", "viktor", "infra"},
		// A full URL is what someone pastes from the browser.
		{"https://forgejo.viktorbarzin.me/viktor/infra", "viktor", "infra"},
		{"https://forgejo.viktorbarzin.me/viktor/infra.git", "viktor", "infra"},
	}
	for _, c := range cases {
		o, r, err := parseRepoFlag(c.in)
		if err != nil {
			t.Errorf("parseRepoFlag(%q): %v", c.in, err)
			continue
		}
		if o != c.owner || r != c.repo {
			t.Errorf("parseRepoFlag(%q) = %q/%q, want %q/%q", c.in, o, r, c.owner, c.repo)
		}
	}
	for _, bad := range []string{"", "   ", "a/b/c", "/infra", "viktor/"} {
		if _, _, err := parseRepoFlag(bad); err == nil {
			t.Errorf("parseRepoFlag(%q) should error", bad)
		}
	}
}
