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
			Summary: `Prometheus instant query: metrics query "<promql>" [--json]`, Run: metricsQuery},
		{Path: []string{"metrics", "alerts"}, Tier: TierRead,
			Summary: "list currently firing Prometheus alerts", Run: metricsAlerts},
		{Path: []string{"logs", "query"}, Tier: TierRead,
			Summary: `Loki query (last --since, default 1h): logs query "<logql>" [--since 1h] [--limit N] [--json]`, Run: logsQuery},
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
	q := queryArg(args, nil)
	if q == "" {
		return fmt.Errorf(`usage: homelab metrics query "<promql>" [--json]`)
	}
	v := url.Values{}
	v.Set("query", q)
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
	q := queryArg(args, map[string]bool{"--since": true, "--limit": true})
	if q == "" {
		return fmt.Errorf(`usage: homelab logs query "<logql>" [--since 1h] [--limit N] [--json]`)
	}
	since := flagValue(args, "--since")
	if since == "" {
		since = "1h"
	}
	dur, err := time.ParseDuration(since)
	if err != nil {
		return fmt.Errorf("bad --since %q: %w", since, err)
	}
	limit := flagValue(args, "--limit")
	if limit == "" {
		limit = "100"
	}
	lim, err := strconv.Atoi(limit)
	if err != nil {
		return fmt.Errorf("bad --limit %q: %w", limit, err)
	}
	end := time.Now()
	v := url.Values{}
	v.Set("query", q)
	v.Set("limit", limit)
	v.Set("start", strconv.FormatInt(end.Add(-dur).UnixNano(), 10))
	v.Set("end", strconv.FormatInt(end.UnixNano(), 10))
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
		fmt.Println("(no log lines)")
	}
	// To stderr, so it cannot corrupt a piped or redirected result set.
	if note := truncationNote(lim, n, minNs, maxNs, dur); note != "" {
		fmt.Fprintln(os.Stderr, note)
	}
	return nil
}
