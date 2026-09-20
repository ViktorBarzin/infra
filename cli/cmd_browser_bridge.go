package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	bb "github.com/ViktorBarzin/browser-bridge/client"
)

// `homelab browser bridge` drives the Chrome a human is sitting at, with that
// human's logins, over a server in the cluster and an extension in their
// browser. Its sibling `homelab browser run` drives a shared headless Chrome
// in the cluster with nobody watching, and is the right call whenever the
// human's session is not what you need.
//
// Every open tab is reachable, not only tabs the agent created: `tabs` lists
// them, `attach` borrows one, and `--tab <handle>` on any command names any of
// them. That is the point of the tool, since a half-filled form or a page
// behind a POST cannot be recreated by opening a URL. Nothing here asks for
// approval, so the human's view of what happened is the extension popup's live
// feed, Chrome's own debugging banner, and `homelab browser bridge stop`.
//
// The protocol, the 30 commands and the exit codes are docs/protocol.md in the
// browser-bridge repo. The client is vendored under bridge/, see its README.

// bridgeDefaultScroll is how far `scroll --direction` moves when no --amount
// is given, in CSS pixels. About one screenful on a laptop.
const bridgeDefaultScroll = 500

// bridgeDefaultShot is where `screenshot` writes when no --output is given.
const bridgeDefaultShot = "screenshot.png"

// bridgeServerEnv is the env override this verb reads first. The client
// package reads BROWSER_BRIDGE_URL, which stays as the fallback.
const bridgeServerEnv = "BROWSER_BRIDGE_SERVER"

func browserBridgeCommands() []Command {
	w := TierWrite
	r := TierRead
	return []Command{
		{Path: []string{"browser", "bridge"}, Tier: r,
			Summary: "drive YOUR OWN Chrome with your logins, any open tab (run `browser bridge --help`)",
			Run:     bridgeGroupHelp},

		// Navigation, 5.
		{Path: []string{"browser", "bridge", "open"}, Tier: w,
			Summary: "open a url in your Chrome: bridge open <url> [--new-tab] [--focus] [--tab T]", Run: bridgeVerb("open")},
		{Path: []string{"browser", "bridge", "back"}, Tier: w,
			Summary: "go back one history entry: bridge back [--tab T]", Run: bridgeVerb("back")},
		{Path: []string{"browser", "bridge", "forward"}, Tier: w,
			Summary: "go forward one history entry: bridge forward [--tab T]", Run: bridgeVerb("forward")},
		{Path: []string{"browser", "bridge", "reload"}, Tier: w,
			Summary: "reload the tab: bridge reload [--hard] [--tab T]", Run: bridgeVerb("reload")},
		{Path: []string{"browser", "bridge", "url"}, Tier: r,
			Summary: "print where a tab is: bridge url [--tab T]", Run: bridgeVerb("url")},

		// Reading, 5.
		{Path: []string{"browser", "bridge", "read-text"}, Tier: r,
			Summary: "read a tab's text: bridge read-text [selector] [--max N] [--tab T]", Run: bridgeVerb("read-text")},
		{Path: []string{"browser", "bridge", "read-html"}, Tier: r,
			Summary: "read a tab's markup: bridge read-html [selector] [--inner] [--tab T]", Run: bridgeVerb("read-html")},
		{Path: []string{"browser", "bridge", "query"}, Tier: r,
			Summary: "match elements and report them: bridge query <selector> [--max N] [--attrs]", Run: bridgeVerb("query")},
		{Path: []string{"browser", "bridge", "eval"}, Tier: w,
			Summary: "evaluate an expression in the page: bridge eval <expr> [--await]", Run: bridgeVerb("eval")},
		{Path: []string{"browser", "bridge", "screenshot"}, Tier: r,
			Summary: "capture a tab to a file: bridge screenshot [--output P] [--full-page] [--selector S]", Run: bridgeVerb("screenshot")},

		// Input, 8.
		{Path: []string{"browser", "bridge", "click"}, Tier: w,
			Summary: "click an element or a point: bridge click <selector> | --at X,Y [--double]", Run: bridgeVerb("click")},
		{Path: []string{"browser", "bridge", "type"}, Tier: w,
			Summary: "type into a field: bridge type <selector> <text> [--clear] [--enter]", Run: bridgeVerb("type")},
		{Path: []string{"browser", "bridge", "fill"}, Tier: w,
			Summary: "fill a field or a whole form in one action: bridge fill <sel> <value> | --set S=V …", Run: bridgeVerb("fill")},
		{Path: []string{"browser", "bridge", "select"}, Tier: w,
			Summary: "pick an option: bridge select <selector> <value> [--by value|label|index]", Run: bridgeVerb("select")},
		{Path: []string{"browser", "bridge", "press"}, Tier: w,
			Summary: "send a key: bridge press <key> [--mod ctrl|shift|alt|meta]", Run: bridgeVerb("press")},
		{Path: []string{"browser", "bridge", "hover"}, Tier: w,
			Summary: "hover an element: bridge hover <selector>", Run: bridgeVerb("hover")},
		{Path: []string{"browser", "bridge", "scroll"}, Tier: w,
			Summary: "scroll the page or an element into view: bridge scroll --to S | --by DX,DY", Run: bridgeVerb("scroll")},
		{Path: []string{"browser", "bridge", "dialog"}, Tier: w,
			Summary: "answer an open JS dialog: bridge dialog accept|dismiss [--text T]", Run: bridgeVerb("dialog")},

		// Waiting, 1.
		{Path: []string{"browser", "bridge", "wait-for"}, Tier: w,
			Summary: "wait for a load, a text, a selector or a url: bridge wait-for [text…] [--selector S]", Run: bridgeVerb("wait-for")},

		// Diagnostics, 3.
		{Path: []string{"browser", "bridge", "console"}, Tier: r,
			Summary: "read what the page logged: bridge console [--tail N] [--level error] [--count]", Run: bridgeVerb("console")},
		{Path: []string{"browser", "bridge", "network"}, Tier: r,
			Summary: "read captured requests: bridge network [--type xhr] [--id N] [--body P]", Run: bridgeVerb("network")},
		{Path: []string{"browser", "bridge", "emulate"}, Tier: w,
			Summary: "override device, network and media: bridge emulate --viewport 390x844x3,mobile [--reset]", Run: bridgeVerb("emulate")},

		// Tab access, 5. The whole point of the tool: every tab, not only ours.
		{Path: []string{"browser", "bridge", "tabs"}, Tier: r,
			Summary: "list EVERY open tab, the human's included: bridge tabs [--window N] [--mine]", Run: bridgeVerb("tabs")},
		{Path: []string{"browser", "bridge", "attach"}, Tier: w,
			Summary: "take control of a tab the human already had open: bridge attach <tab>", Run: bridgeVerb("attach")},
		{Path: []string{"browser", "bridge", "detach"}, Tier: w,
			Summary: "hand a borrowed tab back: bridge detach <tab> | --all", Run: bridgeVerb("detach")},
		{Path: []string{"browser", "bridge", "activate"}, Tier: w,
			Summary: "focus a tab and raise its window, to show a human what you see: bridge activate <tab>", Run: bridgeVerb("activate")},
		{Path: []string{"browser", "bridge", "close-tab"}, Tier: w,
			Summary: "close a tab, the human's own included: bridge close-tab <tab> [--force]", Run: bridgeVerb("close-tab")},

		// Plumbing, 3.
		{Path: []string{"browser", "bridge", "status"}, Tier: r,
			Summary: "can I drive a browser right now (answers with Chrome closed): bridge status", Run: bridgeVerb("status")},
		{Path: []string{"browser", "bridge", "ping"}, Tier: r,
			Summary: "round trip to the extension, answers while the queue is stuck: bridge ping", Run: bridgeVerb("ping")},
		{Path: []string{"browser", "bridge", "stop"}, Tier: w,
			Summary: "kill switch: drop every action and detach every tab: bridge stop [--browser B]", Run: bridgeVerb("stop")},

		// Enrolment and inventory.
		{Path: []string{"browser", "bridge", "enrol"}, Tier: r,
			Summary: "print the one command that enrols a Chrome, and what it grants", Run: bridgeVerb("enrol")},
		{Path: []string{"browser", "bridge", "pair"}, Tier: w,
			Summary: "mint a 6 character pair code for a Chrome that cannot reach Authentik", Run: bridgeVerb("pair")},
		{Path: []string{"browser", "bridge", "browsers"}, Tier: r,
			Summary: "list your enrolled browsers with last-seen and which is default", Run: bridgeVerb("browsers")},
	}
}

