package main

// `homelab claude-sessions`: the long-term store of every Claude Code session
// on the devvm (stacks/claude-sessions, ADR-0039).
//
//	ingest   root, from claude-sessions-ingest.timer: ship new transcript bytes
//	sql      admins: run a read-only query
//	schema   admins: tables, columns and example queries
//	restore  admins: write a user's ~/.claude and ~/.codex back from the store
//	mcp-secrets  admins: the MCP secrets the store leaves out, kept in Vault

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	claudeSessionsURL     = "https://claude-sessions-db.viktorbarzin.me"
	claudeSessionsEnvDir  = "/etc/claude-sessions"
	claudeSessionsState   = "/var/lib/claude-sessions-ingest/state.json"
	claudeSessionsMetrics = "/var/lib/node_exporter/textfile/claude_sessions_ingest.prom"
)

func claudeSessionsCommands() []Command {
	return []Command{
		{Path: []string{"claude-sessions", "sql"}, Tier: TierRead,
			Summary: "query every stored Claude session (admins): claude-sessions sql \"<SELECT ...>\" [--format TSVWithNames|JSONEachRow|...]  (\"-\" reads the query from stdin)",
			Run:     claudeSessionsSQL},
		{Path: []string{"claude-sessions", "schema"}, Tier: TierRead,
			Summary: "tables, columns and example queries for the Claude session store (admins)",
			Run:     claudeSessionsSchema},
		{Path: []string{"claude-sessions", "ingest"}, Tier: TierWrite,
			Summary: "ship new transcript bytes and the rest of ~/.claude and ~/.codex into the session store (root; run by claude-sessions-ingest.timer): claude-sessions ingest [--user <name>] [--homes /home]",
			Run:     claudeSessionsIngest},
		{Path: []string{"claude-sessions", "restore"}, Tier: TierWrite,
			Summary: "write a user's ~/.claude and ~/.codex back from the store so claude --resume works after a rebuild (admins): claude-sessions restore --user <name> (--to <home-dir> | --tar <file|-> | --rebuild) [--session <id>] [--path <rel>]... [--force]",
			Run:     claudeSessionsRestore},
		{Path: []string{"claude-sessions", "mcp-secrets"}, Tier: TierWrite,
			Summary: "keep the MCP server secrets the store leaves out in Vault and put them back after a rebuild (admins): claude-sessions mcp-secrets (capture | fill | list) --user <name> [--home <dir>]",
			Run:     claudeSessionsMCPSecrets},
	}
}

// sessionsConn builds the connection for a role ("ingest" or "reader"):
// CLAUDE_SESSIONS_URL / _USER / _PASSWORD from the environment first (how the
// systemd unit and tests pass them), then /etc/claude-sessions/<role>.env.
func sessionsConn(role string) (dbConn, error) {
	c := dbConn{URL: os.Getenv("CLAUDE_SESSIONS_URL"), User: os.Getenv("CLAUDE_SESSIONS_USER"), Password: os.Getenv("CLAUDE_SESSIONS_PASSWORD")}
	if c.User == "" || c.Password == "" {
		path := filepath.Join(claudeSessionsEnvDir, role+".env")
		b, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrPermission) {
			return c, fmt.Errorf("%s is readable by admins only, so the session store is admin-only for now", path)
		}
		if err != nil {
			return c, fmt.Errorf("no credentials for the session store: %w", err)
		}
		env := parseEnvFile(string(b))
		c.User, c.Password = env["CLAUDE_SESSIONS_USER"], env["CLAUDE_SESSIONS_PASSWORD"]
		if c.URL == "" {
			c.URL = env["CLAUDE_SESSIONS_URL"]
		}
	}
	if c.URL == "" {
		c.URL = claudeSessionsURL
	}
	if c.User == "" || c.Password == "" {
		return c, fmt.Errorf("session store credentials are incomplete (need CLAUDE_SESSIONS_USER and CLAUDE_SESSIONS_PASSWORD)")
	}
	return c, nil
}

