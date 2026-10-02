package main

// homelab delegate hands a task to another Caller of agent-api (Muse first)
// and, optionally, waits for its result. Design:
// docs/plans/2026-10-02-muse-homelab-integration-design.md, "Homelab to Muse".
//
// The flow, in the order the contract fixes:
//
//  1. Refuse before anything is recorded unless the target Caller has a chat
//     in delegate-contacts AND that exact chat is on the message allowlist.
//     A refusal here leaves no pending delegation behind to expire unseen.
//  2. POST /v1/delegations as the local `homelab` Caller. agent-api renders
//     the WhatsApp text, callback instructions included, so the CLI never
//     builds or edits it.
//  3. Send that text through the same path `homelab message send` uses
//     (allowlist, wrong-recipient guard, audit log). This is the one
//     unattended send that path permits: no confirm prompt, because the
//     recipient is pinned by two files a human wrote, not chosen per call.
//  4. POST /sent, or on any send failure POST /undelivered with a one-line
//     reason and exit non-zero. agent-api traces the undelivered event and
//     the Loki rule posts it to #alerts.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	// The agent-api loopback listener. The public endpoint would work too,
	// but this box is where the CLI runs and loopback needs no allowlist.
	defaultAgentAPIURL = "http://127.0.0.1:8710"
	// Server-side caps from the contract, mirrored so a bad value fails here
	// with a clear message instead of a 400.
	delegateMaxTaskChars = 8000
	delegateMaxExpiry    = 14 * 24 * time.Hour
	delegateMinExpiry    = time.Minute
	// agent-api holds a ?wait= request at most 300 s; the Traefik transport
	// in front of the public route allows 330 s, and so does this client.
	delegateWaitSeconds = 300
	// Consecutive transport errors the wait loop rides out before giving up.
	// agent-api restarts with the lobby services, which takes seconds.
	delegateMaxWaitErrors = 5
	// How long past expires_at the wait loop keeps trusting a non-final
	// status. agent-api expires lazily on read, so a correct server never
	// reaches this; it bounds the loop against one that does not.
	delegateExpiryGrace = 2 * time.Minute
)

// delegation is the contract's Delegation object.
type delegation struct {
	ID          string `json:"delegation_id"`
	Caller      string `json:"caller"`
	CreatedBy   string `json:"created_by,omitempty"`
	FromSession string `json:"from_session,omitempty"`
	Task        string `json:"task,omitempty"`
	Status      string `json:"status"`
	Result      string `json:"result,omitempty"`
	Reason      string `json:"reason,omitempty"`
	Message     string `json:"message,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
	ExpiresAt   string `json:"expires_at,omitempty"`
}

// final reports whether the status can no longer change.
func (d delegation) final() bool {
	switch d.Status {
	case "done", "failed", "expired", "undelivered":
		return true
	}
	return false
}

// delegationCreate is the POST /v1/delegations body. A zero ExpiresInS is
// omitted so agent-api applies its own default (24 h).
type delegationCreate struct {
	Caller      string `json:"caller"`
	Task        string `json:"task"`
	FromSession string `json:"from_session,omitempty"`
	ExpiresInS  int    `json:"expires_in_s,omitempty"`
}

// delegationAPI is the slice of agent-api the verb uses. The tests swap in a
// fake; the real one is httpDelegationAPI.
type delegationAPI interface {
	Create(delegationCreate) (delegation, error)
	MarkSent(id string) (delegation, error)
	MarkUndelivered(id, reason string) (delegation, error)
	Get(id string, wait int) (delegation, error)
	List(status string, limit int) ([]delegation, error)
}

// apiError is a non-2xx answer from agent-api, kept typed so callers can tell
// a cap (429) or a missing delegation (404) from a transport failure.
type apiError struct {
	status     int
	msg        string
	retryAfter int // seconds, from Retry-After on a 429
}

func (e *apiError) Error() string {
	return fmt.Sprintf("agent-api answered %d: %s", e.status, e.msg)
}

// sendError carries the one-line reason a WhatsApp send failed, already
// phrased as what to do about it.
type sendError struct{ reason string }

func (e *sendError) Error() string { return e.reason }

type httpDelegationAPI struct {
	base   string
	token  string
	client *http.Client
}

func (a *httpDelegationAPI) do(method, path string, body any) ([]byte, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, strings.TrimRight(a.base, "/")+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		ae := &apiError{status: resp.StatusCode, msg: strings.TrimSpace(string(out))}
		var e struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(out, &e) == nil && e.Error != "" {
			ae.msg = e.Error
		}
		if ra, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil {
			ae.retryAfter = ra
		}
		return nil, ae
	}
	return out, nil
}

func (a *httpDelegationAPI) one(method, path string, body any) (delegation, error) {
	out, err := a.do(method, path, body)
	if err != nil {
		return delegation{}, err
	}
	var d delegation
	if err := json.Unmarshal(out, &d); err != nil {
		return delegation{}, fmt.Errorf("agent-api returned something that is not a delegation: %w", err)
	}
	return d, nil
}

func (a *httpDelegationAPI) Create(c delegationCreate) (delegation, error) {
	return a.one("POST", "/v1/delegations", c)
}

func (a *httpDelegationAPI) MarkSent(id string) (delegation, error) {
	return a.one("POST", "/v1/delegations/"+url.PathEscape(id)+"/sent", nil)
}

func (a *httpDelegationAPI) MarkUndelivered(id, reason string) (delegation, error) {
	return a.one("POST", "/v1/delegations/"+url.PathEscape(id)+"/undelivered", map[string]string{"reason": reason})
}

func (a *httpDelegationAPI) Get(id string, wait int) (delegation, error) {
	p := "/v1/delegations/" + url.PathEscape(id)
	if wait > 0 {
		p += "?wait=" + strconv.Itoa(wait)
	}
	return a.one("GET", p, nil)
}

func (a *httpDelegationAPI) List(status string, limit int) ([]delegation, error) {
	q := url.Values{}
	if status != "" {
		q.Set("status", status)
	}
	if limit > 0 {
		q.Set("limit", strconv.Itoa(limit))
	}
	p := "/v1/delegations"
	if len(q) > 0 {
		p += "?" + q.Encode()
	}
	out, err := a.do("GET", p, nil)
	if err != nil {
		return nil, err
	}
	var r struct {
		Delegations []delegation `json:"delegations"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, fmt.Errorf("agent-api list: %w", err)
	}
	return r.Delegations, nil
}

