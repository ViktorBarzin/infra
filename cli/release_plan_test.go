package main

import (
	"sort"
	"strings"
	"testing"
)

func TestReleaseTVVersionMatchesCIVersionScript(t *testing.T) {
	// scripts/ci-version.sh in f1-stream: code = 30000 + commit count, name =
	// <last tag without v>+<count>, a count of 0 reads as 1, no tag reads 0.0.0.
	cases := []struct {
		count    int
		tag      string
		wantCode int
		wantName string
		wantImg  string
	}{
		{1520, "v2.44.2", 31520, "2.44.2+1520", "2.44.2"},
		{1425, "v2.44.2", 31425, "2.44.2+1425", "2.44.2"},
		{7, "", 30007, "0.0.0+7", "0.0.0"},
		{0, "v1.0.0", 30001, "1.0.0+1", "1.0.0"},
		{12, "2.0.0", 30012, "2.0.0+12", "2.0.0"},
	}
	for _, c := range cases {
		v := releaseVersionFor(30000, c.count, c.tag)
		if v.Code != c.wantCode || v.Name != c.wantName || v.Image != c.wantImg {
			t.Errorf("releaseVersionFor(30000, %d, %q) = %+v, want code %d name %q image %q",
				c.count, c.tag, v, c.wantCode, c.wantName, c.wantImg)
		}
	}
}

func TestReleaseClassifyPathsFollowsTheWorkflowFilters(t *testing.T) {
	spec := f1StreamRelease()
	cases := []struct {
		paths      []string
		wantServer bool
		wantTV     bool
	}{
		{[]string{"docs/adr/2026-10-30-x.md"}, false, false},
		{[]string{"README.md", "docs/design/x.png"}, false, false},
		{[]string{"android/app/src/main/java/A.kt"}, false, true},
		{[]string{"android/README.md"}, false, false},
		{[]string{".woodpecker/publish-tv.yml"}, false, true},
		{[]string{".github/workflows/android.yml"}, false, true},
		{[]string{"tracker/server.js", ".github/workflows/tracker.yml"}, false, false},
		{[]string{"frontend/src/routes/+page.svelte"}, true, false},
		{[]string{"backend/main.py"}, true, false},
		// Not in build.yml's ignore list, so it rebuilds the image too.
		{[]string{"scripts/ci-version.sh"}, true, true},
		// A directory nobody listed still deploys (build.yml excludes by list).
		{[]string{"newdir/thing.txt"}, true, false},
		{[]string{"docs/x.md", "android/app/build.gradle.kts", "backend/x.py"}, true, true},
		{nil, false, false},
	}
	for _, c := range cases {
		s, tv := spec.classify(c.paths)
		if s != c.wantServer || tv != c.wantTV {
			t.Errorf("classify(%v) = server %v tv %v, want server %v tv %v", c.paths, s, tv, c.wantServer, c.wantTV)
		}
	}
}

func TestReleaseServerDecision(t *testing.T) {
	cases := []struct {
		name string
		in   serverFacts
		want releaseAction
	}{
		{"already live", serverFacts{Auto: true, Live: liveSame, Changed: true}, actionSkipLive},
		{"already live, asked for", serverFacts{Live: liveSame, Changed: true}, actionSkipLive},
		{"older than live, asked for", serverFacts{Live: liveNewer, Changed: true}, actionRefuse},
		{"older than live, auto", serverFacts{Auto: true, Live: liveNewer, Changed: true}, actionSkipNewer},
		{"auto, nothing for the image changed", serverFacts{Auto: true, Live: liveOlder, Changed: false}, actionSkipUnchanged},
		{"asked for although unchanged", serverFacts{Live: liveOlder, Changed: false}, actionBuild},
		{"auto, changed, not built", serverFacts{Auto: true, Live: liveOlder, Changed: true}, actionBuild},
		{"auto, changed, CI built it", serverFacts{Auto: true, Live: liveOlder, Changed: true, OnRegistry: true}, actionPublishOnly},
		{"live commit unknown", serverFacts{Auto: true, Live: liveUnknown}, actionBuild},
		{"live commit unknown, image there", serverFacts{Auto: true, Live: liveUnknown, OnRegistry: true}, actionPublishOnly},
	}
	for _, c := range cases {
		if got := decideServer(c.in); got.Action != c.want {
			t.Errorf("%s: decideServer(%+v) = %v (%s), want %v", c.name, c.in, got.Action, got.Reason, c.want)
		}
	}
}