func claudeSessionsSQL(args []string) error {
	format := "PrettyCompactMonoBlock"
	var parts []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--format":
			if i+1 >= len(args) {
				return fmt.Errorf("--format needs a ClickHouse output format, e.g. TSVWithNames")
			}
			i++
			format = args[i]
		default:
			parts = append(parts, args[i])
		}
	}
	q := strings.TrimSpace(strings.Join(parts, " "))
	if q == "-" {
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		q = strings.TrimSpace(string(b))
	}
	if q == "" {
		return fmt.Errorf("usage: homelab claude-sessions sql \"SELECT ...\"   (see: homelab claude-sessions schema)")
	}
	c, err := sessionsConn("reader")
	if err != nil {
		return err
	}
	s := url.Values{}
	s.Set("default_format", format)
	s.Set("output_format_pretty_max_value_width", "300")
	s.Set("output_format_pretty_color", "0")
	out, err := c.do(q, s, nil, false)
	if err != nil {
		return err
	}
	os.Stdout.Write(out)
	return nil
}

const claudeSessionsGuide = `
How to read it
  lines     one row per transcript line; every column is derived from raw,
            the original JSON line (JSONExtract* works on it for anything else).
            type: user | assistant | system | attachment | cost-state | ...
            subtype: system subtype or attachment type (turn_duration,
            compact_boundary, hook_success, ...). agent_id != '' is a subagent.
            Its token columns repeat on every content-block line of a
            message: never sum them, use claude.requests.
            Write the column file as lines.file or ` + "`file`" + ` (bare file can
            parse as the file() table function, which the reader may not use).
  requests  view, one row per API request: model and token counts. Sum
            tokens here.
  blocks    one row per message content block. role user|assistant,
            kind text|thinking|tool_use|tool_result. tool_use rows carry
            tool_name and the input JSON in text; tool_result rows carry
            is_error and the output. Join them on tool_use_id.
            A typed prompt: role='user' AND kind='text' AND prompt_origin='human'.
  files     large tool outputs (kind tool-result) and subagent metadata; use
            FROM claude.files FINAL.
  home_files  the rest of ~/.claude and ~/.codex, one row per file (plans,
            tasks, teams, todos, file-history, settings with secrets
            redacted, Codex config). path is relative to the home; kind is
            tool:top-level-entry (claude:plans, codex:sessions). encoding
            text|base64|omitted. Use FROM claude.home_files FINAL.
  home_lines  .jsonl home files line by line: .claude/history.jsonl (every
            typed prompt), Codex rollouts under .codex/sessions/.
  sessions  view, one row per session: cost_usd, prompts, human_prompts,
            subagents, compactions, api_requests, tokens, models,
            started/ended. cost_usd sums the last cost-state of each Claude
            process, so a resumed session counts every run. It is final once
            the session has exited; a running session's cost can lag.
  model_costs  view, one row per session and model: cost_usd and tokens.
            Use it for spend per model. Do NOT arrayJoin(sessions.models):
            that credits a session's whole cost to every model it used.
  turns     view, one row per finished turn with duration_ms.

Search: hasAnyTokens(text, 'traefik') / hasAllTokens(text, ['git','crypt'])
use the text index (case-insensitive, whole words). ILIKE '%...%' works but
scans. Filter by os_user and a time range first; tables are partitioned by
month and sorted by (os_user, session_id, ts).

Examples
  -- spend per week and model
  SELECT toStartOfWeek(started) week, model, round(sum(cost_usd),2) usd
  FROM claude.model_costs WHERE os_user='wizard' GROUP BY week, model ORDER BY week, usd DESC

  -- output tokens and requests per day
  SELECT toDate(ts) day, count() requests, sum(output_tokens) out_tokens
  FROM claude.requests WHERE os_user='wizard' GROUP BY day ORDER BY day

  -- tools that fail most, last 30 days
  SELECT u.tool_name, count() calls, countIf(r.is_error) failed, round(failed/calls,3) rate
  FROM claude.blocks r JOIN (SELECT tool_use_id, tool_name FROM claude.blocks WHERE kind='tool_use') u USING tool_use_id
  WHERE r.kind='tool_result' AND r.ts > now() - INTERVAL 30 DAY
  GROUP BY u.tool_name ORDER BY failed DESC LIMIT 20

  -- the actual error text of failed Bash calls this week
  SELECT ts, session_id, substring(text,1,300) FROM claude.blocks
  WHERE kind='tool_result' AND is_error AND ts > now() - INTERVAL 7 DAY ORDER BY ts DESC LIMIT 20

  -- most expensive sessions and their first prompt
  SELECT s.session_id, round(s.cost_usd,2) usd, s.started, substring(p.text,1,150) first_prompt
  FROM claude.sessions s LEFT JOIN (SELECT session_id, argMin(text, ts) text FROM claude.blocks
    WHERE role='user' AND kind='text' AND prompt_origin='human' AND agent_id='' GROUP BY session_id) p USING session_id
  ORDER BY usd DESC LIMIT 10

  -- slowest hooks
  SELECT JSONExtractString(raw,'attachment','hookName') hook, count() runs, round(avg(duration_ms)) avg_ms
  FROM claude.lines WHERE subtype='hook_success' GROUP BY hook ORDER BY avg_ms DESC LIMIT 10

  -- sessions that mention a topic
  SELECT session_id, min(ts) first_seen, count() hits FROM claude.blocks
  WHERE hasAnyTokens(text, 'mileageplus') GROUP BY session_id ORDER BY first_seen DESC

  -- turn time and context compactions per week
  SELECT toStartOfWeek(ts) week, count() turns, round(quantile(0.5)(duration_ms)/1000,1) p50_s
  FROM claude.turns GROUP BY week ORDER BY week
`