// bridgeGroupHelp answers a bare `homelab browser bridge`. A mistyped command
// name reaches it too, because dispatch matches the longest prefix, and
// answering a typo with the help text and exit 0 tells an agent its command
// ran.
func bridgeGroupHelp(args []string) error {
	if bad := bridgeUnknownSubcommand(args); bad != "" {
		return bridgeFail("bridge", bridgeUsage(
			"unknown command `browser bridge %s` (try: homelab browser bridge --help)", bad))
	}
	fmt.Print(bridgeHelp())
	return nil
}

// bridgeUnknownSubcommand returns the first token that is not a flag. Under
// this group that can only be a command name no verb claimed.
func bridgeUnknownSubcommand(args []string) string {
	for _, a := range args {
		if a != "" && !strings.HasPrefix(a, "-") {
			return a
		}
	}
	return ""
}

// bridgeVerb binds one command name to the shared parse, run and exit path.
func bridgeVerb(cmd string) func([]string) error {
	return func(args []string) error {
		o, err := parseBridgeArgs(cmd, args)
		if err != nil {
			return bridgeFail(cmd, err)
		}
		if o.help {
			fmt.Print(bridgeHelp())
			return nil
		}
		if err := runBridgeCommand(o, os.Stdout); err != nil {
			return bridgeFail(cmd, err)
		}
		return nil
	}
}

