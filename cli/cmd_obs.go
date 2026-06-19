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
	for _, s := range r.Data.Result {
		for _, val := range s.Values {
			if len(val) == 2 {
				fmt.Println(val[1])
				n++
			}
		}
	}
	if n == 0 {
		fmt.Println("(no log lines)")
	}
	return nil
}
