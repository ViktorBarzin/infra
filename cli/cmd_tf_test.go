package main

import (
	"reflect"
	"testing"
)

func TestFirstPositional(t *testing.T) {
	cases := []struct {
		args     []string
		wantName string
		wantRest []string
	}{
		{[]string{"vault"}, "vault", []string{}},
		{[]string{"--json", "vault"}, "vault", []string{"--json"}},
		{[]string{"vault", "abc-123"}, "vault", []string{"abc-123"}},
		{[]string{"--foo", "monitoring", "extra"}, "monitoring", []string{"--foo", "extra"}},
		{[]string{"--only-flags"}, "", []string{"--only-flags"}},
	}
	for _, c := range cases {
		gotName, gotRest := firstPositional(c.args)
		if gotName != c.wantName || !reflect.DeepEqual(gotRest, c.wantRest) {
			t.Errorf("firstPositional(%v) = (%q, %v), want (%q, %v)",
				c.args, gotName, gotRest, c.wantName, c.wantRest)
		}
	}
}

// homelab tf apply used to drop everything after the stack name, so
// `homelab tf apply vault -target=helm_release.vault` silently ran a FULL
// apply (found 2026-10-02 on the Tier-0 vault stack).
func TestTfApplyArgsForwardsExtraArguments(t *testing.T) {
	cases := []struct {
		rest []string
		want []string
	}{
		{nil, []string{"apply", "--non-interactive"}},
		{[]string{}, []string{"apply", "--non-interactive"}},
		{[]string{"-target=helm_release.vault"}, []string{"apply", "--non-interactive", "-target=helm_release.vault"}},
		{[]string{"-target=a.b", "-target=c.d"}, []string{"apply", "--non-interactive", "-target=a.b", "-target=c.d"}},
		// Already non-interactive: not doubled.
		{[]string{"--non-interactive", "-target=x.y"}, []string{"apply", "--non-interactive", "-target=x.y"}},
	}
	for _, c := range cases {
		if got := tfApplyArgs(c.rest); !reflect.DeepEqual(got, c.want) {
			t.Errorf("tfApplyArgs(%v) = %v, want %v", c.rest, got, c.want)
		}
	}
}