func TestReleaseTVDecision(t *testing.T) {
	cases := []struct {
		name string
		in   tvFacts
		want releaseAction
	}{
		{"same code is live", tvFacts{Auto: true, Code: 31520, LiveCode: 31520, Changed: true}, actionSkipLive},
		{"same code, asked for", tvFacts{Code: 31520, LiveCode: 31520}, actionSkipLive},
		// Two APKs must never share a code, and televisions refuse a lower one.
		{"lower code, asked for", tvFacts{Code: 31400, LiveCode: 31425}, actionRefuse},
		{"lower code, auto", tvFacts{Auto: true, Code: 31400, LiveCode: 31425, Changed: true}, actionSkipNewer},
		{"auto, app unchanged", tvFacts{Auto: true, Code: 31520, LiveCode: 31425, Changed: false, ChangeKnown: true}, actionSkipUnchanged},
		{"auto, live commit unknown", tvFacts{Auto: true, Code: 31520, LiveCode: 31425}, actionBuild},
		{"auto, changed", tvFacts{Auto: true, Code: 31520, LiveCode: 31425, Changed: true, ChangeKnown: true}, actionBuild},
		{"asked for although unchanged", tvFacts{Code: 31520, LiveCode: 31425, ChangeKnown: true}, actionBuild},
		{"CI pushed the artifact", tvFacts{Auto: true, Code: 31520, LiveCode: 31425, Changed: true, ChangeKnown: true, OnRegistry: true}, actionPublishOnly},
		{"site does not answer", tvFacts{Auto: true, Code: 31520, LiveCode: 0, LiveUnknown: true, Changed: true}, actionRefuse},
	}
	for _, c := range cases {
		if got := decideTV(c.in); got.Action != c.want {
			t.Errorf("%s: decideTV(%+v) = %v (%s), want %v", c.name, c.in, got.Action, got.Reason, c.want)
		}
	}
}

func TestReleaseDecisionsSayWhy(t *testing.T) {
	d := decideTV(tvFacts{Code: 31400, LiveCode: 31425})
	if !strings.Contains(d.Reason, "31425") || !strings.Contains(d.Reason, "31400") {
		t.Errorf("a refusal names both codes, got %q", d.Reason)
	}
}

// fakeHistory is a small commit graph: each commit's parents, first parent first.
type fakeHistory map[string][]string

func (h fakeHistory) ancestors(sha string) map[string]bool {
	seen := map[string]bool{}
	stack := []string{sha}
	for len(stack) > 0 {
		c := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if c == "" || seen[c] {
			continue
		}
		seen[c] = true
		stack = append(stack, h[c]...)
	}
	return seen
}

// count is `git rev-list --count sha`.
func (h fakeHistory) count(sha string) (int, error) { return len(h.ancestors(sha)), nil }

func (h fakeHistory) firstParents(tip string) []string {
	var out []string
	for c := tip; c != ""; {
		out = append(out, c)
		if len(h[c]) == 0 {
			break
		}
		c = h[c][0]
	}
	return out
}

// since is `git rev-list tip ^boundary` (the whole history when boundary is "").
func (h fakeHistory) since(tip string) func(string) ([]string, error) {
	return func(boundary string) ([]string, error) {
		skip := map[string]bool{}
		if boundary != "" {
			skip = h.ancestors(boundary)
		}
		var out []string
		for c := range h.ancestors(tip) {
			if !skip[c] {
				out = append(out, c)
			}
		}
		sort.Strings(out)
		return out, nil
	}
}

func TestReleaseTVBaseFoundOnALandedBranch(t *testing.T) {
	// The shape `homelab work land` leaves: a worktree branch s1..s3 off m2,
	// merged into master as M. The TV build was published from s2 before the
	// merge, so its count (4) belongs to no first-parent commit.
	h := fakeHistory{"m1": nil, "m2": {"m1"}, "m3": {"m2"},
		"s1": {"m2"}, "s2": {"s1"}, "s3": {"s2"}, "M": {"m3", "s3"}}
	got, err := tvBaseCandidates(h.firstParents("M"), h.count, h.since("M"), 4)
	if err != nil || len(got) != 1 || got[0] != "s2" {
		t.Errorf("want [s2], got %v (err %v)", got, err)
	}
}