// --- configuration --------------------------------------------------------

func delegateContactsPath() string {
	if v := os.Getenv("HOMELAB_DELEGATE_CONTACTS"); v != "" {
		return v
	}
	return filepath.Join(configHome(), "homelab", "delegate-contacts")
}

// agentAPITokenPath is where playbooks/devvm.yml installs the `homelab`
// Caller's bearer token, 0600 and owned by wizard.
func agentAPITokenPath() string {
	if v := os.Getenv("HOMELAB_AGENT_API_TOKEN_FILE"); v != "" {
		return v
	}
	return filepath.Join(configHome(), "homelab", "agent-api-token")
}

func agentAPIURL() string {
	if v := os.Getenv("HOMELAB_AGENT_API_URL"); v != "" {
		return v
	}
	return defaultAgentAPIURL
}

// readAgentAPIToken returns the token, never printing it. A missing file
// almost always means the playbook has not run since the Caller was added.
func readAgentAPIToken(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("no agent-api token at %s: the devvm playbook installs it from Vault secret/terminal-lobby agent_api_homelab_token", path)
		}
		return "", fmt.Errorf("read agent-api token: %w", err)
	}
	tok := strings.TrimSpace(string(b))
	if tok == "" {
		return "", fmt.Errorf("agent-api token file %s is empty: re-run the devvm playbook", path)
	}
	return tok, nil
}

// parseDelegateContacts reads `caller=<exact WhatsApp chat name>` lines.
// Only the first `=` splits, since a chat name may contain one; blank lines,
// `#` comments and lines without `=` are skipped.
func parseDelegateContacts(body string) map[string]string {
	out := map[string]string{}
	for _, ln := range strings.Split(body, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		k, v, ok := strings.Cut(ln, "=")
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if !ok || k == "" || v == "" {
			continue
		}
		out[k] = v
	}
	return out
}

// delegateChat resolves the chat a delegation to caller may go to. Both files
// must agree, and the match against the allowlist is exact: the fuzzy --to
// matching `message send` offers a human has no place in an unattended send.
func delegateChat(caller, contactsPath, allowPath string) (string, error) {
	var contacts map[string]string
	b, err := os.ReadFile(contactsPath)
	switch {
	case err == nil:
		contacts = parseDelegateContacts(string(b))
	case os.IsNotExist(err):
	default:
		return "", fmt.Errorf("read %s: %w", contactsPath, err)
	}
	chat, ok := contacts[caller]
	if !ok {
		return "", fmt.Errorf("no WhatsApp chat configured for caller %q: add a line %s=<exact chat name> to %s", caller, caller, contactsPath)
	}
	allow, err := loadAllowlist(allowPath)
	if err != nil {
		return "", fmt.Errorf("read allowlist %s: %w", allowPath, err)
	}
	if !slices.Contains(allow, chat) {
		return "", fmt.Errorf("chat %q for caller %q is not on the message allowlist: add that exact line to %s", chat, caller, allowPath)
	}
	return chat, nil
}

