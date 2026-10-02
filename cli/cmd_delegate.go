package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func delegateCommands() []Command {
	return []Command{
		{Path: []string{"delegate"}, Tier: TierWrite,
			Summary: "hand a task to another Caller (Muse) over WhatsApp and optionally wait: delegate <caller> \"<task>\" [--wait] [--expires 24h]", Run: delegateCreateCmd},
		{Path: []string{"delegate", "status"}, Tier: TierRead,
			Summary: "show one delegation, or wait for its result: delegate status <id> [--wait] [--json]", Run: delegateStatusCmd},
		{Path: []string{"delegate", "list"}, Tier: TierRead,
			Summary: "list delegations: delegate list [--status pending|sent|done|failed|expired|undelivered] [--limit N] [--json]", Run: delegateListCmd},
	}
}

// liveDelegateDeps wires the verb to the real agent-api and the real
// WhatsApp path. The token is read here and lives only in the client.
func liveDelegateDeps() (delegateDeps, error) {
	tok, err := readAgentAPIToken(agentAPITokenPath())
	if err != nil {
		return delegateDeps{}, err
	}
	return delegateDeps{
		api: &httpDelegationAPI{
			base:  agentAPIURL(),
			token: tok,
			// Above the 300 s server-side wait, so a long poll ends on the
			// server's answer rather than on this client's clock.
			client: &http.Client{Timeout: (delegateWaitSeconds + 30) * time.Second},
		},
		send:         whatsappDelegationSend,
		contactsPath: delegateContactsPath(),
		allowPath:    allowlistPath(),
		out:          os.Stdout,
		sleep:        time.Sleep,
		now:          time.Now,
	}, nil
}

// whatsappDelegationSend is `homelab message send` without the confirm
// prompt: same automation, same wrong-recipient guard in message_wa.js, same
// audit log (action "delegate"). The automation's stderr is kept so the
// failure can be named on the delegation.
func whatsappDelegationSend(chat, text string) error {
	var stderr bytes.Buffer
	if err := sendMessageAs("wa", chat, text, "delegate", &stderr); err != nil {
		return &sendError{reason: classifySendFailure(chat, stderr.String(), err)}
	}
	return nil
}

// currentSessionName names the delegating session for the message Muse sees.
// Lobby sessions are tmux sessions, so the tmux session name is the one Viktor
// recognises in the sidebar.
func currentSessionName() string {
	if os.Getenv("TMUX") == "" {
		return ""
	}
	out, err := exec.Command("tmux", "display-message", "-p", "#S").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func delegateCreateCmd(args []string) error {
	o, err := parseDelegateArgs(args)
	if err != nil {
		return err
	}
	if o.help {
		fmt.Print(delegateHelp())
		return nil
	}
	if o.from == "" {
		o.from = currentSessionName()
	}
	deps, err := liveDelegateDeps()
	if err != nil {
		return err
	}
	return runDelegate(o, deps)
}

func delegateStatusCmd(args []string) error {
	var id string
	var wait, asJSON bool
	for _, a := range args {
		if a == "-" || !strings.HasPrefix(a, "-") {
			if id != "" {
				return fmt.Errorf("delegate status takes one id")
			}
			id = a
			continue
		}
		switch name, _, _ := flagToken(a); name {
		case "h", "help":
			fmt.Print(delegateHelp())
			return nil
		case "wait":
			wait = true
		case "json":
			asJSON = true
		default:
			return fmt.Errorf("unknown flag %q (try: homelab delegate --help)", a)
		}
	}
	if id == "" {
		return fmt.Errorf("usage: homelab delegate status <id> [--wait] [--json]")
	}
	deps, err := liveDelegateDeps()
	if err != nil {
		return err
	}
	if wait && !asJSON {
		return waitDelegation(id, deps)
	}
	w := 0
	if wait {
		w = delegateWaitSeconds
	}
	d, err := deps.api.Get(id, w)
	if err != nil {
		return err
	}
	if asJSON {
		return printJSON(d)
	}
	printDelegation(os.Stdout, d)
	return nil
}

func delegateListCmd(args []string) error {
	var status string
	limit := 0
	asJSON := false
	for i := 0; i < len(args); i++ {
		a := args[i]
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
			fmt.Print(delegateHelp())
			return nil
		case "json":
			asJSON = true
		case "status":
			v, err := takeVal()
			if err != nil {
				return err
			}
			status = v
		case "limit":
			v, err := takeVal()
			if err != nil {
				return err
			}
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 {
				return fmt.Errorf("--limit expects a positive integer, got %q", v)
			}
			limit = n
		default:
			return fmt.Errorf("unexpected argument %q (try: homelab delegate --help)", a)
		}
	}
	deps, err := liveDelegateDeps()
	if err != nil {
		return err
	}
	ds, err := deps.api.List(status, limit)
	if err != nil {
		return err
	}
	if asJSON {
		return printJSON(map[string]any{"delegations": ds})
	}
	if len(ds) == 0 {
		fmt.Println("no delegations")
		return nil
	}
	for _, d := range ds {
		task := []rune(strings.Join(strings.Fields(d.Task), " "))
		if len(task) > 60 {
			task = append(task[:60], '…')
		}
		fmt.Printf("%-30s  %-11s  %-8s  %-20s  %s\n", d.ID, d.Status, d.Caller, d.CreatedAt, string(task))
	}
	return nil
}

func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

func delegateHelp() string {
	return `homelab delegate — hand a task to another Caller of agent-api (Muse first)

USAGE
  homelab delegate <caller> "<task>" [--wait] [--expires 24h] [--from <session>]
  homelab delegate status <id> [--wait] [--json]
  homelab delegate list [--status S] [--limit N] [--json]

WHAT IT DOES
  Records the delegation in agent-api as the local "homelab" Caller, then sends
  the text agent-api rendered (the task plus where to post the result) to that
  Caller's WhatsApp chat through the same path as 'homelab message send'. The
  Caller posts its result back to /v1/delegations/<id>/result. --wait follows
  the delegation until it is done, failed, expired or undelivered, and prints
  the result. Exit status is zero only for done.

  --expires   how long the Caller has: Go durations or whole days (90m, 24h,
              3d); default 24h, maximum 14d. A late result is refused.
  --from      the session name shown to the Caller; defaults to this tmux
              session's name.

SAFETY
  This is the one unattended send 'homelab message' permits, and only to the
  chat pinned for that Caller in BOTH files below; otherwise it refuses before
  anything is recorded:
      ` + delegateContactsPath() + `   (lines: muse=<exact WhatsApp chat name>)
      ` + allowlistPath() + `   (the same exact name)
  The chat is verified on screen before typing, and every send is in the
  message audit log (action "delegate"):
      ` + auditPath() + `
  agent-api caps each Caller at 20 delegations an hour and 100 a day.

  If the send fails, the delegation closes as undelivered, this exits non-zero
  with the reason, and #alerts gets one post. A logged-out WhatsApp Web is the
  usual cause: re-link it at chrome.viktorbarzin.me (noVNC, scan the QR code).

  "status" and "list" are subcommands, so no Caller can be named either.
  Runbook: docs/runbooks/delegations.md
`
}
