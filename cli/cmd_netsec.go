package main

// `homelab netsec`: what the network IDS records, in the netsec database on
// the claude-sessions ClickHouse (docs/plans/2026-11-10-network-ids.md,
// docs/architecture/network-security-monitoring.md).
//
//	sql      Viktor only: run a read-only query
//	schema   Viktor only: tables, columns and example queries

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// The reader file is root:sudo 0640 (playbooks/devvm.yml), and only Viktor is
// in sudo, so the data stays his: it shows what every device on the network
// looks up and connects to.
const netsecEnvDir = "/etc/netsec"

func netsecCommands() []Command {
	return []Command{
		{Path: []string{"netsec", "sql"}, Tier: TierRead,
			Summary: "query the network IDS store (Viktor only): netsec sql \"<SELECT ...>\" [--format TSVWithNames|JSONEachRow|...]  (\"-\" reads the query from stdin)",
			Run:     netsecSQL},
		{Path: []string{"netsec", "schema"}, Tier: TierRead,
			Summary: "tables, columns and example queries for the network IDS store (Viktor only)",
			Run:     netsecSchema},
	}
}

// netsecConnFrom builds the reader connection: NETSEC_URL / _USER / _PASSWORD
// from the environment first, then <dir>/reader.env. The URL defaults to the
// claude-sessions ClickHouse, which hosts the netsec database.
func netsecConnFrom(dir string) (dbConn, error) {
	c := dbConn{URL: os.Getenv("NETSEC_URL"), User: os.Getenv("NETSEC_USER"), Password: os.Getenv("NETSEC_PASSWORD")}
	if c.User == "" || c.Password == "" {
		path := filepath.Join(dir, "reader.env")
		b, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrPermission) {
			return c, fmt.Errorf("%s is readable by Viktor only, so the netsec store is his alone", path)
		}
		if err != nil {
			return c, fmt.Errorf("no credentials for the netsec store: %w", err)
		}
		env := parseEnvFile(string(b))
		c.User, c.Password = env["NETSEC_USER"], env["NETSEC_PASSWORD"]
		if c.URL == "" {
			c.URL = env["NETSEC_URL"]
		}
	}
	if c.URL == "" {
		c.URL = claudeSessionsURL
	}
	if c.User == "" || c.Password == "" {
		return c, fmt.Errorf("netsec store credentials are incomplete (need NETSEC_USER and NETSEC_PASSWORD)")
	}
	return c, nil
}

func parseNetsecSQLArgs(args []string) (format, query string, err error) {
	format = "PrettyCompactMonoBlock"
	var parts []string
	for i := 0; i < len(args); i++ {
		if args[i] == "--format" {
			if i+1 >= len(args) {
				return "", "", fmt.Errorf("--format needs a ClickHouse output format, e.g. TSVWithNames")
			}
			i++
			format = args[i]
			continue
		}
		parts = append(parts, args[i])
	}
	query = strings.TrimSpace(strings.Join(parts, " "))
	if query == "" {
		return "", "", fmt.Errorf("usage: homelab netsec sql \"SELECT ...\"   (see: homelab netsec schema)")
	}
	return format, query, nil
}

func runNetsecQuery(dir, format, query string) ([]byte, error) {
	c, err := netsecConnFrom(dir)
	if err != nil {
		return nil, err
	}
	s := url.Values{}
	s.Set("default_format", format)
	s.Set("output_format_pretty_max_value_width", "300")
	s.Set("output_format_pretty_color", "0")
	return c.do(query, s, nil, false)
}

func netsecSQL(args []string) error {
	format, q, err := parseNetsecSQLArgs(args)
	if err != nil {
		return err
	}
	if q == "-" {
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		q = strings.TrimSpace(string(b))
	}
	out, err := runNetsecQuery(netsecEnvDir, format, q)
	if err != nil {
		return err
	}
	os.Stdout.Write(out)
	return nil
}

const netsecGuide = `
How to read it
  Raw tables keep 365 days. The *_hourly rollups keep counts forever.
  flows        one row per NetFlow record from OPNsense (VLAN 10 and 20).
               Pod traffic shows the node's address: Calico NATs it.
               Mail clients show as OPNsense (10.0.20.1): use haproxy.
  eve          Suricata EVE events: alert, dns, tls, http, ssh.
               Typed columns: signature_id, signature, severity, dns_rrname,
               tls_sni, http_hostname ...; the whole event is in payload
               (payload.alert.metadata, payload.tls.ja4, payload.ssh.client ...).
               A flow crossing VLAN 10 and 20 appears twice; collapse by community_id.
  haproxy      one row per connection to the internet-facing mail ports
               (25, 465, 587, 993) with the real client_ip, bytes, duration and
               termination (HAProxy's two-letter state, e.g. CD = client hung up).
  proxy        Squid access log for opted-in machines (alias opted_in).
               url has its query string stripped; sni and bump_mode (bump or
               splice) show what was decrypted. Empty while nobody is opted in.
  dns_queries  pod DNS lookups logged by node-local-dns, sent by Alloy over OTLP.
               client_ip is the pod; name it with kube_pod_info.
  tetragon     process starts and outbound connects from k8s nodes.
  *_hourly     one row per hour and key, kept forever, filled by materialized
               views from the raw table of the same name (eve_* from eve).
               SummingMergeTree: a key can sit in several rows until a merge,
               so always sum() the counters with GROUP BY. flows_hourly.port is
               the lower of the two ports, so both directions share it.
  Addresses are IPv6 columns; IPv4 is stored mapped (::ffff:a.b.c.d).
  Use IPv4NumToString(toIPv4(src_ip)) or toString(src_ip) to print them.

Examples
  -- top talkers to the internet in the last hour
  SELECT toString(src_ip) src, sum(bytes) b FROM netsec.flows
  WHERE ts > now() - INTERVAL 1 HOUR AND NOT isIPAddressInRange(toString(dst_ip), '::ffff:10.0.0.0/104')
  GROUP BY src ORDER BY b DESC LIMIT 10

  -- who talked to an address
  SELECT ts, toString(src_ip), src_port, dst_port, proto, bytes FROM netsec.flows
  WHERE dst_ip = toIPv6('203.0.113.7') ORDER BY ts DESC LIMIT 50

  -- alerts by signature today
  SELECT signature, count() n FROM netsec.eve
  WHERE event_type = 'alert' AND ts > today() GROUP BY signature ORDER BY n DESC

  -- long range: bytes per month to an address, from the rollup
  SELECT toStartOfMonth(hour) m, sum(bytes) b FROM netsec.flows_hourly
  WHERE dst_ip = toIPv6('203.0.113.7') GROUP BY m ORDER BY m
`

func netsecSchema(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("schema takes no arguments")
	}
	out, err := runNetsecQuery(netsecEnvDir, "TSV", `SELECT table, groupArray(concat('    ', name, '  ', type)) FROM system.columns
		WHERE database = 'netsec' AND NOT endsWith(table, '_mv') GROUP BY table ORDER BY table FORMAT TSV`)
	if err != nil {
		return err
	}
	fmt.Println("Database netsec (ClickHouse). Query with: homelab netsec sql \"...\"")
	for _, row := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		table, cols, ok := strings.Cut(row, "\t")
		if !ok {
			continue
		}
		fmt.Printf("\nnetsec.%s\n", table)
		cols = strings.TrimSuffix(strings.TrimPrefix(cols, "['"), "']")
		for _, col := range strings.Split(cols, "','") {
			fmt.Println(strings.ReplaceAll(col, `\'`, "'"))
		}
	}
	fmt.Print(netsecGuide)
	return nil
}
