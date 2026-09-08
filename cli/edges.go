package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// edgesOpts is the parsed filter set for `homelab edges` (the who-talks-to-whom
// investigation helper over the goldmane_edges trail; see ADR-0014).
type edgesOpts struct {
	ns       string // edges touching this namespace (either direction)
	src      string // edges where src_ns = this
	dst      string // edges where dst_ns = this
	peersOf  string // distinct peers of this namespace (both directions)
	newSince string // first_seen >= duration (24h/7d/30m) or date (YYYY-MM-DD)
	denied   bool   // action = 'deny' only
	asJSON   bool   // wrap result as a JSON array
	limit    int    // row cap (default 200)
}

// parseEdgesArgs parses the edges flag surface. Unknown flags error out so a
// typo surfaces instead of silently dumping the whole table.
func parseEdgesArgs(args []string) (edgesOpts, error) {
	o := edgesOpts{limit: 200}
	i := 0
	for i < len(args) {
		a := args[i]
		key, inline, hasInline := a, "", false
		if eq := strings.IndexByte(a, '='); eq >= 0 {
			key, inline, hasInline = a[:eq], a[eq+1:], true
		}
		needVal := func() (string, error) {
			if hasInline {
				return inline, nil
			}
			if i+1 < len(args) {
				i++
				return args[i], nil
			}
			return "", fmt.Errorf("flag %s needs a value", key)
		}
		var err error
		switch key {
		case "--ns":
			o.ns, err = needVal()
		case "--src":
			o.src, err = needVal()
		case "--dst":
			o.dst, err = needVal()
		case "--peers-of":
			o.peersOf, err = needVal()
		case "--new-since":
			o.newSince, err = needVal()
		case "--denied":
			o.denied = true
		case "--json":
			o.asJSON = true
		case "--limit":
			var v string
			if v, err = needVal(); err == nil {
				if o.limit, err = strconv.Atoi(v); err != nil {
					err = fmt.Errorf("--limit must be an integer: %q", v)
				}
			}
		default:
			return o, fmt.Errorf("unknown flag: %s", a)
		}
		if err != nil {
			return o, err
		}
		i++
	}
	return o, nil
}

// nsRE is the safe namespace-token charset (k8s names + "Global"). Used as the
// injection guard — anything else is rejected rather than quoted-and-hoped.
var nsRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

func validateNS(s string) error {
	if s == "" || len(s) > 63 || !nsRE.MatchString(s) {
		return fmt.Errorf("invalid namespace name: %q", s)
	}
	return nil
}

// sqlStr renders a SQL string literal (belt-and-suspenders on top of validateNS).
func sqlStr(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

var (
	durRE  = regexp.MustCompile(`^(\d+)([smhd])$`)
	dateRE = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$`)
)

// newSinceCond turns a duration (24h/7d/30m/90s) or a date (YYYY-MM-DD[ HH:MM])
// into a first_seen predicate.
func newSinceCond(v string) (string, error) {
	if m := durRE.FindStringSubmatch(v); m != nil {
		unit := map[string]string{"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}[m[2]]
		return fmt.Sprintf("first_seen >= now() - interval '%s %s'", m[1], unit), nil
	}
	if dateRE.MatchString(v) {
		return "first_seen >= " + sqlStr(v), nil
	}
	return "", fmt.Errorf("--new-since must be a duration (e.g. 24h, 7d, 30m) or a date (YYYY-MM-DD): %q", v)
}

// buildEdgesQuery renders the SQL for the given filters against the `edge` table.
func buildEdgesQuery(o edgesOpts) (string, error) {
	limit := o.limit
	if limit <= 0 {
		limit = 200
	}

	// peers-of is a distinct-peer summary, a different shape from the row list.
	if o.peersOf != "" {
		if err := validateNS(o.peersOf); err != nil {
			return "", err
		}
		p := sqlStr(o.peersOf)
		return fmt.Sprintf("SELECT DISTINCT peer, action FROM ("+
			"SELECT dst_ns AS peer, action FROM edge WHERE src_ns = %s "+
			"UNION SELECT src_ns AS peer, action FROM edge WHERE dst_ns = %s"+
			") t ORDER BY peer LIMIT %d", p, p, limit), nil
	}

	var conds []string
	for _, f := range []struct{ val, tmpl string }{
		{o.ns, "(src_ns = %[1]s OR dst_ns = %[1]s)"},
		{o.src, "src_ns = %s"},
		{o.dst, "dst_ns = %s"},
	} {
		if f.val == "" {
			continue
		}
		if err := validateNS(f.val); err != nil {
			return "", err
		}
		conds = append(conds, fmt.Sprintf(f.tmpl, sqlStr(f.val)))
	}
	if o.denied {
		conds = append(conds, "action = 'deny'")
	}
	if o.newSince != "" {
		c, err := newSinceCond(o.newSince)
		if err != nil {
			return "", err
		}
		conds = append(conds, c)
	}

	q := "SELECT src_ns, dst_ns, action, flow_count, first_seen, last_seen FROM edge"
	if len(conds) > 0 {
		q += " WHERE " + strings.Join(conds, " AND ")
	}
	q += fmt.Sprintf(" ORDER BY first_seen DESC LIMIT %d", limit)

	if o.asJSON {
		q = "SELECT coalesce(json_agg(row_to_json(t)), '[]') FROM (" + q + ") t"
	}
	return q, nil
}
