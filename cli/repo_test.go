package main

import "testing"

func TestPreferRemote(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{[]string{"origin", "forgejo"}, "forgejo"},
		{[]string{"forgejo"}, "forgejo"},
		{[]string{"origin"}, "origin"},
		{[]string{"upstream"}, "upstream"},
		{nil, ""},
	}
	for _, c := range cases {
		if got := preferRemote(c.in); got != c.want {
			t.Errorf("preferRemote(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestHasGitCryptAttr(t *testing.T) {
	if !hasGitCryptAttr("*.tfvars filter=git-crypt diff=git-crypt") {
		t.Error("expected git-crypt detected")
	}
	if hasGitCryptAttr("*.md text\n*.png binary") {
		t.Error("expected no git-crypt")
	}
}

func TestGitCryptFlagsShape(t *testing.T) {
	f := gitCryptFlags()
	if len(f) != 6 || f[0] != "-c" || f[1] != "filter.git-crypt.smudge=cat" {
		t.Fatalf("unexpected git-crypt flags: %v", f)
	}
}