// bridgeOpts is every flag the group accepts, parsed. One struct for 33
// commands, with a per-command allowlist, so `click --full-page` is an error
// rather than a flag dropped on the floor.
type bridgeOpts struct {
	cmd        string
	help       bool
	jsonOut    bool
	positional []string

	// Global.
	browser   string
	tab       string
	session   string
	server    string
	timeoutMs int

	// Navigation.
	newTab bool
	focus  bool
	group  string
	hard   bool

	// Reading.
	maxN     int
	inner    bool
	attrs    bool
	await    bool
	output   string
	fullPage bool
	selector string

	// Input.
	at        string
	double    bool
	button    string
	clear     bool
	enter     bool
	delayMs   int
	sets      []string
	by        string
	mods      []string
	to        string
	direction string
	amount    int

	// Waiting.
	waitURL string
	gone    bool

	// Diagnostics.
	text        string
	tail        int
	head        int
	level       string
	countOnly   bool
	requestID   int
	types       []string
	limit       int
	all         bool
	body        string
	colorScheme string
	cpu         float64
	netProfile  string
	geo         string
	userAgent   string
	viewport    string
	headers     string
	reset       bool

	// Tab access.
	window int
	mine   bool
	force  bool

	// Enrolment.
	label string
}

// bridgeBoolFlags take no value. Everything else consumes the next token, or
// the text after an '=' in the same token.
var bridgeBoolFlags = map[string]bool{
	"json": true, "help": true, "new-tab": true, "focus": true, "hard": true,
	"inner": true, "attrs": true, "await": true, "full-page": true,
	"double": true, "clear": true, "enter": true, "gone": true,
	"count": true, "all": true, "reset": true, "mine": true,
	"all-windows": true, "force": true,
}

// bridgeCommandFlags are the flags each command accepts beyond the globals.
var bridgeCommandFlags = map[string][]string{
	"open":       {"new-tab", "focus", "group"},
	"back":       {},
	"forward":    {},
	"reload":     {"hard"},
	"url":        {},
	"read-text":  {"max"},
	"read-html":  {"inner"},
	"query":      {"max", "attrs"},
	"eval":       {"await"},
	"screenshot": {"output", "full-page", "selector"},
	"click":      {"at", "double", "button"},
	"type":       {"clear", "enter", "delay"},
	"fill":       {"set"},
	"select":     {"by"},
	"press":      {"mod"},
	"hover":      {},
	"scroll":     {"to", "by", "direction", "amount"},
	"dialog":     {"text"},
	"wait-for":   {"selector", "gone", "url"},
	"console":    {"tail", "head", "level", "count", "clear"},
	"network":    {"id", "type", "limit", "all", "body"},
	"emulate": {"color-scheme", "cpu", "network", "geo", "user-agent",
		"viewport", "headers", "reset"},
	"tabs":      {"window", "mine", "all-windows"},
	"attach":    {},
	"detach":    {"all"},
	"activate":  {},
	"close-tab": {"force"},
	"status":    {},
	"ping":      {},
	"stop":      {},
	"enrol":     {},
	"pair":      {"label"},
	"browsers":  {},
}

// bridgeNoTab are the commands where naming a target tab means nothing: they
// address the browser, or they carry the handle in their own parameters.
var bridgeNoTab = map[string]bool{
	"tabs": true, "ping": true, "status": true, "stop": true,
	"enrol": true, "pair": true, "browsers": true,
}

// bridgeServerOnly are the commands the server answers without touching the
// browser, so they take no action timeout and no session.
var bridgeServerOnly = map[string]bool{
	"status": true, "stop": true, "enrol": true, "pair": true, "browsers": true,
}

func bridgeAllowedFlags(cmd string) map[string]bool {
	allowed := map[string]bool{"browser": true, "server": true, "json": true, "help": true}
	if cmd == "enrol" {
		delete(allowed, "json")
		delete(allowed, "browser")
	}
	if !bridgeServerOnly[cmd] {
		allowed["session"] = true
		allowed["timeout"] = true
	}
	if !bridgeNoTab[cmd] {
		allowed["tab"] = true
	}
	// attach, detach, activate and close-tab take the handle as a positional,
	// and --tab is the same thing spelled the other way.
	switch cmd {
	case "attach", "detach", "activate", "close-tab":
		allowed["tab"] = true
	}
	for _, f := range bridgeCommandFlags[cmd] {
		allowed[f] = true
	}
	return allowed
}

