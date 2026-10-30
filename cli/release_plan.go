package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// releaseSpec describes one app `homelab deploy <app>` can build and put live
// from the devvm, doing by hand what the app's GitHub Actions workflows do.
// Only f1-stream exists today; the fields say what a second app would need.
type releaseSpec struct {
	App            string
	GitURL         string
	LocalClone     string // under $HOME; used only to speed up the clone
	Image          string // server image, tagged :<sha8> (and :latest at master's tip)
	TVRepo         string // TV app artifact, tagged :<versionCode>
	WoodpeckerRepo int    // the GitHub mirror's Woodpecker repo the deploys run on
	Site           string // public base URL answering /api/version and /api/app/latest
	Namespace      string
	EdgeDeployment string // the Deployment whose image says the rollout reached viewers
	VaultPath      string // ghcr_username, ghcr_token, woodpecker_token
	Signer         string // SHA-256 of the key every television accepts updates from
	VersionFloor   int
	// GitHub's own path filters, copied from .github/workflows/build.yml
	// (paths-ignore) and android.yml (paths). The image is chosen by
	// EXCLUSION, so a directory nobody listed still deploys.
	ServerIgnore []string
	TVPaths      []string
}

func f1StreamRelease() releaseSpec {
	return releaseSpec{
		App:            "f1-stream",
		GitURL:         "https://forgejo.viktorbarzin.me/viktor/f1-stream.git",
		LocalClone:     "code/f1-stream",
		Image:          "ghcr.io/viktorbarzin/f1-stream",
		TVRepo:         "ghcr.io/viktorbarzin/f1-stream-tv",
		WoodpeckerRepo: 10,
		Site:           "https://tv.viktorbarzin.me",
		Namespace:      "f1-stream",
		EdgeDeployment: "f1-stream-edge",
		VaultPath:      "secret/ci/f1-stream-release",
		Signer:         "7638449ed0971a8b1b634b3eff4d762b3f12aa203536dd62dba16b8495f036f7",
		VersionFloor:   30000,
		ServerIgnore: []string{"docs/**", "**.md", "android/**", ".woodpecker/publish-tv.yml",
			".github/workflows/android.yml", "tracker/**", ".github/workflows/tracker.yml"},
		TVPaths: []string{"android/**", ".woodpecker/publish-tv.yml", ".github/workflows/android.yml",
			"scripts/ci-version.sh"},
	}
}

var releaseSpecs = map[string]func() releaseSpec{"f1-stream": f1StreamRelease}

// matchWorkflowPath implements the three pattern shapes the workflows use:
// "dir/**", "**.ext" and an exact path.
func matchWorkflowPath(pattern, path string) bool {
	switch {
	case strings.HasPrefix(pattern, "**"):
		return strings.HasSuffix(path, strings.TrimPrefix(pattern, "**"))
	case strings.HasSuffix(pattern, "/**"):
		return strings.HasPrefix(path, strings.TrimSuffix(pattern, "**"))
	default:
		return path == pattern
	}
}

func matchesAny(patterns []string, path string) bool {
	for _, p := range patterns {
		if matchWorkflowPath(p, path) {
			return true
		}
	}
	return false
}

// classify says which halves a set of changed paths needs, the way GitHub's
// path filters on build.yml and android.yml decide which workflows run.
func (s releaseSpec) classify(paths []string) (server, tv bool) {
	for _, p := range paths {
		if !matchesAny(s.ServerIgnore, p) {
			server = true
		}
		if matchesAny(s.TVPaths, p) && !strings.HasSuffix(p, ".md") {
			tv = true
		}
	}
	return server, tv
}

// releaseVersion is what scripts/ci-version.sh computes for a commit.
type releaseVersion struct {
	Code  int    // TV versionCode, and APP_BUILD in the image
	Name  string // TV versionName
	Image string // APP_VERSION in the image
}

// releaseVersionFor mirrors scripts/ci-version.sh: the code is floor + the
// commit count (a count of 0 reads as 1), the name is the last tag without
// its v plus "+count". svu answers the last tag here because no subject in
// the repo is a conventional commit (measured 2026-09-13).
func releaseVersionFor(floor, count int, lastTag string) releaseVersion {
	if count <= 0 {
		count = 1
	}
	ver := strings.TrimPrefix(strings.TrimSpace(lastTag), "v")
	if ver == "" {
		ver = "0.0.0"
	}
	return releaseVersion{Code: floor + count, Name: fmt.Sprintf("%s+%d", ver, count), Image: ver}
}

type releaseAction int

const (
	actionBuild releaseAction = iota
	actionPublishOnly
	actionSkipLive
	actionSkipUnchanged
	actionSkipNewer
	actionRefuse
	actionNotAsked
)

func (a releaseAction) String() string {
	return [...]string{"build and publish", "publish the existing build", "already live",
		"nothing changed", "live is newer", "refused", "not asked for"}[a]
}

func (a releaseAction) runs() bool { return a == actionBuild || a == actionPublishOnly }

type releaseDecision struct {
	Action releaseAction
	Reason string
}

// liveRelation places the live commit relative to the commit being released.
type liveRelation int

const (
	liveUnknown liveRelation = iota // not answered, or not in master's history
	liveSame
	liveOlder // live is an ancestor of the target
	liveNewer // the target is an ancestor of live
)

type serverFacts struct {
	Auto       bool // neither --server nor --tv: decide from the changed paths
	Live       liveRelation
	LiveCommit string
	Changed    bool // a server path changed between live and the target
	OnRegistry bool // ghcr already has :<sha8>
}