func TestReleaseTVBaseOnFirstParent(t *testing.T) {
	h := fakeHistory{"m1": nil, "m2": {"m1"}, "m3": {"m2"}, "m4": {"m3"}}
	got, err := tvBaseCandidates(h.firstParents("m4"), h.count, h.since("m4"), 2)
	if err != nil || len(got) != 1 || got[0] != "m2" {
		t.Errorf("want [m2], got %v (err %v)", got, err)
	}
	if got, _ := tvBaseCandidates(h.firstParents("m4"), h.count, h.since("m4"), 9); len(got) != 0 {
		t.Errorf("a count above the tip has no base, got %v", got)
	}
}

func TestReleaseTVBaseReturnsEveryCommitSharingTheCount(t *testing.T) {
	// m4 on master's first parent and s2 on a merged branch both have count 4.
	// Either could be the live build's source, so both come back.
	h := fakeHistory{"m1": nil, "m2": {"m1"}, "m3": {"m2"}, "m4": {"m3"},
		"s1": {"m2"}, "s2": {"s1"}, "s3": {"s2"}, "M": {"m4", "s3"}}
	got, err := tvBaseCandidates(h.firstParents("M"), h.count, h.since("M"), 4)
	sort.Strings(got)
	if err != nil || strings.Join(got, ",") != "m4,s2" {
		t.Errorf("want [m4 s2], got %v (err %v)", got, err)
	}
}

func TestReleaseTVChangedSinceAnyBase(t *testing.T) {
	// The live build came from s2, which lacks an app change m4 carries.
	// The diff from m4 shows nothing, the diff from s2 shows the app change.
	diffs := map[string][]string{"m4": {"backend/main.py"}, "s2": {"android/app/src/main/Foo.kt", "backend/main.py"}}
	changed := func(from string) ([]string, error) { return diffs[from], nil }
	isApp := func(paths []string) bool {
		for _, p := range paths {
			if strings.HasPrefix(p, "android/") {
				return true
			}
		}
		return false
	}
	if got, err := tvChangedSinceAny([]string{"m4", "s2"}, changed, isApp); err != nil || !got {
		t.Errorf("an app change since any candidate counts, got %v (err %v)", got, err)
	}
	if got, err := tvChangedSinceAny([]string{"m4"}, changed, isApp); err != nil || got {
		t.Errorf("no app change since m4, got %v (err %v)", got, err)
	}
}

func TestReleaseTVReasonSaysWhenTheBaseIsUnknown(t *testing.T) {
	d := decideTV(tvFacts{Auto: true, Code: 31537, LiveCode: 31534})
	if d.Action != actionBuild || !strings.Contains(d.Reason, "31534") || !strings.Contains(d.Reason, "no commit") {
		t.Errorf("an unknown base is named in the reason, got %v %q", d.Action, d.Reason)
	}
	d = decideTV(tvFacts{Auto: true, Code: 31537, LiveCode: 31534, ChangeKnown: true, LiveCommits: []string{"23c6de8a5f0d"}})
	if d.Action != actionSkipUnchanged || !strings.Contains(d.Reason, "23c6de8a") {
		t.Errorf("a skip names the base commit, got %v %q", d.Action, d.Reason)
	}
}

func TestReleaseParseSignerAndBadging(t *testing.T) {
	certs := "Signer #1 certificate DN: CN=Android Debug\n" +
		"Signer #1 certificate SHA-256 digest: 7638449ed0971a8b1b634b3eff4d762b3f12aa203536dd62dba16b8495f036f7\n" +
		"Signer #1 certificate SHA-1 digest: abc\n"
	if got := parseSignerDigest(certs); got != "7638449ed0971a8b1b634b3eff4d762b3f12aa203536dd62dba16b8495f036f7" {
		t.Errorf("parseSignerDigest = %q", got)
	}
	if got := parseSignerDigest("garbage"); got != "" {
		t.Errorf("parseSignerDigest(garbage) = %q", got)
	}
	badging := "package: name='me.viktorbarzin.f1tv' versionCode='31520' versionName='2.44.2+1520' platformBuildVersionName='14'\n" +
		"application-label:'TV'\n"
	code, debuggable := parseBadging(badging)
	if code != 31520 || debuggable {
		t.Errorf("parseBadging = %d %v", code, debuggable)
	}
	_, debuggable = parseBadging(badging + "application-debuggable\n")
	if !debuggable {
		t.Errorf("parseBadging missed application-debuggable")
	}
}

