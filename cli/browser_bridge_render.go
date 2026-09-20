package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	bb "github.com/ViktorBarzin/browser-bridge/client"
)

// Human output for `homelab browser bridge`. Every renderer is a pure
// function from a decoded result to a string, so the shapes are testable
// without a server, and `--json` skips all of it and prints the raw result.

// Column widths for the tabs table. A tab list an agent cannot read at a
// glance is a tab list it will re-fetch as JSON and parse, which is slower
// for everyone.
const (
	bridgeTitleWidth = 38
	bridgeURLWidth   = 52
)

// bridgeDecode reads one typed result out of the raw JSON the browser sent.
func bridgeDecode[T any](raw json.RawMessage) (*T, error) {
	var out T
	if len(raw) == 0 {
		return &out, nil
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("the browser's result is not the shape this client expects, %w", err)
	}
	return &out, nil
}

// renderBridgeResult turns one action's result into the line a human reads.
func renderBridgeResult(o bridgeOpts, raw json.RawMessage) (string, error) {
	switch o.cmd {
	case "open":
		r, err := bridgeDecode[bb.OpenResult](raw)
		if err != nil {
			return "", err
		}
		parts := []string{r.Tab}
		if r.StatusCode != 0 {
			parts = append(parts, strconv.Itoa(r.StatusCode))
		}
		parts = append(parts, fmt.Sprintf("%dms", r.LoadMs), r.URL, r.Title)
		return strings.Join(parts, "  "), nil

	case "back", "forward":
		r, err := bridgeDecode[bb.NavResult](raw)
		if err != nil {
			return "", err
		}
		return r.URL + "  " + r.Title, nil

	case "reload":
		r, err := bridgeDecode[bb.ReloadResult](raw)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("reloaded in %dms  %s  %s", r.LoadMs, r.URL, r.Title), nil

	case "url":
		r, err := bridgeDecode[bb.URLResult](raw)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%s  %s  (origin %s, readyState %s)", r.URL, r.Title, r.Origin, r.ReadyState), nil

	case "read-text":
		r, err := bridgeDecode[bb.ReadTextResult](raw)
		if err != nil {
			return "", err
		}
		if r.Truncated {
			return r.Text + "\n\n(truncated: re-run with --max, or a narrower selector)", nil
		}
		return r.Text, nil

	case "read-html":
		r, err := bridgeDecode[bb.ReadHTMLResult](raw)
		if err != nil {
			return "", err
		}
		if r.Truncated {
			return r.HTML + "\n\n(truncated: re-run with a narrower selector)", nil
		}
		return r.HTML, nil

	case "query":
		r, err := bridgeDecode[bb.QueryResult](raw)
		if err != nil {
			return "", err
		}
		return renderQueryResult(r), nil

	case "eval":
		r, err := bridgeDecode[bb.EvalResult](raw)
		if err != nil {
			return "", err
		}
		if len(r.Value) == 0 {
			return "(" + r.Type + ")", nil
		}
		return string(r.Value), nil

	case "screenshot":
		r, err := bridgeDecode[bb.ScreenshotResult](raw)
		if err != nil {
			return "", err
		}
		path := o.output
		if path == "" {
			path = bridgeDefaultShot
		}
		return fmt.Sprintf("wrote %s  %dx%d  %d bytes", path, r.Width, r.Height, r.Bytes), nil

	case "click":
		r, err := bridgeDecode[bb.ClickResult](raw)
		if err != nil {
			return "", err
		}
		what := r.Selector
		if what == "" {
			what = o.at
		}
		if !r.Clicked {
			return "did not click " + what, nil
		}
		return "clicked " + what, nil

	case "type":
		r, err := bridgeDecode[bb.TypeResult](raw)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("typed %d characters into %s", r.Chars, o.arg(0)), nil

	case "fill":
		r, err := bridgeDecode[bb.FillResult](raw)
		if err != nil {
			return "", err
		}
		return renderFillResult(r), nil

	case "select":
		r, err := bridgeDecode[bb.SelectResult](raw)
		if err != nil {
			return "", err
		}
		out := fmt.Sprintf("selected %q", r.Selected)
		if r.Selected == "" && len(r.Options) > 0 {
			out = "selected nothing; the element offers: " + strings.Join(r.Options, ", ")
		}
		return out, nil

	case "press":
		r, err := bridgeDecode[bb.PressResult](raw)
		if err != nil {
			return "", err
		}
		if !r.Pressed {
			return "did not press " + o.arg(0), nil
		}
		return "pressed " + o.arg(0), nil

	case "hover":
		r, err := bridgeDecode[bb.HoverResult](raw)
		if err != nil {
			return "", err
		}
		if !r.Hovered {
			return "did not hover " + o.arg(0), nil
		}
		return "hovered " + o.arg(0), nil

	case "scroll":
		r, err := bridgeDecode[bb.ScrollResult](raw)
		if err != nil {
			return "", err
		}
		out := fmt.Sprintf("scrolled to %.0f,%.0f", r.ScrollX, r.ScrollY)
		if r.AtBottom {
			out += " (at the bottom of the page)"
		}
		return out, nil

	case "dialog":
		r, err := bridgeDecode[bb.DialogResult](raw)
		if err != nil {
			return "", err
		}
		verb := "dismissed"
		if o.arg(0) == "accept" {
			verb = "accepted"
		}
		if !r.Handled {
			return "no dialog was open", nil
		}
		out := verb + " the " + r.DialogType + " dialog"
		if r.Message != "" {
			out += fmt.Sprintf(": %q", r.Message)
		}
		return out, nil

	case "wait-for":
		r, err := bridgeDecode[bb.WaitForResult](raw)
		if err != nil {
			return "", err
		}
		if !r.Matched {
			return fmt.Sprintf("no match after %dms (waiting for %s)", r.WaitedMs, r.What), nil
		}
		return fmt.Sprintf("matched %s in %dms", r.What, r.WaitedMs), nil

	case "console":
		r, err := bridgeDecode[bb.ConsoleResult](raw)
		if err != nil {
			return "", err
		}
		return renderConsoleResult(r, o.countOnly), nil

	case "network":
		r, err := bridgeDecode[bb.NetworkResult](raw)
		if err != nil {
			return "", err
		}
		return renderNetworkResult(r, o.body), nil

	case "emulate":
		r, err := bridgeDecode[bb.EmulateResult](raw)
		if err != nil {
			return "", err
		}
		return renderEmulateResult(r), nil

	case "tabs":
		r, err := bridgeDecode[bb.TabListResult](raw)
		if err != nil {
			return "", err
		}
		return renderTabList(r), nil

	case "attach":
		r, err := bridgeDecode[bb.AttachResult](raw)
		if err != nil {
			return "", err
		}
		note := "a tab an agent opened"
		if r.Owner == bb.OwnerUser {
			note = "you opened this tab"
		}
		if r.BannerShown {
			note += "; Chrome is showing its debugging banner, which stays up until detach"
		}
		return fmt.Sprintf("attached %s  %s  %s  (%s)", r.Tab, r.Title, r.Origin, note), nil

	case "detach":
		r, err := bridgeDecode[bb.DetachResult](raw)
		if err != nil {
			return "", err
		}
		if !r.WasAttached {
			return "nothing to detach for " + r.Tab, nil
		}
		out := "detached " + r.Tab
		if len(r.ClearedOverrides) > 0 {
			out += ", cleared " + strings.Join(r.ClearedOverrides, ", ")
		}
		out += ". What the agent typed into the page stays where it is."
		return out, nil

	case "activate":
		r, err := bridgeDecode[bb.ActivateResult](raw)
		if err != nil {
			return "", err
		}
		out := fmt.Sprintf("activated %s in window %d", r.Tab, r.WindowID)
		if !r.Focused {
			out += " (the window did not take focus)"
		}
		return out, nil

	case "close-tab":
		r, err := bridgeDecode[bb.CloseTabResult](raw)
		if err != nil {
			return "", err
		}
		if !r.Closed {
			return "did not close " + r.Tab, nil
		}
		if r.Owner == bb.OwnerUser {
			return "closed " + r.Tab + " (you opened it, not an agent)", nil
		}
		return "closed " + r.Tab, nil

	case "ping":
		r, err := bridgeDecode[bb.PingResult](raw)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("round trip %dms  extension %s  queue %d  %s",
			r.RoundTripMs, r.ExtensionVersion, r.QueueDepth,
			bridgePlural(r.AttachedTabs, "attached tab")), nil
	}
	return string(raw), nil
}

