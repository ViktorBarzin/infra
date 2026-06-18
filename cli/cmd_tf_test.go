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