func decideServer(f serverFacts) releaseDecision {
	switch f.Live {
	case liveSame:
		return releaseDecision{actionSkipLive, "the site already runs " + f.LiveCommit}
	case liveNewer:
		if f.Auto {
			return releaseDecision{actionSkipNewer, "the site runs " + f.LiveCommit + ", which is newer"}
		}
		return releaseDecision{actionRefuse, "the site runs " + f.LiveCommit + ", which already contains this commit; deploying it would roll back"}
	case liveOlder:
		if f.Auto && !f.Changed {
			return releaseDecision{actionSkipUnchanged, "nothing that goes into the image changed since " + f.LiveCommit}
		}
	}
	if f.OnRegistry {
		return releaseDecision{actionPublishOnly, "the image is already on ghcr; deploying it"}
	}
	return releaseDecision{actionBuild, "building the image"}
}

type tvFacts struct {
	Auto        bool
	Code        int
	LiveCode    int
	LiveUnknown bool // /api/app/latest did not answer
	Changed     bool // an app path changed since the live code's commit
	ChangeKnown bool // the live code's commit was found on master
	OnRegistry  bool // ghcr already has :<code>
}

func decideTV(f tvFacts) releaseDecision {
	if f.LiveUnknown {
		return releaseDecision{actionRefuse, "the site did not say which versionCode televisions are offered, so a new code cannot be checked against it"}
	}
	switch {
	case f.Code == f.LiveCode:
		return releaseDecision{actionSkipLive, fmt.Sprintf("televisions are already offered %d", f.LiveCode)}
	case f.Code < f.LiveCode:
		if f.Auto {
			return releaseDecision{actionSkipNewer, fmt.Sprintf("televisions are offered %d, newer than %d", f.LiveCode, f.Code)}
		}
		return releaseDecision{actionRefuse, fmt.Sprintf("televisions are offered %d; versionCode %d is not above it, and a television never takes a lower code", f.LiveCode, f.Code)}
	}
	if f.Auto && f.ChangeKnown && !f.Changed {
		return releaseDecision{actionSkipUnchanged, fmt.Sprintf("nothing in the app changed since %d", f.LiveCode)}
	}
	if f.OnRegistry {
		return releaseDecision{actionPublishOnly, fmt.Sprintf("versionCode %d is already on ghcr; publishing it", f.Code)}
	}
	return releaseDecision{actionBuild, fmt.Sprintf("building versionCode %d", f.Code)}
}

// commitWithCount walks master's first-parent chain (newest first) for the
// tip whose commit count is want. Tips' counts strictly fall along the chain,
// so the walk stops as soon as it passes want.
func commitWithCount(chain []string, count func(string) (int, error), want int) (string, bool) {
	for _, sha := range chain {
		n, err := count(sha)
		if err != nil {
			return "", false
		}
		if n == want {
			return sha, true
		}
		if n < want {
			return "", false
		}
	}
	return "", false
}

// parseSignerDigest reads the first "certificate SHA-256 digest" apksigner prints.
func parseSignerDigest(out string) string {
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "certificate SHA-256 digest:") {
			f := strings.Fields(line)
			return f[len(f)-1]
		}
	}
	return ""
}

// parseBadging reads versionCode and whether the APK is debuggable from
// `aapt dump badging`.
func parseBadging(out string) (code int, debuggable bool) {
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "package:") {
			if i := strings.Index(line, "versionCode='"); i >= 0 {
				rest := line[i+len("versionCode='"):]
				if j := strings.Index(rest, "'"); j >= 0 {
					code, _ = strconv.Atoi(rest[:j])
				}
			}
		}
		if strings.TrimSpace(line) == "application-debuggable" {
			debuggable = true
		}
	}
	return code, debuggable
}

// parseOutputMetadata reads the versionCode and APK file name Gradle wrote
// to output-metadata.json, the file the publish pipeline also reads.
func parseOutputMetadata(b []byte) (int, string, error) {
	var m struct {
		Elements []struct {
			VersionCode int    `json:"versionCode"`
			OutputFile  string `json:"outputFile"`
		} `json:"elements"`
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return 0, "", err
	}
	if len(m.Elements) == 0 {
		return 0, "", fmt.Errorf("output-metadata.json lists no APK")
	}
	return m.Elements[0].VersionCode, m.Elements[0].OutputFile, nil
}

type releaseOpts struct {
	App    string
	Server bool
	TV     bool
	SHA    string
	Check  bool
}

func (o releaseOpts) auto() bool { return !o.Server && !o.TV }

const releaseUsage = "usage: homelab deploy <app> [--server] [--tv] [--sha SHA] [--check]   (apps: f1-stream)"

func parseReleaseArgs(args []string) (releaseOpts, error) {
	var o releaseOpts
	var rest []string
	// The app may come before or after the flags.
	for i := 0; i < len(args); i++ {
		a := args[i]
		if (a == "--sha" || a == "-sha") && i+1 < len(args) {
			rest = append(rest, a, args[i+1])
			i++
			continue
		}
		if !strings.HasPrefix(a, "-") && o.App == "" {
			o.App = a
			continue
		}
		rest = append(rest, a)
	}
	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.BoolVar(&o.Server, "server", false, "")
	fs.BoolVar(&o.TV, "tv", false, "")
	fs.StringVar(&o.SHA, "sha", "", "")
	fs.BoolVar(&o.Check, "check", false, "")
	if err := fs.Parse(rest); err != nil {
		return o, fmt.Errorf("%v\n%s", err, releaseUsage)
	}
	if fs.NArg() > 0 {
		return o, fmt.Errorf("unexpected %q\n%s", fs.Arg(0), releaseUsage)
	}
	if o.App == "" {
		return o, fmt.Errorf("%s", releaseUsage)
	}
	if _, ok := releaseSpecs[o.App]; !ok {
		return o, fmt.Errorf("no release recipe for %q\n%s", o.App, releaseUsage)
	}
	return o, nil
}
