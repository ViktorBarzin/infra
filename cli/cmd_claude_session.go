package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// `homelab claude-usage --session <id|name>` — read one conversation.
//
// This exists because the streaming telemetry (infra ADR-0025) deliberately
// cannot answer it. Loki carries the prompts and the responses, but a
// tool_result event records only tool_input_size_bytes and
// tool_result_size_bytes — the SIZES, never the content. Since tool traffic is
// the bulk of a session, the transcript on disk is the only complete record.
//
// The two halves compose: Loki is a searchable index (filter by prompt text,
// user, session name, time) and its session_id IS the transcript's filename,
// so a session found there can be read in full here.

// tmuxPersistDir holds the name -> uuid manifests. A var so tests can point
// somewhere else.
var tmuxPersistDir = "/var/lib/tmux-persist"

var sessionIDRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// looksLikeSessionID distinguishes a uuid from a human session name, so the
// caller can pass either.
func looksLikeSessionID(s string) bool { return sessionIDRe.MatchString(s) }

// resolveSessionName maps a tmux session NAME to a session id. Claude's
// transcripts know nothing about names — the mapping lives in tmux-persist's
// manifests, which also cover sessions that are no longer running.
//
// Names are unique per user, not globally, so an ambiguous name is an error
// rather than a guess: picking one silently would open a different person's
// conversation.
func resolveSessionName(dir, name string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", fmt.Errorf("cannot read the session manifests at %s: %w "+
			"(they are root-owned — try sudo)", dir, err)
	}

	type hit struct{ user, id string }
	var hits []hit
	seen := map[string]bool{}
	// The directory is world-readable but the manifests inside are root-only,
	// so an unprivileged run reads nothing. Counting that is what separates
	// "the name does not exist" from "I could not look" -- reporting the first
	// when the second is true sends someone hunting a name that is right there.
	unreadable := 0

	for _, e := range entries {
		fname := e.Name()
		if !strings.HasSuffix(fname, ".tsv") {
			continue
		}
		user := strings.TrimSuffix(fname, ".tsv")
		user = strings.TrimSuffix(user, ".history")
		user = strings.TrimSuffix(user, ".forgotten")

		body, err := os.ReadFile(filepath.Join(dir, fname))
		if err != nil {
			if os.IsPermission(err) {
				unreadable++
			}
			continue
		}
		for _, line := range strings.Split(string(body), "\n") {
			cols := strings.Split(line, "\t")
			if len(cols) < 3 || cols[0] != name {
				continue
			}
			key := user + "/" + cols[2]
			if seen[key] {
				continue
			}
			seen[key] = true
			hits = append(hits, hit{user: user, id: cols[2]})
		}
	}

	switch len(hits) {
	case 0:
		if unreadable > 0 {
			return "", fmt.Errorf("cannot read %d session manifest(s) in %s — they are "+
				"root-owned, so re-run with sudo; %q may well exist", unreadable, dir, name)
		}
		return "", fmt.Errorf("no session named %q (names come from tmux-persist; "+
			"try the session id instead, or check the Sessions table in Grafana)", name)
	case 1:
		return hits[0].id, nil
	default:
		var who []string
		for _, h := range hits {
			who = append(who, fmt.Sprintf("%s (%s)", h.user, h.id))
		}
		sort.Strings(who)
		return "", fmt.Errorf("the name %q belongs to more than one session: %s — "+
			"pass the session id to choose", name, strings.Join(who, ", "))
	}
}

// findTranscript locates <session>.jsonl under any user's projects.
func findTranscript(roots []userRoot, session string) (string, error) {
	var unreadable bool
	for _, root := range roots {
		base := filepath.Join(root.Home, ".claude", "projects")
		projects, err := os.ReadDir(base)
		if err != nil {
			if os.IsPermission(err) {
				unreadable = true
			}
			continue
		}
		for _, p := range projects {
			candidate := filepath.Join(base, p.Name(), session+".jsonl")
			if _, err := os.Stat(candidate); err == nil {
				return candidate, nil
			}
		}
	}
	hint := ""
	if unreadable {
		hint = " (some home directories were not readable — try sudo)"
	}
	return "", fmt.Errorf("no transcript found for session %s%s", session, hint)
}

type transcriptOpts struct {
	// Tools includes tool inputs and results, which are usually the bulk of a
	// session and are summarised unless asked for.
	Tools bool
	// MaxToolChars bounds each expanded tool payload. 0 uses a sane default.
	MaxToolChars int
	// Meta includes harness-injected user records (skill bodies, hook context).
	// Off by default: the question this answers is what the PERSON asked.
	Meta bool
}

