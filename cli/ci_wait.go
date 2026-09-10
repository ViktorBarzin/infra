package main

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// How long a pipeline is allowed to take to APPEAR before we conclude this repo
// does not build the landed commit through Woodpecker at all.
const defaultCIAppearGrace = 10 * time.Minute

// errNoCIPipeline means no pipeline was ever created for the commit, which is
// not the same as a build failing. Repos that build off-infra legitimately
// never get one: tripit builds on GitHub Actions and only DEPLOYS through
// Woodpecker, on `event: manual` carrying the deployed image tag rather than
// the landed commit. `work land` reports this as a note, because the code is on
// master either way and there is no red build to act on.
var errNoCIPipeline = errors.New("no Woodpecker pipeline was created for this commit")

type ciWaitDecision int

const (
	ciKeepWaiting ciWaitDecision = iota
	ciGiveUpNoPipeline
	ciGiveUpTimeout
)

func (d ciWaitDecision) String() string {
	switch d {
	case ciKeepWaiting:
		return "keep-waiting"
	case ciGiveUpNoPipeline:
		return "give-up-no-pipeline"
	case ciGiveUpTimeout:
		return "give-up-timeout"
	}
	return "unknown"
}

// ciWaitPolicy splits the two waits that a single fixed timeout used to
// conflate. A build takes as long as it takes and is none of our business to
// cut short (runTimeout 0), but waiting on a pipeline that will never exist
// would wedge the caller forever, so first sighting stays bounded.
type ciWaitPolicy struct {
	appearGrace time.Duration
	runTimeout  time.Duration // 0 = wait as long as it takes
}

func defaultCIWaitPolicy() ciWaitPolicy {
	return ciWaitPolicy{appearGrace: defaultCIAppearGrace, runTimeout: 0}
}

func (p ciWaitPolicy) decide(seen bool, waited time.Duration) ciWaitDecision {
	if !seen {
		if waited >= p.appearGrace {
			return ciGiveUpNoPipeline
		}
		return ciKeepWaiting
	}
	if p.runTimeout > 0 && waited >= p.runTimeout {
		return ciGiveUpTimeout
	}
	return ciKeepWaiting
}

// parseCIWaitFlags reads --timeout and --appear-grace in both the spaced and
// the `=` form. An unparseable duration is an error rather than a silent
// fallback: a typo that quietly restores a timeout is the bug this replaces.
func parseCIWaitFlags(args []string) (ciWaitPolicy, error) {
	p := defaultCIWaitPolicy()
	// Returns the flag's value and the index to resume from, so the `--flag val`
	// form consumes its value and the `--flag=val` form does not.
	read := func(name string, i int) (string, int, error) {
		if v, ok := strings.CutPrefix(args[i], name+"="); ok {
			return v, i, nil
		}
		if i+1 >= len(args) {
			return "", i, fmt.Errorf("%s needs a duration (e.g. %s 45m)", name, name)
		}
		return args[i+1], i + 1, nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		var target *time.Duration
		switch {
		case a == "--timeout" || strings.HasPrefix(a, "--timeout="):
			target = &p.runTimeout
			a = "--timeout"
		case a == "--appear-grace" || strings.HasPrefix(a, "--appear-grace="):
			target = &p.appearGrace
			a = "--appear-grace"
		default:
			continue
		}
		raw, next, err := read(a, i)
		if err != nil {
			return p, err
		}
		i = next
		d, err := time.ParseDuration(raw)
		if err != nil {
			return p, fmt.Errorf("bad duration %q for %s: %w", raw, a, err)
		}
		*target = d
	}
	return p, nil
}

// landCIOutcome turns a ciWatch result into what `work land` should report. The
// branch is already on master by this point, so the only question is whether
// there is a red build to act on. A pipeline that never existed is not one.
func landCIOutcome(err error) (note string, fatal error) {
	if err == nil {
		return "", nil
	}
	if errors.Is(err, errNoCIPipeline) {
		return fmt.Sprintf("homelab: landed. %s — nothing to watch here, check the repo's own build if it has one.", err), nil
	}
	return "", fmt.Errorf("landed, but CI did not go green: %w", err)
}