func TestReleaseOutputMetadataVersionCode(t *testing.T) {
	meta := []byte(`{"version":3,"artifactType":{"type":"APK"},"elements":[{"type":"SINGLE","versionCode":31520,"versionName":"2.44.2+1520","outputFile":"app-release.apk"}]}`)
	code, file, err := parseOutputMetadata(meta)
	if err != nil || code != 31520 || file != "app-release.apk" {
		t.Errorf("parseOutputMetadata = %d %q %v", code, file, err)
	}
	if _, _, err := parseOutputMetadata([]byte(`{"elements":[]}`)); err == nil {
		t.Errorf("want an error for no elements")
	}
}

func TestReleaseParseArgs(t *testing.T) {
	o, err := parseReleaseArgs([]string{"f1-stream", "--tv", "--sha", "abc1234", "--check"})
	if err != nil || o.App != "f1-stream" || !o.TV || o.Server || o.SHA != "abc1234" || !o.Check {
		t.Errorf("parseReleaseArgs = %+v %v", o, err)
	}
	o, err = parseReleaseArgs([]string{"--server", "f1-stream"})
	if err != nil || o.App != "f1-stream" || !o.Server {
		t.Errorf("flag before app: %+v %v", o, err)
	}
	if _, err := parseReleaseArgs([]string{"f1-stream", "--bogus"}); err == nil {
		t.Errorf("want an error for an unknown flag")
	}
	if _, err := parseReleaseArgs(nil); err == nil {
		t.Errorf("want an error without an app")
	}
	if _, err := parseReleaseArgs([]string{"nope"}); err == nil {
		t.Errorf("want an error for an unknown app")
	}
}

func TestReleaseActionNamesCoverEveryAction(t *testing.T) {
	for a := actionBuild; a <= actionNotAsked; a++ {
		if a.String() == "" {
			t.Errorf("action %d has no name", a)
		}
	}
	if actionNotAsked.runs() || !actionPublishOnly.runs() {
		t.Errorf("runs() is wrong")
	}
}

func TestReleaseJudgeTVAnswersAcrossEdgePods(t *testing.T) {
	a := func(code int, sha string) tvAnswer { return tvAnswer{Code: code, SHA: sha} }
	cases := []struct {
		name    string
		answers []tvAnswer
		want    tvConfirm
		whyHas  string
	}{
		{"every pod offers the build", []tvAnswer{a(31529, "x"), a(31529, "x"), a(31529, "x")}, tvConfirmed, ""},
		// 2026-10-31: one Edge pod's NFS listing stayed on 31521 for 15+ minutes
		// while the other offered 31529; a single read could land on either.
		{"one pod is stale", []tvAnswer{a(31529, "x"), a(31521, "y"), a(31529, "x")}, tvPending, "1 of 3"},
		{"wrong bytes under the code", []tvAnswer{a(31529, "x"), a(31529, "z")}, tvPending, "sha256 z"},
		{"newer everywhere", []tvAnswer{a(31530, "n"), a(31531, "m")}, tvSuperseded, ""},
		{"newer and ours", []tvAnswer{a(31530, "n"), a(31529, "x")}, tvSuperseded, ""},
		{"no answers", nil, tvPending, "no answer"},
	}
	for _, c := range cases {
		got, why := judgeTVAnswers(c.answers, 31529, "x")
		if got != c.want || !strings.Contains(why, c.whyHas) {
			t.Errorf("%s: judgeTVAnswers = %v %q, want %v containing %q", c.name, got, why, c.want, c.whyHas)
		}
	}
}

func TestReleaseHighestTVAnswerIsTheLiveCode(t *testing.T) {
	got := highestTVAnswer([]tvAnswer{{31521, "a"}, {31529, "b"}, {31521, "a"}})
	if got.Code != 31529 || got.SHA != "b" {
		t.Errorf("highestTVAnswer = %+v", got)
	}
}
