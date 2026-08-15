package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// `homelab claude-usage` — how Claude Code is actually used on this box
// (infra ADR-0025).
//
// The streaming half of that ADR sends events to Loki (30 days) and metrics to
// Prometheus (26 weeks). This is the other half, and it exists because those
// windows are not the same question: the transcripts on disk are the WHOLE
// history — 1359 files and ~1.2 GB at the time of writing — and Loki refuses
// anything older than a week, so the past can never be backfilled into it.
//
// It reads only what Claude already wrote, computes locally, and sends nothing
// anywhere. Nothing runs between invocations.
type userRoot struct {
	User string
	Home string
}

// userStats is one person's usage over the scanned window.
type userStats struct {
	Sessions         int
	Turns            int
	InputTokens      int
	OutputTokens     int
	CacheReadTokens  int
	CacheWriteTokens int
	ToolCalls        int
	Tools            map[string]int
	Models           map[string]int
	Projects         map[string]int
	FirstSeen        time.Time
	LastSeen         time.Time
}

// cacheReadShare is the fraction of prompt-side tokens served from cache
// rather than re-sent. It is the cheapest efficiency signal in the data: a low
// share means context is being rebuilt turn after turn.
func (u *userStats) cacheReadShare() float64 {
	total := u.InputTokens + u.CacheReadTokens
	if total == 0 {
		return 0
	}
	return float64(u.CacheReadTokens) / float64(total)
}

type usageReport struct {
	Users   map[string]*userStats
	Files   int
	Skipped int // lines that could not be parsed
	Since   time.Time
	// Unreadable names users whose transcripts exist but could not be opened.
	// Home directories here are mode 0750, so running as one user silently
	// omits the others -- and a missing user looks identical to a user with no
	// sessions, which would make the comparison this tool exists for quietly
	// wrong. Naming them is the difference between "emo does not use Claude"
	// and "you cannot see emo from here".
	Unreadable []string
}

func newUserStats() *userStats {
	return &userStats{
		Tools:    map[string]int{},
		Models:   map[string]int{},
		Projects: map[string]int{},
	}
}

// transcriptLine is the subset of a transcript record this reads. Claude writes
// far more per line; everything not named here is ignored on purpose, so a
// change to an unrelated field cannot break the scan.
type transcriptLine struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Message   struct {
		Model string `json:"model"`
		Role  string `json:"role"`
		// Content is RAW because its shape varies: a user message carries a
		// plain string, an assistant message an array of blocks. Decoding
		// straight into a slice makes every string-content record a parse
		// failure, which silently undercounts turns on real transcripts.
		Content json.RawMessage `json:"content"`
		Usage   struct {
			InputTokens              int `json:"input_tokens"`
			OutputTokens             int `json:"output_tokens"`
			CacheReadInputTokens     int `json:"cache_read_input_tokens"`
			CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

// contentBlock is one element of an assistant message's content array.
type contentBlock struct {
	Type string `json:"type"`
	Name string `json:"name"`
}

// contentBlocks decodes the block array when there is one. A string body (how
// user messages are written) simply has no blocks, and is not an error.
func contentBlocks(raw json.RawMessage) []contentBlock {
	if len(raw) == 0 || raw[0] != '[' {
		return nil
	}
	var blocks []contentBlock
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return nil
	}
	return blocks
}

// scanTranscripts walks each user's transcripts and aggregates them. since is
// the cutoff; a zero value means everything.
//
// It is deliberately forgiving. Across a corpus this size there are truncated
// files from killed sessions, half-written last lines, and records from older
// Claude versions — none of which is a reason to abandon the run. Unparseable
// lines are counted and reported rather than silently dropped, so a corpus that
// is mostly unreadable cannot masquerade as a corpus that is mostly empty.
func scanTranscripts(roots []userRoot, since time.Time) (*usageReport, error) {
	rep := &usageReport{Users: map[string]*userStats{}, Since: since}

	for _, root := range roots {
		base := filepath.Join(root.Home, ".claude", "projects")
		entries, err := os.ReadDir(base)
		if err != nil {
			// A user who has never run Claude, or a home this process cannot
			// read, is not an error — it is just no data.
			continue
		}
		for _, project := range entries {
			if !project.IsDir() {
				continue
			}
			projectDir := filepath.Join(base, project.Name())
			files, err := os.ReadDir(projectDir)
			if err != nil {
				continue
			}
			for _, f := range files {
				if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
					continue
				}
				// A transcript's mtime is its last append, so a file untouched
				// since before the cutoff cannot hold a record inside the
				// window. Skipping it unopened is what keeps a one-day query
				// from costing a full read of the corpus -- 1.2 GB and ~35s
				// here, long enough to read as a hang.
				if !since.IsZero() {
					if info, err := f.Info(); err == nil && info.ModTime().Before(since) {
						continue
					}
				}
				rep.Files++
				scanOneFile(rep, root.User, project.Name(),
					filepath.Join(projectDir, f.Name()), since)
			}
		}
	}
	return rep, nil
}