// parseBridgeArgs reads one command's argv. It accepts both `--flag value` and
// `--flag=value`, and either dash count, because the tools these verbs sit
// next to disagree; an unrecognised flag is always an error, never a token
// dropped on the floor (see flagToken in homelab.go for what that cost).
func parseBridgeArgs(cmd string, args []string) (bridgeOpts, error) {
	o := bridgeOpts{cmd: cmd}
	allowed := bridgeAllowedFlags(cmd)

	atoi := func(s, flag string) (int, error) {
		n, err := strconv.Atoi(s)
		if err != nil {
			return 0, bridgeUsage("%s expects an integer, got %q", flag, s)
		}
		return n, nil
	}
	atof := func(s, flag string) (float64, error) {
		f, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return 0, bridgeUsage("%s expects a number, got %q", flag, s)
		}
		return f, nil
	}

	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			o.positional = append(o.positional, args[i+1:]...)
			break
		}
		if a == "" || a == "-" || !strings.HasPrefix(a, "-") {
			o.positional = append(o.positional, a)
			continue
		}

		name, inline, hasInline := flagToken(a)
		if name == "h" {
			name = "help"
		}
		if !allowed[name] {
			return o, bridgeUsage("unknown flag %q for `browser bridge %s` (try: homelab browser bridge --help)", a, cmd)
		}

		value := inline
		if !bridgeBoolFlags[name] && !hasInline {
			if i+1 >= len(args) {
				return o, bridgeUsage("--%s needs a value", name)
			}
			value = args[i+1]
			i++
		}

		var err error
		switch name {
		case "help":
			o.help = true
		case "json":
			o.jsonOut = true
		case "browser":
			o.browser = value
		case "tab":
			o.tab = value
		case "session":
			o.session = value
		case "server":
			o.server = value
		case "timeout":
			if o.timeoutMs, err = atoi(value, "--timeout"); err != nil {
				return o, err
			}
			if o.timeoutMs < 1000 || o.timeoutMs > 600000 {
				return o, bridgeUsage("--timeout is in milliseconds, between 1000 and 600000, got %d", o.timeoutMs)
			}
		case "new-tab":
			o.newTab = true
		case "focus":
			o.focus = true
		case "group":
			o.group = value
		case "hard":
			o.hard = true
		case "max":
			if o.maxN, err = atoi(value, "--max"); err != nil {
				return o, err
			}
		case "inner":
			o.inner = true
		case "attrs":
			o.attrs = true
		case "await":
			o.await = true
		case "output":
			o.output = value
		case "full-page":
			o.fullPage = true
		case "selector":
			o.selector = value
		case "at":
			o.at = value
		case "double":
			o.double = true
		case "button":
			o.button = value
		case "clear":
			o.clear = true
		case "enter":
			o.enter = true
		case "delay":
			if o.delayMs, err = atoi(value, "--delay"); err != nil {
				return o, err
			}
		case "set":
			o.sets = append(o.sets, value)
		case "by":
			o.by = value
		case "mod":
			o.mods = append(o.mods, value)
		case "to":
			o.to = value
		case "direction":
			o.direction = value
		case "amount":
			if o.amount, err = atoi(value, "--amount"); err != nil {
				return o, err
			}
		case "url":
			o.waitURL = value
		case "gone":
			o.gone = true
		case "text":
			o.text = value
		case "tail":
			if o.tail, err = atoi(value, "--tail"); err != nil {
				return o, err
			}
		case "head":
			if o.head, err = atoi(value, "--head"); err != nil {
				return o, err
			}
		case "level":
			o.level = value
		case "count":
			o.countOnly = true
		case "id":
			if o.requestID, err = atoi(value, "--id"); err != nil {
				return o, err
			}
		case "type":
			o.types = append(o.types, value)
		case "limit":
			if o.limit, err = atoi(value, "--limit"); err != nil {
				return o, err
			}
		case "all":
			o.all = true
		case "body":
			o.body = value
		case "color-scheme":
			o.colorScheme = value
		case "cpu":
			if o.cpu, err = atof(value, "--cpu"); err != nil {
				return o, err
			}
		case "network":
			o.netProfile = value
		case "geo":
			o.geo = value
		case "user-agent":
			o.userAgent = value
		case "viewport":
			o.viewport = value
		case "headers":
			o.headers = value
		case "reset":
			o.reset = true
		case "window":
			if o.window, err = atoi(value, "--window"); err != nil {
				return o, err
			}
		case "mine":
			o.mine = true
		case "all-windows":
			// The default. Accepted so the flag in the docs is not an error.
		case "force":
			o.force = true
		case "label":
			o.label = value
		default:
			return o, bridgeUsage("flag %q is allowed for `browser bridge %s` but not handled, which is a bug in this verb", a, cmd)
		}
	}
	return o, nil
}

// bridgeUsage is the caller's mistake, caught before anything is sent. It
// exits 2, like every other usage error in the protocol.
func bridgeUsage(format string, args ...any) error {
	return &bb.UsageError{Message: fmt.Sprintf(format, args...)}
}

// bridgeNoParams is the payload of the four actions that take none:
// nav.back, nav.forward, nav.url and ctl.ping. The client package does not
// re-export wire.EmptyParams, and this marshals to the same {}.
type bridgeNoParams struct{}

// bridgeAction encodes one action's typed parameters for the wire.
func bridgeAction[P any](action bb.ActionType, params P) (bb.ActionType, json.RawMessage, error) {
	raw, err := json.Marshal(params)
	if err != nil {
		return action, nil, bridgeUsage("cannot encode the parameters for %s, %v", action, err)
	}
	return action, raw, nil
}

func (o bridgeOpts) arg(i int) string {
	if i < len(o.positional) {
		return o.positional[i]
	}
	return ""
}

// bridgeTabHandle is the handle a tab command acts on: the positional, or
// --tab spelled the other way.
func (o bridgeOpts) bridgeTabHandle() string {
	if h := o.arg(0); h != "" {
		return h
	}
	return o.tab
}

