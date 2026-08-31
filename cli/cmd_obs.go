package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	promHost = "prometheus-query.viktorbarzin.lan"
	lokiHost = "loki.viktorbarzin.lan"
)

func obsCommands() []Command {
	return []Command{
		{Path: []string{"metrics", "query"}, Tier: TierRead,
			Summary: `Prometheus query: metrics query "<promql>" [--at T|--since 7d|--start T --end T] [--step 5m] [--json]`, Run: metricsQuery},
		{Path: []string{"metrics", "alerts"}, Tier: TierRead,
			Summary: "list currently firing Prometheus alerts", Run: metricsAlerts},
		{Path: []string{"logs", "query"}, Tier: TierRead,
			Summary: `Loki query (last --since, default 1h): logs query "<logql>" [--since 7d|--start T --end T] [--limit N] [--json]`, Run: logsQuery},
		{Path: []string{"logs", "labels"}, Tier: TierRead,
			Summary: `what streams exist: logs labels [--values <label>] [--since 7d]`, Run: logsLabels},
	}
}

// queryArg joins non-flag args into the query (PromQL/LogQL should normally be
// passed as a single quoted argument; this also tolerates unquoted multi-token).
func queryArg(args []string, valueFlags map[string]bool) string {
	var parts []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if valueFlags[a] {
			i++
			continue
		}
		if strings.HasPrefix(a, "-") {
			continue
		}
		parts = append(parts, a)
	}
	return strings.Join(parts, " ")
}

func labelStr(m map[string]string) string {
	name := m["__name__"]
	var kv []string
	for k, v := range m {
		if k != "__name__" {
			kv = append(kv, k+"="+v)
		}
	}
	sort.Strings(kv)
	return name + "{" + strings.Join(kv, ",") + "}"
}

