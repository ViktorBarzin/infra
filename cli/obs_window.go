package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Time-window handling shared by `logs query` and `metrics query`.
//
// Why this exists. The 2026-08-31 session study counted 30 attempts across 17
// sessions where the question could not be expressed in these verbs, so the
// endpoint got reverse-engineered and answered with curl. That partly undid the
// 2026-08-15 rule fix, which successfully sent Claude to the verb only for the
// verb to be unable to answer. Three gaps, each measured:
//
//   - `--since 7d` was typed 19 times and rejected every time, because
//     time.ParseDuration has no unit above `h`. 40 such failures, 24 of them
//     after the rule fix landed.
//   - `metrics query` had no time flag at all, so "has this rate changed since
//     the deploy" — the commonest shape — was unaskable.
//   - there was no label-value lookup, which is exactly what you need after a
//     zero-result query.

// parseWindow accepts everything time.ParseDuration does, plus `d` (days) and
// `w` (weeks), which are the units people actually type against 30-day Loki and
// 26-week Prometheus retention.
func parseWindow(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	bad := fmt.Errorf("bad window %q: use a number plus s/m/h/d/w (e.g. 30m, 24h, 7d, 2w)", s)
	if s == "" {
		return 0, bad
	}
	// Expand a trailing d/w into hours before handing to ParseDuration, so
	// compound forms ("1h30m") keep working untouched.
	if n := len(s); n >= 2 {
		unit := s[n-1]
		if unit == 'd' || unit == 'w' {
			num, err := strconv.ParseFloat(s[:n-1], 64)
			if err != nil || num < 0 {
				return 0, bad
			}
			hours := num * 24
			if unit == 'w' {
				hours *= 7
			}
			return time.Duration(hours * float64(time.Hour)), nil
		}
	}
	d, err := time.ParseDuration(s)
	if err != nil || d < 0 {
		return 0, bad
	}
	return d, nil
}

// parseInstant accepts RFC3339, `@<epoch seconds>`, or a negative relative
// window (`-2h`, `-3d`) meaning "that long ago". The relative form is the shape
// actually typed mid-investigation.
func parseInstant(s string) (time.Time, error) {
	s = strings.TrimSpace(s)
	bad := fmt.Errorf("bad timestamp %q: use RFC3339 (2026-08-15T22:54:54Z), @<epoch>, or a relative window like -2h", s)
	if s == "" {
		return time.Time{}, bad
	}
	if strings.HasPrefix(s, "@") {
		sec, err := strconv.ParseInt(s[1:], 10, 64)
		if err != nil {
			return time.Time{}, bad
		}
		return time.Unix(sec, 0), nil
	}
	if strings.HasPrefix(s, "-") {
		d, err := parseWindow(s[1:])
		if err != nil {
			return time.Time{}, bad
		}
		return time.Now().Add(-d), nil
	}
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, bad
}

// queryRange is the resolved time selection for one query.
type queryRange struct {
	Start   time.Time
	End     time.Time
	Step    time.Duration
	At      time.Time // set when Instant
	Instant bool
}

// resolveRange turns the time flags into one selection, or errors. Contradictory
// flags are rejected rather than silently resolved: picking a winner quietly is
// how a confidently wrong answer gets reported.
func resolveRange(args []string, defaultWindow time.Duration) (queryRange, error) {
	var r queryRange
	since := flagValue(args, "--since")
	at := flagValue(args, "--at")
	start := flagValue(args, "--start")
	end := flagValue(args, "--end")
	step := flagValue(args, "--step")

	set := 0
	if since != "" {
		set++
	}
	if at != "" {
		set++
	}
	if start != "" {
		set++
	}
	if set > 1 {
		return r, fmt.Errorf("--since, --at and --start select the window three different ways; pass one")
	}
	if end != "" && start == "" {
		return r, fmt.Errorf("--end needs --start (use --since for \"the last N\")")
	}

	if step != "" {
		d, err := parseWindow(step)
		if err != nil {
			return r, fmt.Errorf("--step: %w", err)
		}
		r.Step = d
	}

	switch {
	case at != "":
		t, err := parseInstant(at)
		if err != nil {
			return r, fmt.Errorf("--at: %w", err)
		}
		r.At, r.Instant = t, true
		return r, nil
	case start != "":
		s, err := parseInstant(start)
		if err != nil {
			return r, fmt.Errorf("--start: %w", err)
		}
		e := time.Now()
		if end != "" {
			if e, err = parseInstant(end); err != nil {
				return r, fmt.Errorf("--end: %w", err)
			}
		}
		if !s.Before(e) {
			return r, fmt.Errorf("--start (%s) is not before --end (%s)",
				s.UTC().Format(time.RFC3339), e.UTC().Format(time.RFC3339))
		}
		r.Start, r.End = s, e
		return r, nil
	default:
		w := defaultWindow
		if since != "" {
			d, err := parseWindow(since)
			if err != nil {
				return r, fmt.Errorf("--since: %w", err)
			}
			w = d
		}
		r.End = time.Now()
		r.Start = r.End.Add(-w)
		return r, nil
	}
}

