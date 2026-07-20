package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
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
//   - sends only reach an ALLOWLISTED contact (fail-closed: empty/missing list
//     refuses every send); a fuzzy --to must resolve to exactly one allowlisted
//     title, which is then opened + verified against the composer before typing.
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

// --- allowlist ------------------------------------------------------------

func configHome() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return v
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config")
	}
	return ".config"
}

func allowlistPath() string {
	if v := os.Getenv("HOMELAB_MESSAGE_ALLOWLIST"); v != "" {
		return v
	}
	return filepath.Join(configHome(), "homelab", "message-allowlist")
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

// parseAllowlist extracts permitted recipient titles from a file body: one exact
// WhatsApp contact title per line, `#` comments and blank lines ignored.
func parseAllowlist(body string) []string {
	var out []string
	for _, ln := range strings.Split(body, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		out = append(out, ln)
	}
	return out
}

// loadAllowlist reads + parses the allowlist file. A missing file yields an empty
// list (send fails closed), not an error.
func loadAllowlist(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return parseAllowlist(string(b)), nil
}

// resolveRecipient maps a fuzzy --to onto exactly one allowlisted title.
// Precedence: exact (case-insensitive) → unique case-insensitive substring.
// Returns candidates (for a helpful message) when the match is ambiguous.
func resolveRecipient(to string, allow []string) (match string, candidates []string, err error) {
	to = strings.TrimSpace(to)
	if to == "" {
		return "", nil, fmt.Errorf("no recipient: pass --to <name>")
	}
	if len(allow) == 0 {
		return "", nil, fmt.Errorf("allowlist is empty — add permitted recipients (one exact WhatsApp name per line) to %s", allowlistPath())
	}
	for _, a := range allow {
		if strings.EqualFold(a, to) {
			return a, nil, nil
		}
	}
	lto := strings.ToLower(to)
	var cands []string
	for _, a := range allow {
		if strings.Contains(strings.ToLower(a), lto) {
			cands = append(cands, a)
		}
	}
	switch len(cands) {
	case 0:
		return "", nil, fmt.Errorf("no allowlisted contact matches %q (allowlist: %s)", to, strings.Join(allow, ", "))
	case 1:
		return cands[0], nil, nil
	default:
		return "", cands, fmt.Errorf("%q is ambiguous — matches %d allowlisted contacts: %s", to, len(cands), strings.Join(cands, ", "))
	}
}

// --- audit ----------------------------------------------------------------

type auditRecord struct {
	Time    string `json:"time"`
	Via     string `json:"via"`
	Action  string `json:"action"` // send | dry-run
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
