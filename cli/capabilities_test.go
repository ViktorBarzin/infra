package main

import (
	"strings"
	"testing"
)

// The 2026-08-31 session study (docs/agents/2026-08-31-session-reflection.md)
// measured the failure these tests guard against: `homelab services` listed the
// shared Android emulator the whole time, and it was consulted 85 times in 30
// days while `logs query` — whose rule names both the moment and the built-in it
// beats — ran 3,037 times. The capability existed and nothing nominated it at
// the moment a decision was made.
//
// So these tests assert two things the inventory alone cannot give us: that the
// index is keyed by the TASK rather than the service name, and that asking in
// the words someone actually uses finds it.

func TestCapabilitiesCoverTheMeasuredMisses(t *testing.T) {
	// Each entry is a theme from the study that a task-keyed index must answer.
	// The want strings are what the answer has to name to be useful.
	cases := []struct {
		task string
		want []string
	}{
		{"reproduce a bug someone saw on their phone", []string{"android-emulator"}},
		{"test a mobile layout with a real keyboard", []string{"android-emulator"}},
		{"find a credential for a third-party API", []string{"vault"}},
		{"read the systemd journal of this box", []string{"logs query", "devvm-journal"}},
		{"plan or apply a terraform stack", []string{"homelab tf"}},
		{"create a worktree for a task", []string{"homelab work start"}},
		{"query a database in the cluster", []string{"homelab k8s db"}},
		{"check whether a service is reachable from outside", []string{"homelab net check"}},
	}
	for _, c := range cases {
		hits := matchCapabilities(capabilities(), c.task)
		if len(hits) == 0 {
			t.Errorf("task %q found no capability", c.task)
			continue
		}
		joined := strings.ToLower(hits[0].Use + " " + strings.Join(hits[0].Detail, " "))
		for _, w := range c.want {
			if !strings.Contains(joined, strings.ToLower(w)) {
				t.Errorf("task %q -> top hit %q does not name %q", c.task, hits[0].Intent, w)
			}
		}
	}
}

// The wording Viktor ACTUALLY used on 2026-08-31 t5, which is what Claude got
// wrong. A capability index that only answers the tidy phrasing is the same
// failure the study measured: `--search mobile|phone|touch` returned nothing and
// only `android|emulator` matched, i.e. it worked only if you knew the answer.
func TestRealWorldPhrasingsFindTheEmulator(t *testing.T) {
	for _, q := range []string{
		"his firefox browser causes this issue but chrome works",
		"my friend says the page breaks in firefox on his phone",
		"reproduce a browser-specific bug",
		"only fails in safari",
		"the download fails in one browser but not another",
	} {
		hits := matchCapabilities(capabilities(), q)
		if len(hits) == 0 {
			t.Errorf("query %q found nothing", q)
			continue
		}
		var found bool
		for i, h := range hits {
			if i > 1 {
				break // must be a TOP hit, not buried
			}
			if strings.Contains(h.Use, "android-emulator") || strings.Contains(strings.Join(h.Detail, " "), "android-emulator") {
				found = true
			}
		}
		if !found {
			t.Errorf("query %q: emulator not in top 2; got %q", q, hits[0].Intent)
		}
	}
}

// A low-signal word must not drag in an unrelated row. "someone" appears in the
// paste/share intent and was matching the emulator query before the stop-word
// list and score floor went in.
func TestNoiseWordsDoNotPullUnrelatedCapabilities(t *testing.T) {
	hits := matchCapabilities(capabilities(), "reproduce a bug someone saw on their phone")
	for _, h := range hits {
		if strings.Contains(h.Intent, "share a log") {
			t.Errorf("noise match: %q surfaced for a device-repro query", h.Intent)
		}
	}
}

func TestEmulatorCapabilityStatesTheIOSLimit(t *testing.T) {
	// The study's challengers cut this theme's cost from 510 to ~148 minutes
	// precisely because the emulator cannot reproduce iOS or WebKit defects,
	// which are the majority of client-side defects in the corpus. An index
	// that sends every mobile question at the Android emulator would recreate
	// the wrong-tool problem in the other direction, so the limit is part of
	// the answer, not a footnote.
	hits := matchCapabilities(capabilities(), "reproduce a bug on a phone")
	if len(hits) == 0 {
		t.Fatal("no capability for reproducing a phone bug")
	}
	blob := strings.ToLower(strings.Join(hits[0].Detail, " "))
	if !strings.Contains(blob, "ios") {
		t.Errorf("emulator capability must state the iOS limit, got detail %q", hits[0].Detail)
	}
}