// parseDelegateExpiry turns --expires into seconds. It takes Go durations
// plus a whole-day `Nd` form, since delegations are measured in days. Empty
// means unset (0), which leaves the default to agent-api.
func parseDelegateExpiry(s string) (int, error) {
	if s == "" {
		return 0, nil
	}
	var d time.Duration
	if n, ok := strings.CutSuffix(s, "d"); ok {
		days, err := strconv.Atoi(n)
		if err != nil {
			return 0, fmt.Errorf("--expires %q: want a duration like 24h, 90m or 3d", s)
		}
		d = time.Duration(days) * 24 * time.Hour
	} else {
		var err error
		if d, err = time.ParseDuration(s); err != nil {
			return 0, fmt.Errorf("--expires %q: want a duration like 24h, 90m or 3d", s)
		}
	}
	if d < delegateMinExpiry {
		return 0, fmt.Errorf("--expires %q: must be at least 1m", s)
	}
	if d > delegateMaxExpiry {
		return 0, fmt.Errorf("--expires %q: the maximum is 14d", s)
	}
	return int(d / time.Second), nil
}

// --- the flow -------------------------------------------------------------

type delegateOpts struct {
	caller    string
	task      string
	from      string
	expiresIn int
	wait      bool
	help      bool
}

func parseDelegateArgs(args []string) (delegateOpts, error) {
	var o delegateOpts
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-" || !strings.HasPrefix(a, "-") {
			pos = append(pos, a)
			continue
		}
		name, val, hasVal := flagToken(a)
		takeVal := func() (string, error) {
			if hasVal {
				return val, nil
			}
			if i+1 >= len(args) {
				return "", fmt.Errorf("--%s expects a value", name)
			}
			i++
			return args[i], nil
		}
		switch name {
		case "h", "help":
			o.help = true
		case "wait":
			o.wait = true
		case "expires":
			v, err := takeVal()
			if err != nil {
				return o, err
			}
			if o.expiresIn, err = parseDelegateExpiry(v); err != nil {
				return o, err
			}
		case "from":
			v, err := takeVal()
			if err != nil {
				return o, err
			}
			o.from = v
		default:
			return o, fmt.Errorf("unknown flag %q (try: homelab delegate --help)", a)
		}
	}
	if o.help {
		return o, nil
	}
	if len(pos) == 0 {
		return o, fmt.Errorf("usage: homelab delegate <caller> \"<task>\" [--wait] [--expires 24h]")
	}
	o.caller = pos[0]
	o.task = strings.TrimSpace(strings.Join(pos[1:], " "))
	if o.task == "" {
		return o, fmt.Errorf("no task: homelab delegate %s \"<what you want done>\"", o.caller)
	}
	if n := len([]rune(o.task)); n > delegateMaxTaskChars {
		return o, fmt.Errorf("task is %d characters; the limit is %d", n, delegateMaxTaskChars)
	}
	return o, nil
}

type delegateDeps struct {
	api          delegationAPI
	send         func(chat, text string) error
	contactsPath string
	allowPath    string
	out          io.Writer
	sleep        func(time.Duration)
	now          func() time.Time
}

func runDelegate(o delegateOpts, deps delegateDeps) error {
	chat, err := delegateChat(o.caller, deps.contactsPath, deps.allowPath)
	if err != nil {
		return err
	}
	d, err := deps.api.Create(delegationCreate{
		Caller: o.caller, Task: o.task, FromSession: o.from, ExpiresInS: o.expiresIn,
	})
	if err != nil {
		var ae *apiError
		if errors.As(err, &ae) && ae.status == http.StatusTooManyRequests {
			return fmt.Errorf("delegation cap reached for %s (%s); retry in %s", o.caller, ae.msg,
				(time.Duration(ae.retryAfter) * time.Second).String())
		}
		return fmt.Errorf("create delegation: %w", err)
	}
	if d.Message == "" {
		// Sending a blank or self-made message would hand Muse a task with no
		// callback address; better to close it now than to guess.
		_, _ = deps.api.MarkUndelivered(d.ID, "agent-api returned no message text")
		return fmt.Errorf("delegation %s: agent-api returned no message text; closed as undelivered", d.ID)
	}

	if serr := deps.send(chat, d.Message); serr != nil {
		reason := oneLine(serr.Error())
		if _, uerr := deps.api.MarkUndelivered(d.ID, reason); uerr != nil {
			return fmt.Errorf("delegation %s undelivered: %s (recording that failed too: %s; it will expire at %s)",
				d.ID, reason, oneLine(uerr.Error()), d.ExpiresAt)
		}
		return fmt.Errorf("delegation %s undelivered: %s", d.ID, reason)
	}

	if _, err := deps.api.MarkSent(d.ID); err != nil {
		// The message is out and Muse may post a result against a pending
		// delegation, so this is worth saying but not worth failing over.
		fmt.Fprintf(deps.out, "warning: sent, but marking %s sent failed: %s\n", d.ID, oneLine(err.Error()))
	}
	fmt.Fprintf(deps.out, "delegation %s sent to %s (WhatsApp chat %q), expires %s\n", d.ID, o.caller, chat, d.ExpiresAt)
	if !o.wait {
		fmt.Fprintf(deps.out, "follow it: homelab delegate status %s --wait\n", d.ID)
		return nil
	}
	return waitDelegation(d.ID, deps)
}

