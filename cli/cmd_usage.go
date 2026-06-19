package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
)

func usageCommands() []Command {
	return []Command{
		{Path: []string{"usage", "top"}, Tier: TierRead,
			Summary: "rank homelab verb usage across users (from Loki): usage top [--since 30d] [--user U] [--json]", Run: usageTop},
	}
}

// usageQuery builds the LogQL metric query that counts invocations per verb.
func usageQuery(since, user string) string {
	sel := `job="` + usageJob + `"`
	if user != "" {
		sel += `, user="` + user + `"`
	}
	return fmt.Sprintf(`sum by (verb) (count_over_time({%s}[%s]))`, sel, since)
}

func usageTop(args []string) error {
	since := flagValue(args, "--since")
	if since == "" {
		since = "30d"
	}
	v := url.Values{}
	v.Set("query", usageQuery(since, flagValue(args, "--user")))
	body, err := lbGetBody(lokiHost, "/loki/api/v1/query", v)
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
	type row struct {
		verb string
		n    int
	}
	var rows []row
	for _, s := range r.Data.Result {
		n := 0
		if len(s.Value) == 2 {
			if f, e := strconv.ParseFloat(fmt.Sprint(s.Value[1]), 64); e == nil {
				n = int(f)
			}
		}
		rows = append(rows, row{s.Metric["verb"], n})
	}
	if len(rows) == 0 {
		fmt.Println("(no usage recorded yet)")
		return nil
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].n > rows[j].n })
	for _, r := range rows {
		fmt.Printf("%6d  %s\n", r.n, r.verb)
	}
	return nil
}