// bridgeParams turns parsed flags into the action and the typed parameter
// payload the protocol defines for it.
func bridgeParams(o bridgeOpts) (bb.ActionType, json.RawMessage, error) {
	switch o.cmd {
	case "open":
		url := o.arg(0)
		if url == "" {
			return "", nil, bridgeUsage("open needs a url: homelab browser bridge open <url>")
		}
		return bridgeAction(bb.ActionNavOpen, bb.OpenParams{
			URL: url, NewTab: o.newTab, Focus: o.focus, Group: o.group})

	case "back":
		return bridgeAction(bb.ActionNavBack, bridgeNoParams{})
	case "forward":
		return bridgeAction(bb.ActionNavForward, bridgeNoParams{})
	case "reload":
		return bridgeAction(bb.ActionNavReload, bb.ReloadParams{IgnoreCache: o.hard})
	case "url":
		return bridgeAction(bb.ActionNavURL, bridgeNoParams{})

	case "read-text":
		return bridgeAction(bb.ActionReadText, bb.ReadTextParams{Selector: o.arg(0), MaxChars: o.maxN})
	case "read-html":
		return bridgeAction(bb.ActionReadHTML, bb.ReadHTMLParams{Selector: o.arg(0), Inner: o.inner})
	case "query":
		sel := o.arg(0)
		if sel == "" {
			return "", nil, bridgeUsage("query needs a selector: homelab browser bridge query <selector>")
		}
		max := o.maxN
		if max == 0 {
			max = 10
		}
		return bridgeAction(bb.ActionReadQuery, bb.QueryParams{Selector: sel, Max: max, Attrs: o.attrs})
	case "eval":
		expr := strings.Join(o.positional, " ")
		if expr == "" {
			return "", nil, bridgeUsage("eval needs an expression: homelab browser bridge eval <expression>")
		}
		return bridgeAction(bb.ActionReadEval, bb.EvalParams{Expression: expr, AwaitPromise: o.await})
	case "screenshot":
		return bridgeAction(bb.ActionReadScreenshot, bb.ScreenshotParams{
			FullPage: o.fullPage, Selector: o.selector})

	case "click":
		p := bb.ClickParams{Selector: o.arg(0), Double: o.double, Button: bb.MouseButton(o.button)}
		if o.at != "" {
			pt, err := bridgePoint(o.at)
			if err != nil {
				return "", nil, err
			}
			p.At = pt
		}
		if p.Selector == "" && p.At == nil {
			return "", nil, bridgeUsage("click needs a selector or --at <x>,<y>")
		}
		if !p.Button.Valid() {
			return "", nil, bridgeUsage("--button takes left, right or middle, got %q", o.button)
		}
		return bridgeAction(bb.ActionInputClick, p)
	case "type":
		if len(o.positional) < 2 {
			return "", nil, bridgeUsage("type needs a selector and the text: homelab browser bridge type <selector> <text>")
		}
		return bridgeAction(bb.ActionInputType, bb.TypeParams{
			Selector: o.arg(0), Text: strings.Join(o.positional[1:], " "),
			Clear: o.clear, SubmitKey: o.enter, DelayMs: o.delayMs})
	case "fill":
		fields, err := bridgeFillFields(o)
		if err != nil {
			return "", nil, err
		}
		return bridgeAction(bb.ActionInputFill, bb.FillParams{Fields: fields})
	case "select":
		if len(o.positional) < 2 {
			return "", nil, bridgeUsage("select needs a selector and a value: homelab browser bridge select <selector> <value>")
		}
		by := bb.SelectBy(o.by)
		if !by.Valid() {
			return "", nil, bridgeUsage("--by takes value, label or index, got %q", o.by)
		}
		return bridgeAction(bb.ActionInputSelect, bb.SelectParams{
			Selector: o.arg(0), Value: strings.Join(o.positional[1:], " "), By: by})
	case "press":
		key := o.arg(0)
		if key == "" {
			return "", nil, bridgeUsage("press needs a key: homelab browser bridge press <key>")
		}
		var mods []bb.Modifier
		for _, m := range o.mods {
			mod := bb.Modifier(m)
			if !mod.Valid() {
				return "", nil, bridgeUsage("--mod takes ctrl, shift, alt or meta, got %q", m)
			}
			mods = append(mods, mod)
		}
		return bridgeAction(bb.ActionInputPress, bb.PressParams{Key: key, Modifiers: mods})
	case "hover":
		sel := o.arg(0)
		if sel == "" {
			return "", nil, bridgeUsage("hover needs a selector: homelab browser bridge hover <selector>")
		}
		return bridgeAction(bb.ActionInputHover, bb.HoverParams{Selector: sel})
	case "scroll":
		p, err := bridgeScrollParams(o)
		if err != nil {
			return "", nil, err
		}
		return bridgeAction(bb.ActionInputScroll, p)
	case "dialog":
		switch o.arg(0) {
		case "accept":
			return bridgeAction(bb.ActionInputDialog, bb.DialogParams{Accept: true, PromptText: o.text})
		case "dismiss":
			return bridgeAction(bb.ActionInputDialog, bb.DialogParams{Accept: false, PromptText: o.text})
		default:
			return "", nil, bridgeUsage("dialog needs accept or dismiss: homelab browser bridge dialog accept|dismiss")
		}

	case "wait-for":
		return bridgeAction(bb.ActionWaitFor, bb.WaitForParams{
			Texts: o.positional, Selector: o.selector, Gone: o.gone, URLContains: o.waitURL})

	case "console":
		p := bb.ConsoleParams{
			Tail: o.tail, Head: o.head, Level: bb.ConsoleLevel(o.level),
			CountOnly: o.countOnly, Clear: o.clear}
		if !p.Level.Valid() {
			return "", nil, bridgeUsage("--level takes log, info, warn, error or debug, got %q", o.level)
		}
		if p.Tail == 0 && p.Head == 0 && !p.CountOnly {
			p.Tail = 20
		}
		return bridgeAction(bb.ActionDiagConsole, p)
	case "network":
		return bridgeAction(bb.ActionDiagNetwork, bb.NetworkParams{
			RequestID: o.requestID, Types: o.types, Limit: o.limit,
			IncludePreNav: o.all, WantBody: o.body != ""})
	case "emulate":
		p, err := bridgeEmulateParams(o)
		if err != nil {
			return "", nil, err
		}
		return bridgeAction(bb.ActionDiagEmulate, p)

	case "tabs":
		return bridgeAction(bb.ActionTabList, bb.TabListParams{WindowID: o.window, OnlyAgent: o.mine})
	case "attach":
		h := o.bridgeTabHandle()
		if h == "" {
			return "", nil, bridgeUsage("attach needs a tab handle: homelab browser bridge attach <tab> (run tabs to list them)")
		}
		return bridgeAction(bb.ActionTabAttach, bb.AttachParams{Tab: h})
	case "detach":
		h := o.bridgeTabHandle()
		if h == "" && !o.all {
			return "", nil, bridgeUsage("detach needs a tab handle or --all: homelab browser bridge detach <tab>")
		}
		return bridgeAction(bb.ActionTabDetach, bb.DetachParams{Tab: h, All: o.all})
	case "activate":
		h := o.bridgeTabHandle()
		if h == "" {
			return "", nil, bridgeUsage("activate needs a tab handle: homelab browser bridge activate <tab>")
		}
		return bridgeAction(bb.ActionTabActivate, bb.ActivateParams{Tab: h})
	case "close-tab":
		h := o.bridgeTabHandle()
		if h == "" {
			return "", nil, bridgeUsage("close-tab needs a tab handle: homelab browser bridge close-tab <tab>")
		}
		return bridgeAction(bb.ActionTabClose, bb.CloseTabParams{Tab: h})

	case "ping":
		return bridgeAction(bb.ActionCtlPing, bridgeNoParams{})
	}
	return "", nil, bridgeUsage("`browser bridge %s` is answered by the server, not by an action", o.cmd)
}