// waitDelegation long-polls until the delegation reaches a final status and
// prints it. done exits zero; failed, expired and undelivered do not, so a
// script can branch on the exit code.
func waitDelegation(id string, deps delegateDeps) error {
	errs := 0
	for {
		d, err := deps.api.Get(id, delegateWaitSeconds)
		if err != nil {
			var ae *apiError
			if errors.As(err, &ae) && ae.status/100 == 4 {
				return fmt.Errorf("delegation %s: %w", id, err)
			}
			errs++
			if errs >= delegateMaxWaitErrors {
				return fmt.Errorf("delegation %s: gave up waiting after %d errors in a row: %w", id, errs, err)
			}
			deps.sleep(time.Duration(errs) * 5 * time.Second)
			continue
		}
		errs = 0
		if d.final() {
			printDelegation(deps.out, d)
			if d.Status == "done" {
				return nil
			}
			return finalError(d)
		}
		if exp, err := time.Parse(time.RFC3339, d.ExpiresAt); err == nil && deps.now().After(exp.Add(delegateExpiryGrace)) {
			return fmt.Errorf("delegation %s is still %q past its expiry (%s); agent-api should have expired it", id, d.Status, d.ExpiresAt)
		}
		// A server that answers ?wait at once instead of holding the request
		// would otherwise turn this loop into a busy one.
		deps.sleep(time.Second)
	}
}

func finalError(d delegation) error {
	switch d.Status {
	case "undelivered":
		return fmt.Errorf("delegation %s undelivered: %s", d.ID, d.Reason)
	case "expired":
		return fmt.Errorf("delegation %s expired at %s without a result", d.ID, d.ExpiresAt)
	default:
		return fmt.Errorf("delegation %s %s", d.ID, d.Status)
	}
}

func printDelegation(w io.Writer, d delegation) {
	fmt.Fprintf(w, "%s  %s  caller=%s", d.ID, d.Status, d.Caller)
	if d.FromSession != "" {
		fmt.Fprintf(w, "  from=%s", d.FromSession)
	}
	fmt.Fprintln(w)
	for _, kv := range [][2]string{{"created", d.CreatedAt}, {"updated", d.UpdatedAt}, {"expires", d.ExpiresAt}} {
		if kv[1] != "" {
			fmt.Fprintf(w, "  %s: %s\n", kv[0], kv[1])
		}
	}
	if d.Task != "" {
		fmt.Fprintf(w, "task:\n%s\n", indent(strings.TrimRight(d.Task, "\n"), "  "))
	}
	if d.Reason != "" {
		fmt.Fprintf(w, "reason: %s\n", d.Reason)
	}
	if d.Result != "" {
		fmt.Fprintf(w, "result:\n%s\n", indent(strings.TrimRight(d.Result, "\n"), "  "))
	}
}

// oneLine collapses an error to a single line of at most 300 characters, the
// shape the undelivered reason and the #alerts post both want.
func oneLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 300 {
		s = string(r[:300]) + "…"
	}
	return s
}

// classifySendFailure turns what the WhatsApp automation printed into the
// reason recorded on the delegation: what broke, phrased as what to do.
func classifySendFailure(chat, stderr string, err error) string {
	low := strings.ToLower(stderr)
	switch {
	case strings.Contains(low, "not logged in"):
		return "WhatsApp Web is logged out in the shared browser; re-link at chrome.viktorbarzin.me (noVNC, scan the QR code with the phone)"
	case strings.Contains(low, "contact not found in whatsapp"):
		return oneLine(fmt.Sprintf("chat %q not found in WhatsApp; fix the name in %s and on the message allowlist", chat, delegateContactsPath()))
	case strings.Contains(low, "recipient verification failed"):
		return oneLine(fmt.Sprintf("recipient verification failed: the chat that opened was not %q, so nothing was typed", chat))
	case strings.Contains(low, "chrome-service") || strings.Contains(low, "cdp not ready"):
		return oneLine("the shared browser (chrome-service) is unreachable: " + lastLine(stderr))
	}
	detail := lastLine(stderr)
	if detail == "" && err != nil {
		detail = err.Error()
	}
	return oneLine("WhatsApp send failed: " + detail)
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return ""
}