func scanOneFile(rep *usageReport, user, project, path string, since time.Time) {
	fh, err := os.Open(path)
	if err != nil {
		return
	}
	defer fh.Close()

	stats := rep.Users[user]
	if stats == nil {
		stats = newUserStats()
	}

	sc := bufio.NewScanner(fh)
	// Transcript lines carry whole tool results and file contents, so the
	// default 64 KiB scanner limit is far too small — without this, long lines
	// end the scan of that file early and silently.
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)

	counted := false
	for sc.Scan() {
		raw := strings.TrimSpace(sc.Text())
		if raw == "" {
			continue
		}
		var line transcriptLine
		if err := json.Unmarshal([]byte(raw), &line); err != nil {
			rep.Skipped++
			continue
		}

		// Records without a usable timestamp cannot be placed in the window.
		var ts time.Time
		if line.Timestamp != "" {
			parsed, err := time.Parse(time.RFC3339, line.Timestamp)
			if err != nil {
				rep.Skipped++
				continue
			}
			ts = parsed
		}
		if !since.IsZero() && !ts.IsZero() && ts.Before(since) {
			continue
		}

		switch line.Type {
		case "user":
			// One user record is one turn. Sidechain and tool-result records
			// carry other types, so this does not overcount them.
			stats.Turns++
		case "assistant":
			u := line.Message.Usage
			stats.InputTokens += u.InputTokens
			stats.OutputTokens += u.OutputTokens
			stats.CacheReadTokens += u.CacheReadInputTokens
			stats.CacheWriteTokens += u.CacheCreationInputTokens
			if line.Message.Model != "" {
				stats.Models[line.Message.Model]++
			}
			for _, c := range contentBlocks(line.Message.Content) {
				if c.Type == "tool_use" && c.Name != "" {
					stats.Tools[c.Name]++
					stats.ToolCalls++
				}
			}
		}

		if !ts.IsZero() {
			if stats.FirstSeen.IsZero() || ts.Before(stats.FirstSeen) {
				stats.FirstSeen = ts
			}
			if ts.After(stats.LastSeen) {
				stats.LastSeen = ts
			}
		}
		counted = true
	}
	// A file whose every line fell outside the window is not a session in it.
	if counted {
		stats.Sessions++
		stats.Projects[project]++
		rep.Users[user] = stats
	}
}

func fmtInt(n int) string {
	s := strconv.Itoa(n)
	if len(s) <= 3 {
		return s
	}
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	return string(out)
}

func topN(m map[string]int, n int) []string {
	type kv struct {
		K string
		V int
	}
	var all []kv
	for k, v := range m {
		all = append(all, kv{k, v})
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].V != all[j].V {
			return all[i].V > all[j].V
		}
		return all[i].K < all[j].K
	})
	var out []string
	for i, e := range all {
		if i >= n {
			break
		}
		out = append(out, fmt.Sprintf("%s %d", e.K, e.V))
	}
	return out
}

// renderReport writes the human-readable summary. Every section is per-user,
// because the comparison is the question this answers.
func renderReport(rep *usageReport) string {
	var b strings.Builder
	users := make([]string, 0, len(rep.Users))
	for u := range rep.Users {
		users = append(users, u)
	}
	sort.Strings(users)

	fmt.Fprintf(&b, "Claude usage — %d transcripts", rep.Files)
	if !rep.Since.IsZero() {
		fmt.Fprintf(&b, " since %s", rep.Since.Format("2006-01-02"))
	}
	if rep.Skipped > 0 {
		fmt.Fprintf(&b, " (%d unparseable lines skipped)", rep.Skipped)
	}
	b.WriteString("\n\n")

	if len(rep.Unreadable) > 0 {
		fmt.Fprintf(&b, "NOT INCLUDED — no permission to read: %s\n"+
			"  Home directories are mode 0750, so these are invisible from this\n"+
			"  account. Re-run with sudo to include them.\n\n",
			strings.Join(rep.Unreadable, ", "))
	}

	if len(users) == 0 {
		b.WriteString("No sessions found in this window.\n")
		return b.String()
	}

	for _, name := range users {
		u := rep.Users[name]
		fmt.Fprintf(&b, "%s\n", name)
		fmt.Fprintf(&b, "  Sessions      %s over %s turns\n",
			fmtInt(u.Sessions), fmtInt(u.Turns))
		if u.Sessions > 0 {
			fmt.Fprintf(&b, "  Turns/session %.1f\n", float64(u.Turns)/float64(u.Sessions))
		}
		fmt.Fprintf(&b, "  Tokens        in %s · out %s · cache read %s · cache write %s\n",
			fmtInt(u.InputTokens), fmtInt(u.OutputTokens),
			fmtInt(u.CacheReadTokens), fmtInt(u.CacheWriteTokens))
		fmt.Fprintf(&b, "  Cache reuse   %.0f%% of prompt tokens served from cache\n",
			u.cacheReadShare()*100)
		fmt.Fprintf(&b, "  Tool calls    %s", fmtInt(u.ToolCalls))
		if u.Turns > 0 {
			fmt.Fprintf(&b, " (%.1f per turn)", float64(u.ToolCalls)/float64(u.Turns))
		}
		b.WriteString("\n")
		if tools := topN(u.Tools, 6); len(tools) > 0 {
			fmt.Fprintf(&b, "  Top tools     %s\n", strings.Join(tools, " · "))
		}
		if models := topN(u.Models, 3); len(models) > 0 {
			fmt.Fprintf(&b, "  Models        %s\n", strings.Join(models, " · "))
		}
		if projects := topN(u.Projects, 4); len(projects) > 0 {
			fmt.Fprintf(&b, "  Projects      %s\n", strings.Join(projects, " · "))
		}
		if !u.FirstSeen.IsZero() {
			fmt.Fprintf(&b, "  Span          %s → %s\n",
				u.FirstSeen.Format("2006-01-02"), u.LastSeen.Format("2006-01-02"))
		}
		b.WriteString("\n")
	}
	return b.String()
}