// bridgePoint reads an "<x>,<y>" pair.
func bridgePoint(s string) (*bb.Point, error) {
	x, y, ok := bridgePair(s)
	if !ok {
		return nil, bridgeUsage("--at takes <x>,<y> in viewport pixels, got %q", s)
	}
	return &bb.Point{X: x, Y: y}, nil
}

func bridgePair(s string) (float64, float64, bool) {
	a, b, found := strings.Cut(s, ",")
	if !found {
		return 0, 0, false
	}
	x, err := strconv.ParseFloat(strings.TrimSpace(a), 64)
	if err != nil {
		return 0, 0, false
	}
	y, err := strconv.ParseFloat(strings.TrimSpace(b), 64)
	if err != nil {
		return 0, 0, false
	}
	return x, y, true
}

func bridgeFillFields(o bridgeOpts) ([]bb.FillField, error) {
	if len(o.sets) > 0 {
		fields := make([]bb.FillField, 0, len(o.sets))
		for _, s := range o.sets {
			sel, value, found := strings.Cut(s, "=")
			if !found || sel == "" {
				return nil, bridgeUsage("--set takes <selector>=<value>, got %q", s)
			}
			fields = append(fields, bb.FillField{Selector: sel, Value: value})
		}
		return fields, nil
	}
	if len(o.positional) < 2 {
		return nil, bridgeUsage("fill needs a selector and a value, or repeated --set <selector>=<value>")
	}
	return []bb.FillField{{Selector: o.arg(0), Value: strings.Join(o.positional[1:], " ")}}, nil
}

func bridgeScrollParams(o bridgeOpts) (bb.ScrollParams, error) {
	p := bb.ScrollParams{Selector: o.to}
	switch {
	case o.by != "":
		dx, dy, ok := bridgePair(o.by)
		if !ok {
			return p, bridgeUsage("--by takes <dx>,<dy> in pixels, got %q", o.by)
		}
		p.DX, p.DY = dx, dy
	case o.direction != "":
		amount := float64(o.amount)
		if amount == 0 {
			amount = bridgeDefaultScroll
		}
		switch o.direction {
		case "down":
			p.DY = amount
		case "up":
			p.DY = -amount
		case "right":
			p.DX = amount
		case "left":
			p.DX = -amount
		default:
			return p, bridgeUsage("--direction takes up, down, left or right, got %q", o.direction)
		}
	case p.Selector == "":
		return p, bridgeUsage("scroll needs --to <selector>, --by <dx>,<dy> or --direction <up|down|left|right>")
	}
	return p, nil
}