func claudeSessionsSchema(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("schema takes no arguments")
	}
	c, err := sessionsConn("reader")
	if err != nil {
		return err
	}
	s := url.Values{}
	s.Set("default_format", "TSV")
	out, err := c.do(`SELECT table, groupArray(concat('    ', name, '  ', type)) FROM system.columns
		WHERE database = 'claude' GROUP BY table ORDER BY table FORMAT TSV`, s, nil, false)
	if err != nil {
		return err
	}
	fmt.Println("Database claude (ClickHouse). Query with: homelab claude-sessions sql \"...\"")
	for _, row := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		table, cols, ok := strings.Cut(row, "\t")
		if !ok {
			continue
		}
		fmt.Printf("\nclaude.%s\n", table)
		// groupArray comes back as ['a','b']; print one column per line.
		cols = strings.TrimSuffix(strings.TrimPrefix(cols, "['"), "']")
		for _, col := range strings.Split(cols, "','") {
			fmt.Println(strings.ReplaceAll(col, `\'`, "'"))
		}
	}
	fmt.Print(claudeSessionsGuide)
	return nil
}

func claudeSessionsIngest(args []string) error {
	cfg := ingestConfig{HomesRoot: "/home", StatePath: claudeSessionsState, Budget: 8 << 20, RequireRestore: true}
	metrics := claudeSessionsMetrics
	for i := 0; i < len(args); i++ {
		need := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", args[i])
			}
			i++
			return args[i], nil
		}
		var err error
		switch args[i] {
		case "--user":
			cfg.OnlyUser, err = need()
		case "--homes":
			cfg.HomesRoot, err = need()
		case "--state":
			cfg.StatePath, err = need()
		case "--metrics":
			metrics, err = need()
		default:
			return fmt.Errorf("unknown argument %q", args[i])
		}
		if err != nil {
			return err
		}
	}
	c, err := sessionsConn("ingest")
	if err != nil {
		return err
	}
	cfg.DB = c
	start := time.Now()
	st, runErr := runIngest(cfg)
	dur := time.Since(start)
	status := "ok"
	if runErr != nil {
		status = "error"
	}
	// key=value so Loki can filter it by the unit label (devvm-io-guard.md).
	fmt.Printf("claude-sessions-ingest status=%s users=%d files_seen=%d files_changed=%d lines=%d bytes=%d side_files=%d home_files=%d home_lines=%d file_errors=%d users_waiting_for_restore=%d mcp_uncaptured=%d duration_ms=%d\n",
		status, st.Users, st.FilesSeen, st.FilesChanged, st.Lines, st.Bytes, st.SideFiles, st.HomeFiles, st.HomeLines, st.FileErrors, st.UsersWaiting, st.MCPUncaptured, dur.Milliseconds())
	if metrics != "" {
		writeIngestMetrics(metrics, st, runErr == nil, dur)
	}
	return runErr
}