// discoverUsers finds the home directories worth scanning. Only users who have
// actually run Claude have a projects directory, so the check is cheap and the
// list stays honest.
func discoverUsers(filter string) (roots []userRoot, unreadable []string) {
	homes, err := os.ReadDir("/home")
	if err != nil {
		return nil, nil
	}
	for _, h := range homes {
		if !h.IsDir() {
			continue
		}
		name := h.Name()
		if filter != "" && filter != "all" && filter != name {
			continue
		}
		home := filepath.Join("/home", name)
		projects := filepath.Join(home, ".claude", "projects")
		if _, err := os.Stat(projects); err != nil {
			// Absent is "never ran Claude"; denied is "ran it, but not visible
			// from this account". Only the second is worth reporting.
			if os.IsPermission(err) {
				unreadable = append(unreadable, name)
			}
			continue
		}
		roots = append(roots, userRoot{User: name, Home: home})
	}
	return roots, unreadable
}

func claudeUsageCommands() []Command {
	return []Command{
		{Path: []string{"claude-usage"}, Tier: TierRead,
			Summary: "how Claude is used on this box, over the full transcript history: claude-usage [--since 30d] [--user wizard|emo|all] [--json] | --session <id|name> [--tools] [--meta]",
			Run:     claudeUsageRun},
	}
}

func claudeUsageRun(args []string) error {
	var (
		since   time.Time
		user    = "all"
		asJSON  bool
		session string
		topts   transcriptOpts
	)
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--user":
			if i+1 >= len(args) {
				return fmt.Errorf("--user needs a value (a username, or 'all')")
			}
			i++
			user = args[i]
		case "--json":
			asJSON = true
		case "--meta":
			// Harness-injected user records (skill bodies, hook context).
			topts.Meta = true
		case "--tools":
			// Tool payloads are the bulk of a session, so they are opt-in.
			topts.Tools = true
		case "--session":
			if i+1 >= len(args) {
				return fmt.Errorf("--session needs a session id or a tmux session name")
			}
			i++
			session = args[i]
		case "--since":
			if i+1 >= len(args) {
				return fmt.Errorf("--since needs a value like 30d, 12h or 2026-01-01")
			}
			i++
			parsed, err := parseSince(args[i])
			if err != nil {
				return err
			}
			since = parsed
		default:
			return fmt.Errorf("unknown argument %q", args[i])
		}
	}

	// --session reads ONE conversation in full, which the aggregate report
	// cannot show: Loki records only the SIZE of each tool payload, so the
	// transcript is the sole complete record of what actually happened.
	if session != "" {
		return claudeSessionRun(session, topts)
	}

	roots, unreadable := discoverUsers(user)
	if len(roots) == 0 && len(unreadable) == 0 {
		return fmt.Errorf("no Claude transcripts found (looked under /home/*/.claude/projects)")
	}
	rep, err := scanTranscripts(roots, since)
	if err != nil {
		return err
	}
	rep.Unreadable = unreadable

	if asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(rep)
	}
	fmt.Print(renderReport(rep))
	return nil
}

// parseSince accepts a duration shorthand (30d, 12h) or an absolute date.
func parseSince(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	if strings.HasSuffix(s, "d") {
		days, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err == nil {
			return time.Now().AddDate(0, 0, -days), nil
		}
	}
	if d, err := time.ParseDuration(s); err == nil {
		return time.Now().Add(-d), nil
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		return t, nil
	}
	return time.Time{}, fmt.Errorf("cannot read %q as a duration (30d, 12h) or a date (2026-01-01)", s)
}