// turnLine is the shape renderTranscript reads. Content is raw because it is a
// string on user records and an array of blocks on assistant ones.
type turnLine struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Message   struct {
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
	// IsMeta marks a user record that the HARNESS injected -- a skill body,
	// a hook's context -- rather than something the person typed. Both are
	// user-role records, so without this the injected text reads as the user's
	// own words and buries the actual prompt.
	IsMeta        bool            `json:"isMeta"`
	ToolUseResult json.RawMessage `json:"toolUseResult"`
}

type richBlock struct {
	Type  string          `json:"type"`
	Text  string          `json:"text"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input"`
}

func richBlocks(raw json.RawMessage) []richBlock {
	if len(raw) == 0 || raw[0] != '[' {
		return nil
	}
	var out []richBlock
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil
	}
	return out
}

// plainText pulls the readable text out of either content shape.
func plainText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return s
		}
		return ""
	}
	var parts []string
	for _, b := range richBlocks(raw) {
		if b.Type == "text" && b.Text != "" {
			parts = append(parts, b.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func clipText(s string, max int) string {
	s = strings.TrimSpace(s)
	if max > 0 && len(s) > max {
		return s[:max] + fmt.Sprintf(" … (+%d chars)", len(s)-max)
	}
	return s
}

func indent(s, prefix string) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = prefix + l
	}
	return strings.Join(lines, "\n")
}

// renderTranscript turns one transcript into a readable conversation.
func renderTranscript(path string, opts transcriptOpts) (string, error) {
	fh, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer fh.Close()

	maxTool := opts.MaxToolChars
	if maxTool <= 0 {
		maxTool = 800
	}

	var b strings.Builder
	sc := bufio.NewScanner(fh)
	// Transcript lines carry whole tool results; the default 64 KiB limit ends
	// the scan early and silently.
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)

	skipped := 0
	for sc.Scan() {
		raw := strings.TrimSpace(sc.Text())
		if raw == "" {
			continue
		}
		var line turnLine
		if err := json.Unmarshal([]byte(raw), &line); err != nil {
			skipped++
			continue
		}
		if line.Type != "user" && line.Type != "assistant" {
			continue
		}

		stamp := ""
		if t, err := time.Parse(time.RFC3339, line.Timestamp); err == nil {
			stamp = t.Local().Format("15:04:05")
		}

		text := plainText(line.Message.Content)
		var tools []string
		var toolDetail []string
		for _, blk := range richBlocks(line.Message.Content) {
			if blk.Type != "tool_use" || blk.Name == "" {
				continue
			}
			tools = append(tools, blk.Name)
			if opts.Tools && len(blk.Input) > 0 {
				toolDetail = append(toolDetail,
					fmt.Sprintf("%s %s", blk.Name, clipText(string(blk.Input), maxTool)))
			}
		}

		switch line.Type {
		case "user":
			// A user record with no text is a tool RESULT being fed back, not
			// something a person typed; showing those as user turns would bury
			// the actual conversation.
			if text == "" {
				continue
			}
			if line.IsMeta {
				// Injected context, not typed input. Kept because it explains
				// what the model saw, but labelled and clipped so it cannot be
				// mistaken for the user's own words.
				if opts.Meta {
					fmt.Fprintf(&b, "\n%s  [injected context]\n%s\n",
						stamp, indent(clipText(text, maxTool), "  "))
				}
				continue
			}
			fmt.Fprintf(&b, "\n%s  you\n%s\n", stamp, indent(clipText(text, 0), "  "))
		case "assistant":
			head := stamp + "  claude"
			if len(tools) > 0 {
				head += "  [" + strings.Join(tools, ", ") + "]"
			}
			fmt.Fprintf(&b, "\n%s\n", head)
			if text != "" {
				fmt.Fprintf(&b, "%s\n", indent(clipText(text, 0), "  "))
			}
			for _, d := range toolDetail {
				fmt.Fprintf(&b, "%s\n", indent(d, "    | "))
			}
		}
	}
	if skipped > 0 {
		fmt.Fprintf(&b, "\n(%d unreadable lines skipped)\n", skipped)
	}
	return b.String(), nil
}

// claudeSessionRun implements `claude-usage --session`.
func claudeSessionRun(session string, opts transcriptOpts) error {
	id := session
	if !looksLikeSessionID(session) {
		resolved, err := resolveSessionName(tmuxPersistDir, session)
		if err != nil {
			return err
		}
		id = resolved
	}

	roots, unreadable := discoverUsers("all")
	path, err := findTranscript(roots, id)
	if err != nil {
		if len(unreadable) > 0 {
			return fmt.Errorf("%w — not readable from this account: %s",
				err, strings.Join(unreadable, ", "))
		}
		return err
	}

	out, err := renderTranscript(path, opts)
	if err != nil {
		return err
	}
	fmt.Printf("session %s\n%s\n", id, path)
	if !opts.Tools {
		fmt.Println("(tool inputs summarised — add --tools to expand)")
	}
	fmt.Print(out)
	return nil
}