func renderQueryResult(r *bb.QueryResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", bridgePlural(r.Count, "match"))
	for _, m := range r.Matches {
		visible := "hidden"
		if m.Visible {
			visible = "visible"
		}
		fmt.Fprintf(&b, "[%d] %s  %q  %s", m.Index, m.Tag, bridgeTrunc(m.Text, 60), visible)
		if len(m.Attrs) > 0 {
			keys := make([]string, 0, len(m.Attrs))
			for k := range m.Attrs {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			pairs := make([]string, 0, len(keys))
			for _, k := range keys {
				pairs = append(pairs, k+"="+m.Attrs[k])
			}
			fmt.Fprintf(&b, "  %s", strings.Join(pairs, " "))
		}
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func renderFillResult(r *bb.FillResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "filled %s", bridgePlural(r.Filled, "field"))
	if len(r.Failed) > 0 {
		fmt.Fprintf(&b, ", %d failed:", len(r.Failed))
		for _, f := range r.Failed {
			fmt.Fprintf(&b, "\n  %s  %s", f.Selector, f.Code)
			if f.Message != "" {
				fmt.Fprintf(&b, "  %s", f.Message)
			}
		}
	}
	return b.String()
}

func renderConsoleResult(r *bb.ConsoleResult, countOnly bool) string {
	if countOnly || len(r.Entries) == 0 {
		return bridgePlural(r.Count, "console entry")
	}
	var b strings.Builder
	for _, e := range r.Entries {
		fmt.Fprintf(&b, "[%s] %s  %s", e.Level, bridgeClock(e.At), e.Text)
		if e.Source != "" {
			fmt.Fprintf(&b, "  (%s:%d)", e.Source, e.Line)
		}
		b.WriteString("\n")
	}
	fmt.Fprintf(&b, "%s captured since the tab was attached", bridgePlural(r.Count, "console entry"))
	return b.String()
}

func renderNetworkResult(r *bb.NetworkResult, bodyPath string) string {
	if r.Request != nil {
		var b strings.Builder
		q := r.Request
		fmt.Fprintf(&b, "%d  %s  %d  %s  %s  %dms\n%s\n",
			q.ID, q.Method, q.Status, q.Type, bridgeBytes(q.Bytes), q.Ms, q.URL)
		if q.MimeType != "" {
			fmt.Fprintf(&b, "mime %s\n", q.MimeType)
		}
		b.WriteString(bridgeHeaderBlock("request headers", q.RequestHeaders))
		b.WriteString(bridgeHeaderBlock("response headers", q.ResponseHeaders))
		if q.PostData != "" {
			fmt.Fprintf(&b, "post data:\n  %s\n", bridgeTrunc(q.PostData, 2000))
		}
		if bodyPath != "" && r.ResponseBlobID != "" {
			fmt.Fprintf(&b, "body written to %s\n", bodyPath)
		}
		return strings.TrimRight(b.String(), "\n")
	}

	var b strings.Builder
	for _, q := range r.Requests {
		fmt.Fprintf(&b, "%-4d %-6s %-4d %-10s %8s %6dms  %s\n",
			q.ID, q.Method, q.Status, q.Type, bridgeBytes(q.Bytes), q.Ms, bridgeTrunc(q.URL, 80))
	}
	fmt.Fprintf(&b, "%s captured since the tab was attached", bridgePlural(r.Count, "request"))
	return b.String()
}

func renderEmulateResult(r *bb.EmulateResult) string {
	var parts []string
	if len(r.Applied) > 0 {
		parts = append(parts, "applied "+strings.Join(r.Applied, ", "))
	}
	if len(r.Cleared) > 0 {
		parts = append(parts, "cleared "+strings.Join(r.Cleared, ", "))
	}
	if len(parts) == 0 {
		return "nothing to apply"
	}
	return strings.Join(parts, "; ") +
		"\nThese die with the debugger session: detach, stop or the idle detach clears them."
}

// renderTabList is the first thing an agent runs, so it has to answer "what
// is open and which of it is the human's" without a second command.
func renderTabList(r *bb.TabListResult) string {
	tabs := make([]bb.TabInfo, len(r.Tabs))
	copy(tabs, r.Tabs)
	sort.SliceStable(tabs, func(i, j int) bool {
		a, b := tabs[i], tabs[j]
		if (a.State == bb.TabClosed) != (b.State == bb.TabClosed) {
			return b.State == bb.TabClosed
		}
		if a.WindowID != b.WindowID {
			return a.WindowID < b.WindowID
		}
		return a.Index < b.Index
	})

	closed, attached := 0, 0
	for _, t := range tabs {
		if t.State == bb.TabClosed {
			closed++
		}
		if t.Attached {
			attached++
		}
	}

	var b strings.Builder
	// The count is the rows listed, closed handles included: they stay in the
	// result for an hour and a header that disagrees with the table is worse
	// than one extra clause.
	head := fmt.Sprintf("%s, %s in %s", r.BrowserID,
		bridgePlural(len(tabs), "tab"), bridgePlural(len(r.Windows), "window"))
	if attached > 0 {
		head += fmt.Sprintf(", %d attached", attached)
	}
	if closed > 0 {
		head += fmt.Sprintf(", %d recently closed", closed)
	}
	b.WriteString(head + "\n\n")

	b.WriteString(fmt.Sprintf("%-10s  %-5s  %-*s  %-*s  %s\n",
		"HANDLE", "OWNER", bridgeTitleWidth, "TITLE", bridgeURLWidth, "URL", "NOTES"))
	for _, t := range tabs {
		owner := "agent"
		if t.Owner == bb.OwnerUser {
			owner = "you"
		}
		b.WriteString(strings.TrimRight(fmt.Sprintf("%-10s  %-5s  %-*s  %-*s  %s",
			t.Tab, owner,
			bridgeTitleWidth, bridgePad(bridgeTrunc(t.Title, bridgeTitleWidth), bridgeTitleWidth),
			bridgeURLWidth, bridgePad(bridgeTrunc(t.URL, bridgeURLWidth), bridgeURLWidth),
			strings.Join(bridgeTabNotes(t), ", ")), " ") + "\n")
	}
	if r.Truncated {
		fmt.Fprintf(&b, "\nlisting capped at %d tabs, most recently active first\n", len(tabs))
	}
	b.WriteString("\nowner \"you\" is a tab the human opened. Drive any of them with --tab <handle>;\n")
	b.WriteString("an unattached tab attaches itself on first use, and Chrome says so in a banner.")
	return b.String()
}

func bridgeTabNotes(t bb.TabInfo) []string {
	var notes []string
	if t.State == bb.TabClosed {
		notes = append(notes, "closed")
	}
	if t.Active {
		notes = append(notes, "active")
	}
	switch {
	case t.Attached && t.AttachedBy != "":
		notes = append(notes, "attached by "+bridgeTrunc(t.AttachedBy, 12))
	case t.Attached:
		notes = append(notes, "attached")
	}
	if t.Rebound {
		notes = append(notes, "rebound")
	}
	if t.Discarded {
		notes = append(notes, "discarded")
	}
	if t.Audible {
		notes = append(notes, "audible")
	}
	if t.Group != nil && t.Group.Title != "" {
		notes = append(notes, "group "+t.Group.Title)
	}
	return notes
}

func renderStatusResponse(s *bb.StatusResponse) string {
	var b strings.Builder
	store := "store ok"
	if !s.Server.StoreOk {
		store = "STORE UNAVAILABLE, every action is failing"
	}
	fmt.Fprintf(&b, "server   %s, protocol %d, %s\n", s.Server.Version, s.Server.Protocol, store)
	fmt.Fprintf(&b, "user     %s\n", s.User)

	if s.Browser == nil {
		b.WriteString("browser  no browser enrolled for you\n")
		b.WriteString("         run: homelab browser bridge enrol\n")
		return strings.TrimRight(b.String(), "\n")
	}

	state := "not connected, open Chrome on that machine"
	if s.Browser.Live {
		state = "live"
	}
	if s.Browser.Stopped {
		state += ", STOPPED by the kill switch (resume in the toolbar popup)"
	}
	doing := "idle"
	if s.Browser.CurrentAction != nil && *s.Browser.CurrentAction != "" {
		doing = "running " + *s.Browser.CurrentAction
	}
	fmt.Fprintf(&b, "browser  %s (%s), %s, %s, queue %d",
		s.Browser.Label, s.Browser.BrowserID, state, doing, s.Browser.QueueDepth)
	if s.Browser.ExtensionVersion != "" {
		fmt.Fprintf(&b, ", extension %s", s.Browser.ExtensionVersion)
	}
	b.WriteString("\n")

	if s.Session != nil {
		fmt.Fprintf(&b, "session  %s", s.Session.SessionID)
		if s.Session.CurrentTab != "" {
			fmt.Fprintf(&b, ", current tab %s", s.Session.CurrentTab)
		}
		if s.Session.ExpiresAt > 0 {
			fmt.Fprintf(&b, ", expires %s", bridgeStamp(s.Session.ExpiresAt))
		}
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func renderBrowsersList(browsers []bb.Browser) string {
	if len(browsers) == 0 {
		return "no browsers enrolled.\nrun: homelab browser bridge enrol"
	}
	var b strings.Builder
	for _, br := range browsers {
		var notes []string
		if br.Default {
			notes = append(notes, "default")
		}
		if br.Live {
			notes = append(notes, "live")
		} else {
			notes = append(notes, "offline")
		}
		if br.Stopped {
			notes = append(notes, "stopped")
		}
		if br.QueueDepth > 0 {
			notes = append(notes, fmt.Sprintf("queue %d", br.QueueDepth))
		}
		if br.LastSeenAt > 0 {
			notes = append(notes, "last seen "+bridgeStamp(br.LastSeenAt))
		}
		fmt.Fprintf(&b, "%-24s  %-24s  %s\n", br.BrowserID, br.Label, strings.Join(notes, ", "))
	}
	b.WriteString("\nthe default is what an agent gets when it passes no --browser")
	return b.String()
}

func renderStopResponse(s *bb.StopResponse) string {
	out := fmt.Sprintf("stopped %s, epoch %d, cancelled %s",
		s.BrowserID, s.StopEpoch, bridgePlural(s.Cancelled, "queued action"))
	if !s.BrowserLive {
		return out + ". The browser is not connected, so the stop lands when it reconnects."
	}
	return out + ". Resume from the extension's toolbar popup."
}

func renderPairResponse(p *bb.PairResponse) string {
	var b strings.Builder
	fmt.Fprintf(&b, "pair code %s\n", p.Code)
	if p.ExpiresAt > 0 {
		fmt.Fprintf(&b, "valid until %s, %d attempts left\n", bridgeStamp(p.ExpiresAt), p.AttemptsLeft)
	}
	b.WriteString("\nIn Chrome on that machine, open the browser-bridge popup and type the code.\n")
	b.WriteString("The enrolment ends up owned by you, because the code came from your CLI token.\n")
	return b.String()
}

// bridgeEnrolText is what `enrol` prints. It takes no server round trip, so
// it answers before anything at all is set up.
func bridgeEnrolText(server string) string {
	return `Enrol a Chrome. One command, on the machine that has the browser:

  curl -fsSL ` + server + `/install | sh

It writes Chrome's managed policy, pins the extension id, and tells you to
restart Chrome. On restart the extension installs itself and opens one page:
sign in, read what it grants, press Connect. Nothing else to do.

What Connect grants, in plain words:
  every open tab can be read and driven, the human's own tabs included
  actions run with no per-action approval and no denylist
  the agent sees tab titles and urls, and can close a tab
  Stop is in the toolbar popup, on ` + server + `, and at
    homelab browser bridge stop

A Chrome that cannot reach the sign-in page takes a code instead:
  homelab browser bridge pair

Then check it landed:
  homelab browser bridge status
`
}

// bridgeHelp is the discoverability payload: when this beats the headless
// browser, when it does not, and the three things a human can do about an
// agent driving their Chrome.
func bridgeHelp() string {
	return `homelab browser bridge — drive YOUR OWN Chrome, with your logins

The agent's command goes to a server in the cluster, which pushes it to an
extension in the Chrome a human is sitting at. Every open tab is reachable,
not only tabs the agent opened.

USAGE
  homelab browser bridge <command> [args] [--tab <handle>] [--browser <id>] [--json]

WHEN TO USE THIS, AND WHEN NOT TO
  Use it when the human's own session is the point: a site they are logged in
  to, a half-filled form, a page reached by a POST, an ephemeral session, a
  tab already open on their screen. None of those can be recreated by opening
  a URL in a fresh browser.
  Do NOT use it for anti-bot walls or for anything a clean browser can do.
  That is the cluster's headless Chrome, which needs no human at all:
    homelab browser run <script.js>

START HERE
  homelab browser bridge status            can I drive anything right now
  homelab browser bridge tabs              every open tab, the human's included
  homelab browser bridge open <url>        drive the session's current tab

TABS BELONG TO THE HUMAN
  tabs lists them with owner "you" (they opened it) or "agent" (we did).
  --tab <handle> on any command targets any of them. An unattached tab
  attaches itself on first use, Chrome raises its own debugging banner, the
  tab gets a cursor overlay, and the popup's feed names every action and the
  tab it hit. detach hands a tab back; what was typed into the page stays.

COMMANDS
  navigation   open back forward reload url
  reading      read-text read-html query eval screenshot
  input        click type fill select press hover scroll dialog
  waiting      wait-for
  diagnostics  console network emulate
  tab access   tabs attach detach activate close-tab
  plumbing     status ping stop
  enrolment    enrol pair browsers

GLOBAL FLAGS
  --tab <handle>   any tab in that browser, not only one the agent created
  --browser <id>   which enrolled browser; the default is the one marked
                   default in the web UI, or $BROWSER_BRIDGE_BROWSER
  --timeout <ms>   1000 to 600000
  --session <id>   pin an agent session, for two agents sharing one browser
  --server <url>   override the server, or $BROWSER_BRIDGE_SERVER
  --json           print the raw result object instead of a human line

EXIT CODES
  0 ok   1 the action failed   2 usage   3 no browser connected
  4 the tab could not be resolved   5 stopped   6 server unreachable

THE KILL SWITCH
  homelab browser bridge stop    drops every queued action and detaches every
                                 tab. The toolbar popup has the same button,
                                 and it works with no server round trip.

SETUP
  homelab browser bridge enrol   prints the one command that enrols a Chrome
  Token: ~/.config/browser-bridge/token, mode 0600, one per OS user.
`
}

// bridgeTrunc shortens to n runes, with an ellipsis when it had to cut.
func bridgeTrunc(s string, n int) string {
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\n", " "), "\t", " ")
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}

// bridgePad right-pads to n runes. fmt's %-*s counts bytes, which misaligns
// every column after a non-ASCII title.
func bridgePad(s string, n int) string {
	if pad := n - len([]rune(s)); pad > 0 {
		return s + strings.Repeat(" ", pad)
	}
	return s
}

func bridgePlural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	switch {
	case strings.HasSuffix(noun, "ch"), strings.HasSuffix(noun, "s"):
		return fmt.Sprintf("%d %ses", n, noun)
	case strings.HasSuffix(noun, "y"):
		return fmt.Sprintf("%d %sies", n, strings.TrimSuffix(noun, "y"))
	default:
		return fmt.Sprintf("%d %ss", n, noun)
	}
}

func bridgeBytes(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1fMB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1fkB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%dB", n)
	}
}

// bridgeClock and bridgeStamp read the protocol's epoch milliseconds.
func bridgeClock(ms int64) string {
	if ms <= 0 {
		return "--:--:--"
	}
	return time.UnixMilli(ms).Format("15:04:05")
}

func bridgeStamp(ms int64) string {
	if ms <= 0 {
		return "unknown"
	}
	return time.UnixMilli(ms).Format("2006-01-02 15:04")
}

func bridgeHeaderBlock(title string, headers map[string]string) string {
	if len(headers) == 0 {
		return ""
	}
	keys := make([]string, 0, len(headers))
	for k := range headers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	fmt.Fprintf(&b, "%s:\n", title)
	for _, k := range keys {
		fmt.Fprintf(&b, "  %s: %s\n", k, bridgeTrunc(headers[k], 200))
	}
	return b.String()
}