func bridgeEmulateParams(o bridgeOpts) (bb.EmulateParams, error) {
	p := bb.EmulateParams{
		ColorScheme: bb.ColorScheme(o.colorScheme),
		CPUThrottle: o.cpu,
		Network:     bb.NetworkProfile(o.netProfile),
		UserAgent:   o.userAgent,
		Reset:       o.reset,
	}
	if !p.ColorScheme.Valid() {
		return p, bridgeUsage("--color-scheme takes dark, light or auto, got %q", o.colorScheme)
	}
	if !p.Network.Valid() {
		return p, bridgeUsage("--network takes offline, slow-3g, fast-3g, slow-4g, fast-4g or none, got %q", o.netProfile)
	}
	if o.geo != "" {
		lat, lon, ok := bridgePair(o.geo)
		if !ok {
			return p, bridgeUsage("--geo takes <lat>,<lon>, got %q", o.geo)
		}
		p.Geolocation = &bb.GeoPoint{Lat: lat, Lon: lon}
	}
	if o.viewport != "" {
		v, err := bridgeViewport(o.viewport)
		if err != nil {
			return p, err
		}
		p.Viewport = v
	}
	if o.headers != "" {
		headers := map[string]string{}
		if err := json.Unmarshal([]byte(o.headers), &headers); err != nil {
			return p, bridgeUsage("--headers takes a JSON object of header names to values, got %q", o.headers)
		}
		p.ExtraHeaders = headers
	}
	if bridgeEmulateIsEmpty(p) {
		return p, bridgeUsage("emulate needs at least one override, or --reset to clear them")
	}
	return p, nil
}

// bridgeEmulateIsEmpty reports whether the command set no override at all.
// EmulateParams carries a map, so it cannot be compared to its zero value.
func bridgeEmulateIsEmpty(p bb.EmulateParams) bool {
	return p.ColorScheme == "" && p.CPUThrottle == 0 && p.Network == "" &&
		p.Geolocation == nil && p.UserAgent == "" && p.Viewport == nil &&
		len(p.ExtraHeaders) == 0 && !p.Reset
}

// bridgeViewport reads "<width>x<height>[xDPR][,mobile][,touch]".
func bridgeViewport(s string) (*bb.Viewport, error) {
	bad := bridgeUsage("--viewport takes <width>x<height>[xDPR][,mobile][,touch], got %q", s)
	parts := strings.Split(s, ",")
	dims := strings.Split(parts[0], "x")
	if len(dims) < 2 || len(dims) > 3 {
		return nil, bad
	}
	width, err := strconv.Atoi(strings.TrimSpace(dims[0]))
	if err != nil {
		return nil, bad
	}
	height, err := strconv.Atoi(strings.TrimSpace(dims[1]))
	if err != nil {
		return nil, bad
	}
	v := &bb.Viewport{Width: width, Height: height}
	if len(dims) == 3 {
		dpr, err := strconv.ParseFloat(strings.TrimSpace(dims[2]), 64)
		if err != nil {
			return nil, bad
		}
		v.DPR = dpr
	}
	for _, opt := range parts[1:] {
		switch strings.TrimSpace(opt) {
		case "mobile":
			v.Mobile = true
		case "touch":
			v.Touch = true
		default:
			return nil, bad
		}
	}
	return v, nil
}

// bridgeServerURL resolves the server: --server, then $BROWSER_BRIDGE_SERVER,
// then the client package's own $BROWSER_BRIDGE_URL and deployed default.
func bridgeServerURL(o bridgeOpts) string {
	if o.server != "" {
		return o.server
	}
	if v := strings.TrimSpace(os.Getenv(bridgeServerEnv)); v != "" {
		return v
	}
	return bb.BaseURLFromEnv()
}

// newBridgeClient builds the client. The token comes from
// $BROWSER_BRIDGE_TOKEN or ~/.config/browser-bridge/token, which must not be
// readable by anyone else: this is a shared box and that token drives a
// human's logged-in Chrome.
func newBridgeClient(o bridgeOpts) (*bb.Client, error) {
	token, err := bb.TokenFromEnvOrFile()
	if err != nil {
		return nil, err
	}
	browser := o.browser
	if browser == "" {
		browser = bb.BrowserFromEnv()
	}
	return bb.New(bridgeServerURL(o), token,
		bb.WithBrowser(browser),
		bb.WithSession(o.session),
		bb.WithUser(currentUser()),
		bb.WithAgentLabel(bridgeAgentLabel()),
		bb.WithUserAgent("homelab/"+version+" browser-bridge"),
	)
}

// bridgeAgentLabel is what the popup feed and the tab overlay name, so a
// human watching can tell who is driving.
func bridgeAgentLabel() string {
	host, err := os.Hostname()
	if err != nil || host == "" {
		return currentUser()
	}
	return currentUser() + "@" + host
}

func bridgeTarget(o bridgeOpts) bb.Target {
	t := bb.Target{Browser: o.browser, Session: o.session}
	if !bridgeNoTab[o.cmd] {
		switch o.cmd {
		case "attach", "detach", "activate", "close-tab":
			// The handle rides in the parameters for these.
		default:
			t.Tab = o.tab
		}
	}
	if o.timeoutMs > 0 {
		t.Timeout = time.Duration(o.timeoutMs) * time.Millisecond
	}
	return t
}

