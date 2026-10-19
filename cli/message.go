package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// message verbs let the agent read a thread and send messages AS Viktor on his
// personal WhatsApp, via browser automation of the warm chrome-service session.
// Design: docs/plans/2026-07-20-homelab-message-personal-messaging-design.md.
//
// Safety model (all enforced here or in the embedded automation):
//   - --to must name exactly one chat (case-insensitive exact title), which is
//     opened + verified against the composer before typing.
//   - a send only counts once WhatsApp marks the message Sent/Delivered/Read;
//     a red "Something went wrong" or a message still pending is an error.
//   - preview + confirm by default; --yes skips (only after the agent has shown
//     the message in chat and the human approved); --dry-run resolves + prints,
//     never sends.
//   - every send is appended to an audit log.
//   - reading is a SEPARATE verb from sending (the read/send injection firewall):
//     incoming text is never fed into a send in the same step.

type messageOpts struct {
	verb   string // send | read | contacts
	via    string // wa (phase 1); messenger/ig deferred to phase 2
	to     string
	search string
	text   string
	limit  int
	dryRun bool
	yes    bool
	help   bool
	// stderrTee also receives the automation's stderr (delegate uses it to
	// name a failure); nil leaves stderr going only to the terminal.
	stderrTee io.Writer
}

// parseMessageArgs parses args after `message <verb>`. Positionals join into the
// message text (send). Mirrors parseBrowserArgs' explicit-index flag style.
func parseMessageArgs(verb string, args []string) (messageOpts, error) {
	o := messageOpts{verb: verb, via: "wa", limit: 20}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		takeVal := func(flag string) (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s expects a value", flag)
			}
			i++
			return args[i], nil
		}
		switch {
		case a == "-h" || a == "--help":
			o.help = true
		case a == "--dry-run":
			o.dryRun = true
		case a == "--yes" || a == "-y":
			o.yes = true
		case a == "--via":
			v, err := takeVal("--via")
			if err != nil {
				return o, err
			}
			o.via = v
		case strings.HasPrefix(a, "--via="):
			o.via = strings.TrimPrefix(a, "--via=")
		case a == "--to":
			v, err := takeVal("--to")
			if err != nil {
				return o, err
			}
			o.to = v
		case strings.HasPrefix(a, "--to="):
			o.to = strings.TrimPrefix(a, "--to=")
		case a == "--search":
			v, err := takeVal("--search")
			if err != nil {
				return o, err
			}
			o.search = v
		case strings.HasPrefix(a, "--search="):
			o.search = strings.TrimPrefix(a, "--search=")
		case a == "--limit":
			v, err := takeVal("--limit")
			if err != nil {
				return o, err
			}
			n, err := strconv.Atoi(v)
			if err != nil {
				return o, fmt.Errorf("--limit expects an integer, got %q", v)
			}
			o.limit = n
		case strings.HasPrefix(a, "--limit="):
			n, err := strconv.Atoi(strings.TrimPrefix(a, "--limit="))
			if err != nil {
				return o, fmt.Errorf("--limit expects an integer")
			}
			o.limit = n
		case a != "-" && strings.HasPrefix(a, "-"):
			return o, fmt.Errorf("unknown flag %q (try: homelab message --help)", a)
		default:
			pos = append(pos, a)
		}
	}
	o.text = strings.TrimSpace(strings.Join(pos, " "))
	return o, nil
}

// --- paths ----------------------------------------------------------------

func configHome() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return v
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config")
	}
	return ".config"
}

func auditPath() string {
	if v := os.Getenv("HOMELAB_MESSAGE_AUDIT"); v != "" {
		return v
	}
	if v := os.Getenv("XDG_STATE_HOME"); v != "" {
		return filepath.Join(v, "homelab", "message-audit.jsonl")
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".local", "state", "homelab", "message-audit.jsonl")
	}
	return "message-audit.jsonl"
}

// --- audit ----------------------------------------------------------------

type auditRecord struct {
	Time    string `json:"time"`
	Via     string `json:"via"`
	Action  string `json:"action"` // send | dry-run | delegate
	To      string `json:"to"`
	Chars   int    `json:"chars"`
	SHA8    string `json:"sha8"`    // sha256(text)[:8] — correlate without storing full text everywhere
	Preview string `json:"preview"` // first 60 runes, for human review
	Result  string `json:"result"`  // sent | dry-run | error: <msg>
}

// buildAuditRecord captures one send attempt. now is injected for testability.
func buildAuditRecord(now, via, action, to, text, result string) auditRecord {
	sum := sha256.Sum256([]byte(text))
	runes := []rune(text)
	preview := string(runes)
	if len(runes) > 60 {
		preview = string(runes[:60]) + "…"
	}
	return auditRecord{
		Time:    now,
		Via:     via,
		Action:  action,
		To:      to,
		Chars:   len(runes),
		SHA8:    hex.EncodeToString(sum[:])[:8],
		Preview: preview,
		Result:  result,
	}
}

func (r auditRecord) line() (string, error) {
	b, err := json.Marshal(r)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// appendAudit appends one JSONL record to path, creating parent dirs (0700 — the
// log holds message previews).
func appendAudit(path string, r auditRecord) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	ln, err := r.line()
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(ln + "\n")
	return err
}
