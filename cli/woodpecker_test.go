package main

import "testing"

func TestParseOwnerRepo(t *testing.T) {
	cases := []struct{ in, owner, repo string }{
		{"https://forgejo.viktorbarzin.me/viktor/infra.git", "viktor", "infra"},
		{"https://forgejo.viktorbarzin.me/viktor/infra", "viktor", "infra"},
		{"git@github.com:ViktorBarzin/infra.git", "ViktorBarzin", "infra"},
		{"https://github.com/ViktorBarzin/tripit/", "ViktorBarzin", "tripit"},
	}
	for _, c := range cases {
		o, r, err := parseOwnerRepo(c.in)
		if err != nil || o != c.owner || r != c.repo {
			t.Errorf("parseOwnerRepo(%q) = (%q, %q, %v), want (%q, %q)", c.in, o, r, err, c.owner, c.repo)
		}
	}
	if _, _, err := parseOwnerRepo("nonsense"); err == nil {
		t.Error("expected error for unparseable remote")
	}
}

func TestStatusClassification(t *testing.T) {
	for _, s := range []string{"success", "failure", "error", "killed"} {
		if !isTerminalStatus(s) {
			t.Errorf("%q should be terminal", s)
		}
	}
	for _, s := range []string{"running", "pending"} {
		if isTerminalStatus(s) {
			t.Errorf("%q should not be terminal", s)
		}
	}
	if !isFailureStatus("failure") || !isFailureStatus("error") {
		t.Error("failure/error should classify as failure")
	}
	if isFailureStatus("success") {
		t.Error("success must not classify as failure")
	}
}