func metricsQuery(args []string) error {
	// The value-flag map matters: without it queryArg folds "--since 6h" into
	// the PromQL and Prometheus rejects "sum(up) 6h" as a parse error.
	q := queryArg(args, map[string]bool{"--since": true, "--at": true,
		"--start": true, "--end": true, "--step": true})
	if q == "" {
		return fmt.Errorf(`usage: homelab metrics query "<promql>" [--json]`)
	}
	// A time selection is optional here: with no flags this stays the instant
	// query it always was. The study found "has this rate changed since the
	// deploy" unaskable because there was no time flag at all.
	hasTime := flagValue(args, "--at") != "" || flagValue(args, "--since") != "" ||
		flagValue(args, "--start") != ""
	v := url.Values{}
	v.Set("query", q)
	path := "/api/v1/query"
	if hasTime {
		rng, err := resolveRange(args, time.Hour)
		if err != nil {
			return err
		}
		if rng.Instant {
			v.Set("time", strconv.FormatInt(rng.At.Unix(), 10))
		} else {
			step := rng.Step
			if step == 0 {
				// ~200 points across the window: enough shape to read, small
				// enough that a 7d range does not return 60k samples.
				step = rng.End.Sub(rng.Start) / 200
				if step < time.Second {
					step = time.Second
				}
			}
			path = "/api/v1/query_range"
			v.Set("start", strconv.FormatInt(rng.Start.Unix(), 10))
			v.Set("end", strconv.FormatInt(rng.End.Unix(), 10))
			v.Set("step", fmt.Sprintf("%ds", int(step.Seconds())))
		}
	}
	body, err := lbGetBody(promHost, path, v)
	if err != nil {
		return err
	}
	if containsArg(args, "--json") {
		fmt.Println(string(body))
		return nil
	}
	if path == "/api/v1/query_range" {
		// A range result is a matrix; rendering it as scalars would silently
		// show one point per series and read as an instant answer.
		fmt.Println("range query — pass --json for the full matrix, or --at <T> for a single moment")
		return renderMatrixSummary(body)
	}
	var r struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Value  []interface{}     `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		fmt.Println(string(body))
		return nil
	}
	if len(r.Data.Result) == 0 {
		fmt.Println("(no series)")
		return nil
	}
	for _, s := range r.Data.Result {
		val := ""
		if len(s.Value) == 2 {
			val = fmt.Sprint(s.Value[1])
		}
		fmt.Printf("%-14s %s\n", val, labelStr(s.Metric))
	}
	return nil
}

func metricsAlerts(args []string) error {
	// prometheus-query is a query-only frontend (no /api/v1/alerts); the firing
	// set is exposed as the synthetic ALERTS series, queryable the normal way.
	v := url.Values{}
	v.Set("query", `ALERTS{alertstate="firing"}`)
	body, err := lbGetBody(promHost, "/api/v1/query", v)
	if err != nil {
		return err
	}
	if containsArg(args, "--json") {
		fmt.Println(string(body))
		return nil
	}
	var r struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		fmt.Println(string(body))
		return nil
	}
	if len(r.Data.Result) == 0 {
		fmt.Println("(no firing alerts)")
		return nil
	}
	for _, a := range r.Data.Result {
		m := a.Metric
		scope := ""
		for _, k := range []string{"namespace", "deployment", "instance", "job", "node"} {
			if v := m[k]; v != "" {
				scope = k + "=" + v
				break
			}
		}
		fmt.Printf("%-9s %-34s %s\n", m["severity"], m["alertname"], scope)
	}
	return nil
}

// truncationNote warns when --limit, not --since, decided how far back the
// results reach.
//
// Loki returns the most RECENT n lines for a log query, so a limit that is
// reached silently narrows the window: `--since 96h --limit 100` against a
// chatty stream can come back covering two minutes, and reads exactly like
// "nothing happened earlier". That is a confidently wrong answer, which is
// worse than an error — it sends the reader to the wrong conclusion.
//
// Returns "" when the limit was not reached, so the warning stays meaningful.
func truncationNote(limit, n int, minNs, maxNs int64, since time.Duration) string {
	if n == 0 || limit <= 0 || n < limit || minNs == 0 || maxNs == 0 {
		return ""
	}
	covered := time.Duration(maxNs-minNs) * time.Nanosecond
	return fmt.Sprintf(
		"note: --limit %d was reached, so these lines cover only %s of the %s requested "+
			"(oldest %s). Older lines were NOT returned. Raise --limit, narrow the stream "+
			"selector, or add line filters (!= \"/health\") to reach further back.",
		limit, covered.Round(time.Second), since,
		time.Unix(0, minNs).Format("15:04:05"))
}

func logsQuery(args []string) error {
	q := queryArg(args, map[string]bool{"--since": true, "--limit": true,
		"--start": true, "--end": true, "--at": true, "--step": true})
	if q == "" {
		return fmt.Errorf(`usage: homelab logs query "<logql>" [--since 7d|--start T --end T] [--limit N] [--json]`)
	}
	rng, err := resolveRange(args, time.Hour)
	if err != nil {
		return err
	}
	if rng.Instant {
		return fmt.Errorf("--at selects a single moment, which log lines do not have; use --since or --start/--end")
	}
	limit := flagValue(args, "--limit")
	if limit == "" {
		limit = "100"
	}
	lim, err := strconv.Atoi(limit)
	if err != nil {
		return fmt.Errorf("bad --limit %q: %w", limit, err)
	}
	v := url.Values{}
	v.Set("query", q)
	v.Set("limit", limit)
	v.Set("start", strconv.FormatInt(rng.Start.UnixNano(), 10))
	v.Set("end", strconv.FormatInt(rng.End.UnixNano(), 10))
	body, err := lbGetBody(lokiHost, "/loki/api/v1/query_range", v)
	if err != nil {
		return err
	}
	if containsArg(args, "--json") {
		fmt.Println(string(body))
		return nil
	}
	var r struct {
		Data struct {
			Result []struct {
				Values [][]string `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		fmt.Println(string(body))
		return nil
	}
	n := 0
	var minNs, maxNs int64
	for _, s := range r.Data.Result {
		for _, val := range s.Values {
			if len(val) == 2 {
				fmt.Println(val[1])
				n++
				if ts, err := strconv.ParseInt(val[0], 10, 64); err == nil {
					if minNs == 0 || ts < minNs {
						minNs = ts
					}
					if ts > maxNs {
						maxNs = ts
					}
				}
			}
		}
	}
	if n == 0 {
		// To stderr with the rest of the guidance, so a piped result set stays
		// machine-readable.
		fmt.Fprint(os.Stderr, zeroResultHint(q))
	}
	// To stderr, so it cannot corrupt a piped or redirected result set.
	if note := truncationNote(lim, n, minNs, maxNs, rng.End.Sub(rng.Start)); note != "" {
		fmt.Fprintln(os.Stderr, note)
	}
	return nil
}