// zeroResultHint says what to do next when a query matched nothing. It states
// that THIS QUERY found nothing, never that the thing did not happen — the two
// are different, and conflating them is how a wrong negative gets reported as a
// finding.
func zeroResultHint(query string) string {
	var b strings.Builder
	b.WriteString("0 lines matched. That is not the same as \"it did not happen\".\n")
	b.WriteString("Next, in order of what usually turns out to be wrong:\n")
	b.WriteString("  1. the stream is named something else — list what exists:\n")
	b.WriteString("       homelab logs labels                 (label names)\n")
	b.WriteString("       homelab logs labels --values job    (values for one label)\n")
	b.WriteString("  2. the window is too short — widen it: --since 7d (d and w are accepted)\n")
	b.WriteString("  3. the line filter is too exact — drop the |= and look at raw lines first\n")
	if isWideSelector(query) {
		b.WriteString("\nNote: that selector is very wide. A wide selector over a long window\n")
		b.WriteString("fills --limit with whatever is most recent and can look empty for the\n")
		b.WriteString("thing you are actually after. Narrow the stream, then filter.\n")
	}
	return b.String()
}

// isWideSelector spots a stream selector that matches essentially everything.
func isWideSelector(q string) bool {
	for _, pat := range []string{`=~".+"`, `=~".*"`, `=~"..*"`, `!=""`} {
		if strings.Contains(strings.ReplaceAll(q, " ", ""), pat) {
			return true
		}
	}
	return false
}

// renderMatrixSummary prints one line per series from a Prometheus range result:
// first value, last value, and the direction between them. That is the shape of
// the question people ask a range query ("has this changed since the deploy"),
// and printing every sample would bury it.
func renderMatrixSummary(body []byte) error {
	var r struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Values [][]interface{}   `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return fmt.Errorf("cannot read range result: %w", err)
	}
	if len(r.Data.Result) == 0 {
		fmt.Println("(no series matched)")
		return nil
	}
	for _, s := range r.Data.Result {
		if len(s.Values) == 0 {
			continue
		}
		first := sampleValue(s.Values[0])
		last := sampleValue(s.Values[len(s.Values)-1])
		arrow := "->"
		if fv, lv, ok := twoFloats(first, last); ok {
			switch {
			case lv > fv:
				arrow = "UP to"
			case lv < fv:
				arrow = "DOWN to"
			default:
				arrow = "flat at"
			}
		}
		fmt.Printf("  %-50s %s %s %s  (%d samples)\n",
			labelStr(s.Metric), first, arrow, last, len(s.Values))
	}
	return nil
}

func sampleValue(pair []interface{}) string {
	if len(pair) < 2 {
		return "?"
	}
	if s, ok := pair[1].(string); ok {
		return s
	}
	return fmt.Sprint(pair[1])
}

func twoFloats(a, b string) (float64, float64, bool) {
	af, err1 := strconv.ParseFloat(a, 64)
	bf, err2 := strconv.ParseFloat(b, 64)
	return af, bf, err1 == nil && err2 == nil
}

// logsLabels answers "what is the stream actually called", which is the question
// every zero-result query raises. Without it, finding out meant reading the Loki
// endpoint by hand.
func logsLabels(args []string) error {
	rng, err := resolveRange(args, 24*time.Hour)
	if err != nil {
		return err
	}
	v := url.Values{}
	v.Set("start", strconv.FormatInt(rng.Start.UnixNano(), 10))
	v.Set("end", strconv.FormatInt(rng.End.UnixNano(), 10))

	path := "/loki/api/v1/labels"
	if label := flagValue(args, "--values"); label != "" {
		path = "/loki/api/v1/label/" + label + "/values"
	}
	body, err := lbGetBody(lokiHost, path, v)
	if err != nil {
		return err
	}
	if containsArg(args, "--json") {
		fmt.Println(string(body))
		return nil
	}
	var r struct {
		Data []string `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return fmt.Errorf("cannot read labels: %w", err)
	}
	if len(r.Data) == 0 {
		fmt.Println("(nothing in this window — try --since 7d)")
		return nil
	}
	sort.Strings(r.Data)
	for _, d := range r.Data {
		fmt.Println("  " + d)
	}
	if flagValue(args, "--values") == "" {
		fmt.Println("\nvalues for one of them: homelab logs labels --values <label>")
	}
	return nil
}
