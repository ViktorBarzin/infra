package main

import "testing"

func TestQueryArg(t *testing.T) {
	if got := queryArg([]string{"up"}, nil); got != "up" {
		t.Errorf(`queryArg(["up"]) = %q, want "up"`, got)
	}
	if got := queryArg([]string{"up", "--json"}, nil); got != "up" {
		t.Errorf(`--json should be dropped, got %q`, got)
	}
	// single quoted PromQL arrives as one token
	if got := queryArg([]string{"count by (node) (up)", "--json"}, nil); got != "count by (node) (up)" {
		t.Errorf(`quoted query mangled: %q`, got)
	}
	// value-flags and their values are skipped, query survives
	vf := map[string]bool{"--since": true, "--limit": true}
	if got := queryArg([]string{`{app="x"}`, "--since", "1h", "--limit", "50"}, vf); got != `{app="x"}` {
		t.Errorf(`value-flag skipping failed: %q`, got)
	}
}

func TestLabelStr(t *testing.T) {
	got := labelStr(map[string]string{"__name__": "up", "job": "x", "instance": "y"})
	if got != "up{instance=y,job=x}" { // __name__ extracted, rest sorted
		t.Errorf("labelStr = %q", got)
	}
	if got := labelStr(map[string]string{"alertname": "Foo"}); got != "{alertname=Foo}" {
		t.Errorf("labelStr (no __name__) = %q", got)
	}
}

func TestOneLineList(t *testing.T) {
	if got := oneLineList("  "); got != "(none)" {
		t.Errorf("empty = %q, want (none)", got)
	}
	if got := oneLineList("a\nb"); got != "a, b" {
		t.Errorf("multi = %q, want 'a, b'", got)
	}
}

func TestHostOnly(t *testing.T) {
	if got := hostOnly("foo.me/path"); got != "foo.me" {
		t.Errorf("hostOnly = %q", got)
	}
	if got := hostOnly("foo.me"); got != "foo.me" {
		t.Errorf("hostOnly = %q", got)
	}
}