func TestCapabilitiesNameTheCompetitor(t *testing.T) {
	// The one controlled result we have (2026-08-15) is that naming the built-in
	// competitor is what makes a rule fire. Every capability that exists to beat
	// a built-in must say which one, or it is the `services` wording again.
	var missing []string
	for _, c := range capabilities() {
		if c.Instead == "" {
			continue // not every capability has a built-in rival
		}
		blob := c.Instead
		if strings.TrimSpace(blob) == "" {
			missing = append(missing, c.Intent)
		}
	}
	if len(missing) > 0 {
		t.Errorf("capabilities with an empty Instead: %v", missing)
	}
	// At least the ones the study priced must carry it.
	priced := map[string]string{
		"phone":    "playwright",
		"journal":  "journalctl",
		"worktree": "git worktree",
	}
	for taskWord, competitor := range priced {
		var found bool
		for _, c := range capabilities() {
			hay := strings.ToLower(c.Intent + " " + strings.Join(c.Synonyms, " "))
			if strings.Contains(hay, taskWord) && strings.Contains(strings.ToLower(c.Instead), competitor) {
				found = true
			}
		}
		if !found {
			t.Errorf("no capability matching %q names competitor %q", taskWord, competitor)
		}
	}
}

func TestMatchCapabilitiesRanksByOverlapNotOrder(t *testing.T) {
	caps := []capability{
		{Intent: "share a file", Synonyms: []string{"upload", "link"}, Use: "homelab share"},
		{Intent: "reproduce a bug on a phone", Synonyms: []string{"mobile", "android", "touch", "keyboard"}, Use: "android-emulator"},
	}
	hits := matchCapabilities(caps, "mobile phone keyboard bug")
	if len(hits) == 0 {
		t.Fatal("want a match")
	}
	if !strings.Contains(hits[0].Use, "android-emulator") {
		t.Errorf("best overlap should win, got %q", hits[0].Use)
	}
}

func TestMatchCapabilitiesIgnoresStopWordsAndCase(t *testing.T) {
	caps := []capability{
		{Intent: "reproduce a bug on a phone", Synonyms: []string{"mobile", "android"}, Use: "android-emulator"},
	}
	for _, q := range []string{
		"How do I REPRODUCE a bug on the phone?",
		"i want to test on a MOBILE device",
	} {
		if hits := matchCapabilities(caps, q); len(hits) == 0 {
			t.Errorf("query %q found nothing", q)
		}
	}
	// A query with nothing in common must return nothing rather than
	// everything — an index that always answers is noise.
	if hits := matchCapabilities(caps, "compile the kernel"); len(hits) != 0 {
		t.Errorf("unrelated query should not match, got %+v", hits)
	}
}

func TestRoutingTableStillDerivesFromCapabilities(t *testing.T) {
	// routingTable() is the existing contract `formatCatalog` and two older
	// tests depend on. It must keep working while capabilities() becomes the
	// single source of truth.
	rt := routingTable()
	if len(rt) < len(capabilities()) {
		t.Errorf("routing table (%d rows) should cover capabilities (%d)", len(rt), len(capabilities()))
	}
	for _, r := range rt {
		if strings.TrimSpace(r[0]) == "" || strings.TrimSpace(r[1]) == "" {
			t.Errorf("routing row has an empty half: %+v", r)
		}
	}
}

func TestFilterServicesMatchesTaskWords(t *testing.T) {
	// `homelab services --search mobile|phone|touch|viewport` returned nothing
	// before this change; only `android|emulator` matched, which requires
	// already knowing the answer. Task words must reach the row.
	svcs := []service{
		{Name: "Android Emulator", Host: "android-emulator.viktorbarzin.me",
			Description: "Shared Android testing instance (adb + noVNC)"},
		{Name: "Immich", Host: "immich.viktorbarzin.me", Description: "Photos library"},
	}
	for _, q := range []string{"mobile", "phone", "touch", "reproduce", "emulator"} {
		got := filterServices(svcs, q)
		if len(got) != 1 || got[0].Host != "android-emulator.viktorbarzin.me" {
			t.Errorf("search %q: want the emulator row, got %+v", q, got)
		}
	}
	if got := filterServices(svcs, "photos"); len(got) != 1 || got[0].Host != "immich.viktorbarzin.me" {
		t.Errorf("plain description search regressed: %+v", got)
	}
}

func TestFormatHowOutputIsActionable(t *testing.T) {
	// Viktor reads these on a phone. The answer must carry the command, not a
	// pointer to where the command is documented.
	out := formatHow(matchCapabilities(capabilities(), "reproduce a bug someone saw on their phone"), "reproduce a bug someone saw on their phone")
	for _, want := range []string{"android-emulator", "adb", "NOT"} {
		if !strings.Contains(out, want) {
			t.Errorf("how output missing %q:\n%s", want, out)
		}
	}
}

func TestFormatHowSaysSoWhenNothingMatches(t *testing.T) {
	out := formatHow(nil, "compile the kernel")
	if !strings.Contains(strings.ToLower(out), "no capability") {
		t.Errorf("want an explicit miss, got:\n%s", out)
	}
	// A miss must route somewhere rather than dead-end.
	if !strings.Contains(out, "homelab services") {
		t.Errorf("a miss should point at the full inventory:\n%s", out)
	}
}