// writeIngestMetrics updates the node_exporter textfile. The last-success
// timestamp is carried over from the previous file on a failed run, so the
// freshness alert measures time since the last GOOD run.
func writeIngestMetrics(path string, st ingestStats, ok bool, dur time.Duration) {
	last := ""
	if ok {
		last = strconv.FormatInt(time.Now().Unix(), 10)
	} else if b, err := os.ReadFile(path); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, "claude_sessions_ingest_last_success_timestamp_seconds ") {
				last = strings.TrimPrefix(l, "claude_sessions_ingest_last_success_timestamp_seconds ")
			}
		}
	}
	okv := 0
	if ok {
		okv = 1
	}
	var b strings.Builder
	b.WriteString("# HELP claude_sessions_ingest_last_success_timestamp_seconds Unix time of the last ingest run that finished without a database error.\n")
	b.WriteString("# TYPE claude_sessions_ingest_last_success_timestamp_seconds gauge\n")
	if last != "" {
		b.WriteString("claude_sessions_ingest_last_success_timestamp_seconds " + last + "\n")
	}
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_last_run_ok gauge\nclaude_sessions_ingest_last_run_ok %d\n", okv)
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_last_run_lines gauge\nclaude_sessions_ingest_last_run_lines %d\n", st.Lines)
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_last_run_bytes gauge\nclaude_sessions_ingest_last_run_bytes %d\n", st.Bytes)
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_last_run_file_errors gauge\nclaude_sessions_ingest_last_run_file_errors %d\n", st.FileErrors)
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_last_run_files_seen gauge\nclaude_sessions_ingest_last_run_files_seen %d\n", st.FilesSeen)
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_last_run_duration_seconds gauge\nclaude_sessions_ingest_last_run_duration_seconds %.3f\n", dur.Seconds())
	// Users the ingest skips until `restore --rebuild` has run for them. A
	// user stuck here has new sessions that never reach the store.
	fmt.Fprintf(&b, "# HELP claude_sessions_ingest_users_waiting_for_restore Users with agent state that the ingest skips until restore --rebuild has run for them.\n")
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_users_waiting_for_restore gauge\nclaude_sessions_ingest_users_waiting_for_restore %d\n", st.UsersWaiting)
	// MCP server entries whose secret was added or changed after the last
	// `mcp-secrets capture`: a rebuild would lose it or put back the old one.
	fmt.Fprintf(&b, "# HELP claude_sessions_ingest_mcp_entries_uncaptured Live MCP server entries with secrets that are new or changed since the last mcp-secrets capture.\n")
	fmt.Fprintf(&b, "# TYPE claude_sessions_ingest_mcp_entries_uncaptured gauge\nclaude_sessions_ingest_mcp_entries_uncaptured %d\n", st.MCPUncaptured)
	tmp := path + ".tmp"
	if os.WriteFile(tmp, []byte(b.String()), 0o644) == nil {
		os.Rename(tmp, path)
	}
}
