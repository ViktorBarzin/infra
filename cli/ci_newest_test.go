package main

import "testing"

// Shipped 2026-08-31 and wrong the same day: `ci watch --repo infra` with no
// commit reported pipeline #1324 (a failing one belonging to another session)
// while #1330 already existed. findPipeline returned ps[0] and trusted the API
// to hand back newest-first. It does not reliably — concurrent pipelines
// interleave — and the failure mode is the worst kind: a confident report about
// somebody else's build.
func TestNewestPipelinePicksHighestNumber(t *testing.T) {
	cases := []struct {
		name string
		in   []wpPipeline
		want int
	}{
		{"already newest-first", []wpPipeline{{Number: 1330}, {Number: 1329}, {Number: 1324}}, 1330},
		{"the observed interleaving", []wpPipeline{{Number: 1324}, {Number: 1330}, {Number: 1329}}, 1330},
		{"oldest-first", []wpPipeline{{Number: 1324}, {Number: 1329}, {Number: 1330}}, 1330},
		{"single", []wpPipeline{{Number: 7}}, 7},
	}
	for _, c := range cases {
		got := newestPipeline(c.in)
		if got.Number != c.want {
			t.Errorf("%s: got #%d, want #%d", c.name, got.Number, c.want)
		}
	}
}

func TestNewestPipelineOnEmptyIsZero(t *testing.T) {
	// Callers check len(ps) first; this must not panic regardless.
	if got := newestPipeline(nil); got.Number != 0 {
		t.Errorf("empty slice should give the zero value, got #%d", got.Number)
	}
}

// A commit lookup must still win over recency: asking about a specific commit
// means that commit's pipeline, even when a newer unrelated one exists.
func TestPickPipelinePrefersTheNamedCommit(t *testing.T) {
	ps := []wpPipeline{
		{Number: 1330, Commit: "85ace43a11"},
		{Number: 1329, Commit: "e32fc15b22"},
	}
	got, err := pickPipeline(ps, "e32fc15b")
	if err != nil {
		t.Fatal(err)
	}
	if got.Number != 1329 {
		t.Errorf("commit lookup got #%d, want #1329", got.Number)
	}
	if _, err := pickPipeline(ps, "deadbeef"); err == nil {
		t.Error("an unknown commit should error, not fall back to the newest")
	}
	// No commit -> newest by number, not list order.
	got, err = pickPipeline([]wpPipeline{{Number: 1324}, {Number: 1330}}, "")
	if err != nil || got.Number != 1330 {
		t.Errorf("no-commit got #%d err=%v, want #1330", got.Number, err)
	}
}