// runBridgeCommand executes one parsed command and writes its output.
func runBridgeCommand(o bridgeOpts, out io.Writer) error {
	if o.cmd == "enrol" {
		fmt.Fprint(out, bridgeEnrolText(bridgeServerURL(o)))
		return nil
	}

	c, err := newBridgeClient(o)
	if err != nil {
		return err
	}
	ctx := context.Background()

	switch o.cmd {
	case "status":
		return runBridgeStatus(ctx, c, o, out)
	case "browsers":
		return runBridgeBrowsers(ctx, c, o, out)
	case "stop":
		return runBridgeStop(ctx, c, o, out)
	case "pair":
		return runBridgePair(ctx, c, o, out)
	case "screenshot":
		return runBridgeScreenshot(ctx, c, o, out)
	}

	action, params, err := bridgeParams(o)
	if err != nil {
		return err
	}
	status, err := c.Run(ctx, bridgeTarget(o), action, params)
	if err != nil {
		return err
	}
	if o.jsonOut {
		return bridgeWriteJSON(out, status.Result)
	}
	text, err := renderBridgeResult(o, status.Result)
	if err != nil {
		return err
	}
	bridgeWarnClosedUsersTab(o, status.Result)
	fmt.Fprintln(out, strings.TrimRight(text, "\n"))
	return nil
}

func runBridgeStatus(ctx context.Context, c *bb.Client, o bridgeOpts, out io.Writer) error {
	status, err := c.Status(ctx)
	if err != nil {
		return err
	}
	if o.jsonOut {
		return bridgeMarshalTo(out, status)
	}
	fmt.Fprintln(out, strings.TrimRight(renderStatusResponse(status), "\n"))
	return nil
}

func runBridgeBrowsers(ctx context.Context, c *bb.Client, o bridgeOpts, out io.Writer) error {
	browsers, err := c.Browsers(ctx)
	if err != nil {
		return err
	}
	if o.jsonOut {
		return bridgeMarshalTo(out, browsers)
	}
	fmt.Fprintln(out, strings.TrimRight(renderBrowsersList(browsers), "\n"))
	return nil
}

func runBridgeStop(ctx context.Context, c *bb.Client, o bridgeOpts, out io.Writer) error {
	stopped, err := c.Stop(ctx, o.browser)
	if err != nil {
		return err
	}
	if o.jsonOut {
		return bridgeMarshalTo(out, stopped)
	}
	fmt.Fprintln(out, renderStopResponse(stopped))
	return nil
}

func runBridgePair(ctx context.Context, c *bb.Client, o bridgeOpts, out io.Writer) error {
	pair, err := c.Pair(ctx, o.label)
	if err != nil {
		return err
	}
	if o.jsonOut {
		return bridgeMarshalTo(out, pair)
	}
	fmt.Fprint(out, renderPairResponse(pair))
	return nil
}

func runBridgeScreenshot(ctx context.Context, c *bb.Client, o bridgeOpts, out io.Writer) error {
	path := o.output
	if path == "" {
		path = bridgeDefaultShot
	}
	f, err := os.Create(path)
	if err != nil {
		return bridgeUsage("cannot write %s, %v", path, err)
	}
	shot, err := c.ScreenshotTo(ctx, bridgeTarget(o),
		bb.ScreenshotParams{FullPage: o.fullPage, Selector: o.selector}, f)
	if closeErr := f.Close(); err == nil && closeErr != nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if o.jsonOut {
		return bridgeMarshalTo(out, shot)
	}
	// Report what landed on disk, not what the result claimed: those differ
	// exactly when the fetch was cut short, which is the case worth seeing.
	written := shot.Bytes
	if info, err := os.Stat(path); err == nil {
		written = info.Size()
	}
	fmt.Fprintf(out, "wrote %s  %dx%d  %d bytes\n", path, shot.Width, shot.Height, written)
	return nil
}

// bridgeWarnClosedUsersTab says so when the agent closed a tab the human
// opened. --force silences the line, never the record in the activity feed.
func bridgeWarnClosedUsersTab(o bridgeOpts, raw json.RawMessage) {
	if o.cmd != "close-tab" || o.force || len(raw) == 0 {
		return
	}
	var r bb.CloseTabResult
	if err := json.Unmarshal(raw, &r); err != nil || r.Owner != bb.OwnerUser {
		return
	}
	fmt.Fprintf(os.Stderr, "warning: %s was a tab the human opened, not one an agent created\n", r.Tab)
}

func bridgeWriteJSON(out io.Writer, raw json.RawMessage) error {
	if len(raw) == 0 {
		fmt.Fprintln(out, "{}")
		return nil
	}
	fmt.Fprintln(out, string(raw))
	return nil
}

func bridgeMarshalTo[T any](out io.Writer, v T) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	fmt.Fprintln(out, string(raw))
	return nil
}

// bridgeErrorText renders an error the way section 14.1 asks, and gives the
// exit code an agent branches on: 1 action failed, 2 usage, 3 no browser,
// 4 tab not resolvable, 5 stopped, 6 server or store unreachable.
func bridgeErrorText(err error) (string, int) {
	if err == nil {
		return "", 0
	}
	code := bb.ExitCode(err)
	// The unpaired message is part of the protocol, section 5.2, and an agent
	// reads it to decide what to do next. It is printed as written.
	if code == 3 {
		return err.Error(), code
	}
	return "homelab: " + err.Error(), code
}

// bridgeFail prints and exits. main.go exits 1 for every error it prints, and
// the exit code is the whole point here, so this verb owns its own exit and
// records the invocation itself.
func bridgeFail(cmd string, err error) error {
	text, code := bridgeErrorText(err)
	fmt.Fprintln(os.Stderr, text)
	emitUsage("browser bridge "+cmd, err)
	os.Exit(code)
	return nil
}
