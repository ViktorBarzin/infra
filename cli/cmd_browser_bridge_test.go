package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	bb "github.com/ViktorBarzin/browser-bridge/client"
)

// bridgePaths is every verb this group registers, including the group's own
// help entry. The 30 protocol commands are checked separately against
// bb.Commands(), so a command added to the protocol and forgotten here fails
// TestBridgeRegistersEveryProtocolCommand rather than passing quietly.
var bridgePaths = []string{
	"browser bridge",
	"browser bridge open", "browser bridge back", "browser bridge forward",
	"browser bridge reload", "browser bridge url",
	"browser bridge read-text", "browser bridge read-html", "browser bridge query",
	"browser bridge eval", "browser bridge screenshot",
	"browser bridge click", "browser bridge type", "browser bridge fill",
	"browser bridge select", "browser bridge press", "browser bridge hover",
	"browser bridge scroll", "browser bridge dialog",
	"browser bridge wait-for",
	"browser bridge console", "browser bridge network", "browser bridge emulate",
	"browser bridge tabs", "browser bridge attach", "browser bridge detach",
	"browser bridge activate", "browser bridge close-tab",
	"browser bridge status", "browser bridge ping", "browser bridge stop",
	"browser bridge enrol", "browser bridge pair", "browser bridge browsers",
}

func TestBridgeCommandsRegistered(t *testing.T) {
	reg := buildRegistry()
	found := map[string]Command{}
	for _, c := range reg {
		found[c.name()] = c
	}
	for _, want := range bridgePaths {
		c, ok := found[want]
		if !ok {
			t.Errorf("verb %q is not in the registry", want)
			continue
		}
		if c.Run == nil {
			t.Errorf("%q has no Run", want)
		}
		if c.Summary == "" {
			t.Errorf("%q has no Summary", want)
		}
	}
	// `homelab browser` must still list run and bridge side by side.
	for _, sibling := range []string{"browser", "browser run", "browser open", "browser ls"} {
		if _, ok := found[sibling]; !ok {
			t.Errorf("registering bridge lost the existing verb %q", sibling)
		}
	}
}

func TestBridgeRegistersEveryProtocolCommand(t *testing.T) {
	reg := buildRegistry()
	have := map[string]bool{}
	for _, c := range reg {
		have[c.name()] = true
	}
	for _, cmd := range bb.Commands() {
		if !have["browser bridge "+string(cmd)] {
			t.Errorf("protocol command %q has no verb", cmd)
		}
	}
	if n := len(bb.Commands()); n != 30 {
		t.Errorf("the protocol says 30 commands, the client package lists %d", n)
	}
}

func TestBridgeTiers(t *testing.T) {
	readOnly := map[string]bool{
		"browser bridge": true, "browser bridge url": true,
		"browser bridge read-text": true, "browser bridge read-html": true,
		"browser bridge query": true, "browser bridge screenshot": true,
		"browser bridge console": true, "browser bridge network": true,
		"browser bridge tabs": true, "browser bridge status": true,
		"browser bridge ping": true, "browser bridge browsers": true,
		"browser bridge enrol": true,
	}
	for _, c := range buildRegistry() {
		if !strings.HasPrefix(c.name(), "browser bridge") {
			continue
		}
		want := TierWrite
		if readOnly[c.name()] {
			want = TierRead
		}
		if c.Tier != want {
			t.Errorf("%q is tier %q, want %q", c.name(), c.Tier, want)
		}
	}
}

func TestParseBridgeArgsGlobals(t *testing.T) {
	got, err := parseBridgeArgs("click", []string{
		"#submit", "--tab", "t_4k2p9xqa", "--browser", "b_9Qw8Er",
		"--session=s_QaZw", "--server", "http://127.0.0.1:8080",
		"--timeout", "5000", "--json", "--double", "--button", "right",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := bridgeOpts{
		cmd: "click", positional: []string{"#submit"},
		tab: "t_4k2p9xqa", browser: "b_9Qw8Er", session: "s_QaZw",
		server: "http://127.0.0.1:8080", timeoutMs: 5000, jsonOut: true,
		double: true, button: "right",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseBridgeArgs =\n %+v\nwant\n %+v", got, want)
	}
}

func TestParseBridgeArgsRejects(t *testing.T) {
	cases := []struct {
		name string
		cmd  string
		args []string
		want string
	}{
		{"unknown flag", "click", []string{"#a", "--inner"}, `unknown flag "--inner"`},
		{"flag from another command", "click", []string{"#a", "--full-page"}, `unknown flag "--full-page"`},
		{"missing value", "click", []string{"--button"}, `--button needs a value`},
		{"not an integer", "read-text", []string{"--max", "lots"}, `--max expects an integer`},
		{"not a number", "emulate", []string{"--cpu", "fast"}, `--cpu expects a number`},
		{"timeout too small", "url", []string{"--timeout", "10"}, "--timeout is in milliseconds"},
		{"timeout too large", "url", []string{"--timeout", "900000"}, "--timeout is in milliseconds"},
		{"single dash form", "read-text", []string{"-max=5"}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := parseBridgeArgs(c.cmd, c.args)
			if c.want == "" {
				if err != nil {
					t.Fatalf("expected the single-dash form to parse, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected an error naming %q", c.want)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %q does not name %q", err, c.want)
			}
		})
	}
}

// A misspelled flag is the caller's mistake, which section 14.1 exits 2 for.
// Returning a plain error instead of a UsageError exits 1, the code for an
// action that failed inside the browser, and a script branches on the wrong
// one. Caught by running the built binary, not by the table above.
func TestParseBridgeArgsErrorsExitTwo(t *testing.T) {
	cases := [][]string{
		{"--full-page"}, {"--button"}, {"--timeout", "10"}, {"--timeout", "lots"},
	}
	for _, args := range cases {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			_, err := parseBridgeArgs("click", args)
			if err == nil {
				t.Fatal("expected an error")
			}
			if _, code := bridgeErrorText(err); code != 2 {
				t.Errorf("exit code = %d, want 2, for %v", code, args)
			}
		})
	}
}

func TestParseBridgeArgsHelp(t *testing.T) {
	for _, a := range []string{"-h", "--help"} {
		o, err := parseBridgeArgs("open", []string{a})
		if err != nil {
			t.Fatalf("%s: %v", a, err)
		}
		if !o.help {
			t.Errorf("%s did not ask for help", a)
		}
	}
}

func TestBridgeParams(t *testing.T) {
	cases := []struct {
		name   string
		cmd    string
		args   []string
		action bb.ActionType
		want   string
	}{
		{"open", "open", []string{"https://example.com", "--new-tab", "--focus", "--group", "research"},
			bb.ActionNavOpen, `{"url":"https://example.com","newTab":true,"focus":true,"group":"research"}`},
		{"open plain", "open", []string{"https://example.com"},
			bb.ActionNavOpen, `{"url":"https://example.com"}`},
		{"back", "back", nil, bb.ActionNavBack, `{}`},
		{"forward", "forward", nil, bb.ActionNavForward, `{}`},
		{"reload hard", "reload", []string{"--hard"}, bb.ActionNavReload, `{"ignoreCache":true}`},
		{"url", "url", nil, bb.ActionNavURL, `{}`},
		{"read-text", "read-text", []string{"main", "--max", "500"},
			bb.ActionReadText, `{"selector":"main","maxChars":500}`},
		{"read-text whole document", "read-text", nil, bb.ActionReadText, `{}`},
		{"read-html inner", "read-html", []string{"#app", "--inner"},
			bb.ActionReadHTML, `{"selector":"#app","inner":true}`},
		{"query defaults to ten", "query", []string{"a.nav"},
			bb.ActionReadQuery, `{"selector":"a.nav","max":10}`},
		{"query attrs", "query", []string{"a.nav", "--max", "3", "--attrs"},
			bb.ActionReadQuery, `{"selector":"a.nav","max":3,"attrs":true}`},
		{"eval", "eval", []string{"document.title", "--await"},
			bb.ActionReadEval, `{"expression":"document.title","awaitPromise":true}`},
		{"screenshot", "screenshot", []string{"--full-page", "--selector", "#chart"},
			bb.ActionReadScreenshot, `{"fullPage":true,"selector":"#chart"}`},
		{"click selector", "click", []string{"button[type=submit]"},
			bb.ActionInputClick, `{"selector":"button[type=submit]"}`},
		{"click coordinates", "click", []string{"--at", "120,480", "--double", "--button", "middle"},
			bb.ActionInputClick, `{"at":{"x":120,"y":480},"double":true,"button":"middle"}`},
		{"type", "type", []string{"#user", "viktor", "--clear", "--enter", "--delay", "40"},
			bb.ActionInputType, `{"selector":"#user","text":"viktor","clear":true,"submitKey":true,"delayMs":40}`},
		{"fill one field", "fill", []string{"#user", "viktor"},
			bb.ActionInputFill, `{"fields":[{"selector":"#user","value":"viktor"}]}`},
		{"fill a form", "fill", []string{"--set", "#user=viktor", "--set", "#pass=hunter2"},
			bb.ActionInputFill, `{"fields":[{"selector":"#user","value":"viktor"},{"selector":"#pass","value":"hunter2"}]}`},
		{"select", "select", []string{"#country", "United Kingdom", "--by", "label"},
			bb.ActionInputSelect, `{"selector":"#country","value":"United Kingdom","by":"label"}`},
		{"press", "press", []string{"Enter", "--mod", "ctrl", "--mod", "shift"},
			bb.ActionInputPress, `{"key":"Enter","modifiers":["ctrl","shift"]}`},
		{"hover", "hover", []string{".menu"}, bb.ActionInputHover, `{"selector":".menu"}`},
		{"scroll to", "scroll", []string{"--to", "#footer"}, bb.ActionInputScroll, `{"selector":"#footer"}`},
		{"scroll by", "scroll", []string{"--by", "0,-400"}, bb.ActionInputScroll, `{"dy":-400}`},
		{"scroll direction", "scroll", []string{"--direction", "down", "--amount", "800"},
			bb.ActionInputScroll, `{"dy":800}`},
		{"dialog accept", "dialog", []string{"accept", "--text", "yes"},
			bb.ActionInputDialog, `{"accept":true,"promptText":"yes"}`},
		{"dialog dismiss", "dialog", []string{"dismiss"}, bb.ActionInputDialog, `{"accept":false}`},
		{"wait-for load", "wait-for", nil, bb.ActionWaitFor, `{}`},
		{"wait-for text", "wait-for", []string{"Signed in", "Welcome"},
			bb.ActionWaitFor, `{"texts":["Signed in","Welcome"]}`},
		{"wait-for selector gone", "wait-for", []string{"--selector", ".spinner", "--gone"},
			bb.ActionWaitFor, `{"selector":".spinner","gone":true}`},
		{"wait-for url", "wait-for", []string{"--url", "/dashboard"},
			bb.ActionWaitFor, `{"urlContains":"/dashboard"}`},
		{"console defaults to twenty", "console", nil, bb.ActionDiagConsole, `{"tail":20}`},
		{"console errors", "console", []string{"--level", "error", "--head", "5"},
			bb.ActionDiagConsole, `{"head":5,"level":"error"}`},
		{"console count", "console", []string{"--count"}, bb.ActionDiagConsole, `{"countOnly":true}`},
		{"network list", "network", []string{"--type", "xhr", "--type", "fetch", "--limit", "5", "--all"},
			bb.ActionDiagNetwork, `{"types":["xhr","fetch"],"limit":5,"includePreNav":true}`},
		{"network one request", "network", []string{"--id", "12", "--body", "out.json"},
			bb.ActionDiagNetwork, `{"requestId":12,"wantBody":true}`},
		{"emulate", "emulate", []string{"--color-scheme", "dark", "--cpu", "4", "--network", "slow-3g",
			"--geo", "51.5,-0.12", "--viewport", "390x844x3,mobile,touch", "--user-agent", "Mozilla/5.0"},
			bb.ActionDiagEmulate, `{"colorScheme":"dark","cpuThrottle":4,"network":"slow-3g",` +
				`"geolocation":{"lat":51.5,"lon":-0.12},"userAgent":"Mozilla/5.0",` +
				`"viewport":{"width":390,"height":844,"dpr":3,"mobile":true,"touch":true}}`},
		{"emulate reset", "emulate", []string{"--reset"}, bb.ActionDiagEmulate, `{"reset":true}`},
		{"tabs", "tabs", nil, bb.ActionTabList, `{}`},
		{"tabs mine in one window", "tabs", []string{"--window", "12", "--mine"},
			bb.ActionTabList, `{"windowId":12,"onlyAgent":true}`},
		{"attach", "attach", []string{"t_4k2p9xqa"}, bb.ActionTabAttach, `{"tab":"t_4k2p9xqa"}`},
		{"attach via the tab flag", "attach", []string{"--tab", "t_4k2p9xqa"},
			bb.ActionTabAttach, `{"tab":"t_4k2p9xqa"}`},
		{"detach one", "detach", []string{"t_4k2p9xqa"}, bb.ActionTabDetach, `{"tab":"t_4k2p9xqa"}`},
		{"detach all", "detach", []string{"--all"}, bb.ActionTabDetach, `{"all":true}`},
		{"activate", "activate", []string{"t_4k2p9xqa"}, bb.ActionTabActivate, `{"tab":"t_4k2p9xqa"}`},
		{"close-tab", "close-tab", []string{"t_4k2p9xqa"}, bb.ActionTabClose, `{"tab":"t_4k2p9xqa"}`},
		{"ping", "ping", nil, bb.ActionCtlPing, `{}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			o, err := parseBridgeArgs(c.cmd, c.args)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			action, params, err := bridgeParams(o)
			if err != nil {
				t.Fatalf("bridgeParams: %v", err)
			}
			if action != c.action {
				t.Errorf("action = %q, want %q", action, c.action)
			}
			if got := string(params); got != c.want {
				t.Errorf("params =\n %s\nwant\n %s", got, c.want)
			}
		})
	}
}

func TestBridgeParamsRejectsMissingArguments(t *testing.T) {
	cases := []struct {
		cmd  string
		args []string
		want string
	}{
		{"open", nil, "open needs a url"},
		{"query", nil, "query needs a selector"},
		{"eval", nil, "eval needs an expression"},
		{"click", nil, "click needs a selector or --at"},
		{"type", []string{"#user"}, "type needs a selector and the text"},
		{"fill", []string{"#user"}, "fill needs a selector and a value"},
		{"select", []string{"#country"}, "select needs a selector and a value"},
		{"press", nil, "press needs a key"},
		{"hover", nil, "hover needs a selector"},
		{"dialog", nil, "dialog needs accept or dismiss"},
		{"dialog", []string{"maybe"}, "dialog needs accept or dismiss"},
		{"attach", nil, "attach needs a tab handle"},
		{"activate", nil, "activate needs a tab handle"},
		{"close-tab", nil, "close-tab needs a tab handle"},
		{"detach", nil, "detach needs a tab handle or --all"},
		{"scroll", nil, "scroll needs --to <selector>, --by <dx>,<dy> or --direction"},
		{"select", []string{"#c", "UK", "--by", "colour"}, "--by takes value, label or index"},
		{"press", []string{"Enter", "--mod", "hyper"}, "--mod takes ctrl, shift, alt or meta"},
		{"click", []string{"--at", "over there"}, "--at takes <x>,<y>"},
		{"emulate", []string{"--viewport", "wide"}, "--viewport takes <width>x<height>"},
		{"emulate", []string{"--geo", "here"}, "--geo takes <lat>,<lon>"},
		{"emulate", nil, "emulate needs at least one override"},
		{"fill", []string{"--set", "#user"}, "--set takes <selector>=<value>"},
	}
	for _, c := range cases {
		t.Run(c.cmd+" "+strings.Join(c.args, " "), func(t *testing.T) {
			o, err := parseBridgeArgs(c.cmd, c.args)
			if err == nil {
				_, _, err = bridgeParams(o)
			}
			if err == nil {
				t.Fatalf("expected an error naming %q", c.want)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %q does not name %q", err, c.want)
			}
		})
	}
}

func TestRenderBridgeResult(t *testing.T) {
	cases := []struct {
		cmd    string
		args   []string
		result string
		want   []string
	}{
		{"open", []string{"https://example.com"},
			`{"tab":"t_4k2p9xqa","url":"https://example.com/","title":"Example","statusCode":200,"loadMs":412}`,
			[]string{"t_4k2p9xqa", "200", "412ms", "https://example.com/", "Example"}},
		{"url", nil,
			`{"url":"https://example.com/login","title":"Sign in","origin":"https://example.com","readyState":"complete"}`,
			[]string{"https://example.com/login", "Sign in", "complete"}},
		{"read-text", nil, `{"text":"Hello there","truncated":false}`, []string{"Hello there"}},
		{"read-text", nil, `{"text":"Hello","truncated":true}`, []string{"Hello", "truncated"}},
		{"query", []string{"a"},
			`{"count":2,"matches":[{"index":0,"tag":"a","text":"Home","visible":true},` +
				`{"index":1,"tag":"a","text":"Docs","visible":false}]}`,
			[]string{"2 matches", "[0]", "Home", "[1]", "Docs", "hidden"}},
		{"eval", []string{"1+1"}, `{"value":2,"type":"number"}`, []string{"2"}},
		{"click", []string{"#a"}, `{"clicked":true,"selector":"#a"}`, []string{"clicked", "#a"}},
		{"click", []string{"#a"}, `{"clicked":false,"selector":"#a"}`, []string{"did not click", "#a"}},
		{"type", []string{"#u", "hi"}, `{"typed":true,"chars":2}`, []string{"typed 2 characters"}},
		{"fill", []string{"#u", "x"}, `{"filled":2,"failed":[{"selector":"#p","code":"selector_not_found"}]}`,
			[]string{"filled 2", "#p", "selector_not_found"}},
		{"select", []string{"#c", "UK"}, `{"selected":"UK"}`, []string{"selected", "UK"}},
		{"press", []string{"Enter"}, `{"pressed":true}`, []string{"pressed Enter"}},
		{"hover", []string{".m"}, `{"hovered":true}`, []string{"hovered .m"}},
		{"scroll", []string{"--to", "#f"}, `{"scrollX":0,"scrollY":1200,"atBottom":true}`,
			[]string{"1200", "bottom"}},
		{"dialog", []string{"accept"}, `{"handled":true,"dialogType":"confirm","message":"Sure?"}`,
			[]string{"accepted", "confirm", "Sure?"}},
		{"wait-for", nil, `{"matched":true,"what":"load","waitedMs":812}`,
			[]string{"load", "812ms"}},
		{"wait-for", nil, `{"matched":false,"what":"text","waitedMs":30000}`,
			[]string{"no match", "30000ms"}},
		{"console", nil,
			`{"count":1,"entries":[{"at":1758380000000,"level":"error","text":"boom","source":"app.js","line":12}]}`,
			[]string{"error", "boom", "app.js:12"}},
		{"console", []string{"--count"}, `{"count":7}`, []string{"7"}},
		{"network", nil,
			`{"count":1,"requests":[{"id":3,"method":"GET","url":"https://e.com/a","status":200,"type":"xhr","bytes":91,"ms":12}]}`,
			[]string{"GET", "200", "xhr", "https://e.com/a"}},
		{"emulate", []string{"--reset"}, `{"applied":[],"cleared":["emulation","network"]}`,
			[]string{"cleared emulation, network"}},
		{"attach", []string{"t_4k2p9xqa"},
			`{"tab":"t_4k2p9xqa","title":"Sign in","origin":"https://e.com","owner":"user","bannerShown":true}`,
			[]string{"attached t_4k2p9xqa", "Sign in", "you opened", "banner"}},
		{"detach", []string{"t_4k2p9xqa"},
			`{"tab":"t_4k2p9xqa","wasAttached":true,"clearedOverrides":["emulation"]}`,
			[]string{"detached t_4k2p9xqa", "emulation"}},
		{"activate", []string{"t_4k2p9xqa"}, `{"tab":"t_4k2p9xqa","windowId":12,"focused":true}`,
			[]string{"t_4k2p9xqa", "window 12"}},
		{"close-tab", []string{"t_4k2p9xqa"}, `{"tab":"t_4k2p9xqa","closed":true,"owner":"user"}`,
			[]string{"closed t_4k2p9xqa", "you opened"}},
		{"ping", nil, `{"roundTripMs":42,"extensionVersion":"0.1.0","queueDepth":0,"attachedTabs":1}`,
			[]string{"42ms", "0.1.0", "queue 0", "1 attached"}},
	}
	for _, c := range cases {
		t.Run(c.cmd+" "+strings.Join(c.want, ","), func(t *testing.T) {
			o, err := parseBridgeArgs(c.cmd, c.args)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			got, err := renderBridgeResult(o, json.RawMessage(c.result))
			if err != nil {
				t.Fatalf("render: %v", err)
			}
			for _, want := range c.want {
				if !strings.Contains(got, want) {
					t.Errorf("output does not contain %q:\n%s", want, got)
				}
			}
		})
	}
}

// tabsFixture is the section 11.2 example, widened to three tabs so the
// renderer has an agent tab, a borrowed tab and a closed one to show.
const tabsFixture = `{
  "browserId": "b_9Qw8ErTyUiOpAsDfGhJkLm",
  "at": 1758380000000,
  "windows": [{"windowId": 12, "focused": true, "tabCount": 3, "state": "normal"}],
  "tabs": [
    {"tab":"t_4k2p9xqa","chromeTabId":4471,"title":"Sign in to Example",
     "url":"https://example.com/login","origin":"https://example.com","windowId":12,
     "index":3,"active":true,"owner":"user","attached":true,"attachedBy":"s_QaZw",
     "rebound":false,"state":"open"},
    {"tab":"t_7h3m1zzz","chromeTabId":4472,"title":"Grafana",
     "url":"https://grafana.viktorbarzin.me/d/abc","origin":"https://grafana.viktorbarzin.me",
     "windowId":12,"index":4,"owner":"agent","sessionId":"s_QaZw","attached":false,
     "rebound":true,"state":"open"},
    {"tab":"t_9z0p0aaa","chromeTabId":0,"title":"Gone","url":"https://old.example/",
     "origin":"https://old.example","windowId":12,"index":5,"owner":"user",
     "attached":false,"rebound":false,"state":"closed"}
  ],
  "truncated": false
}`

func TestRenderTabsMarksTheUsersOwnTabs(t *testing.T) {
	o, err := parseBridgeArgs("tabs", nil)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	got, err := renderBridgeResult(o, json.RawMessage(tabsFixture))
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	for _, want := range []string{
		"t_4k2p9xqa", "t_7h3m1zzz",
		"Sign in to Example", "https://example.com/login",
		"you", "agent",
		"active", "attached", "rebound", "closed",
		"3 tabs", "1 window",
		"--tab",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("tabs output does not contain %q:\n%s", want, got)
		}
	}
	// A handle is only useful if it is the first thing on the line.
	for _, line := range strings.Split(got, "\n") {
		if strings.Contains(line, "Sign in to Example") && !strings.HasPrefix(line, "t_4k2p9xqa") {
			t.Errorf("the handle is not the first column:\n%q", line)
		}
	}
}

func TestRenderTabsTruncatesLongTitles(t *testing.T) {
	long := strings.Repeat("x", 200)
	raw := `{"browserId":"b_1","at":0,"windows":[{"windowId":1,"tabCount":1}],"tabs":[
	  {"tab":"t_aaaaaaaa","title":"` + long + `","url":"https://e.com/` + long + `",
	   "origin":"https://e.com","windowId":1,"owner":"user","state":"open"}],"truncated":false}`
	o, _ := parseBridgeArgs("tabs", nil)
	got, err := renderBridgeResult(o, json.RawMessage(raw))
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	for _, line := range strings.Split(got, "\n") {
		if len([]rune(line)) > 160 {
			t.Fatalf("a %d character line is not readable at a glance:\n%q", len([]rune(line)), line)
		}
	}
}

func TestRenderStatus(t *testing.T) {
	raw := `{"server":{"version":"0.1.0","protocol":1,"storeOk":true},"user":"wizard",
	  "browser":{"browserId":"b_9Qw8Er","label":"wizard-mbp Chrome","live":true,"stopped":false,
	  "queueDepth":0,"currentAction":null,"extensionVersion":"0.1.0"},
	  "session":{"sessionId":"s_QaZw","expiresAt":1758466400000,"currentTab":"t_4k2p9xqa"}}`
	var s bb.StatusResponse
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	got := renderStatusResponse(&s)
	for _, want := range []string{"wizard", "wizard-mbp Chrome", "b_9Qw8Er", "live", "idle", "s_QaZw", "t_4k2p9xqa"} {
		if !strings.Contains(got, want) {
			t.Errorf("status output does not contain %q:\n%s", want, got)
		}
	}
}

func TestRenderStatusWithNoBrowser(t *testing.T) {
	var s bb.StatusResponse
	if err := json.Unmarshal([]byte(`{"server":{"version":"0.1.0","protocol":1,"storeOk":true},"user":"emo"}`), &s); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	got := renderStatusResponse(&s)
	for _, want := range []string{"no browser", "homelab browser bridge enrol"} {
		if !strings.Contains(got, want) {
			t.Errorf("status output does not contain %q:\n%s", want, got)
		}
	}
}

func TestRenderBrowsers(t *testing.T) {
	bs := []bb.Browser{
		{BrowserID: "b_9Qw8Er", Label: "wizard-mbp Chrome", Default: true, Live: true, QueueDepth: 2},
		{BrowserID: "b_2Zx1Cv", Label: "devvm Chrome", Live: false, Stopped: true},
	}
	got := renderBrowsersList(bs)
	for _, want := range []string{"b_9Qw8Er", "wizard-mbp Chrome", "default", "live", "b_2Zx1Cv", "stopped"} {
		if !strings.Contains(got, want) {
			t.Errorf("browsers output does not contain %q:\n%s", want, got)
		}
	}
}

func TestRenderBrowsersEmpty(t *testing.T) {
	got := renderBrowsersList(nil)
	if !strings.Contains(got, "homelab browser bridge enrol") {
		t.Errorf("an empty list must name the fix:\n%s", got)
	}
}

// The unpaired message is part of the protocol, section 5.2: an agent reads it
// and decides what to do next, so both the fix and the alternative have to be
// in it, verbatim.
func TestBridgeUnpairedErrorNamesTheFixAndTheAlternative(t *testing.T) {
	err := &bb.NoBrowserError{
		APIError: &bb.APIError{Status: 412, Code: "no_browser_live"},
		User:     "wizard", BaseURL: "https://browser-bridge.viktorbarzin.me",
	}
	text, code := bridgeErrorText(err)
	if code != 3 {
		t.Errorf("exit code = %d, want 3", code)
	}
	for _, want := range []string{
		"No browser is connected for wizard.",
		"curl -fsSL https://browser-bridge.viktorbarzin.me/install | sh",
		"homelab browser run <script.js>",
		"do not actually need the human's logged-in session",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("the unpaired message does not contain %q:\n%s", want, text)
		}
	}
	if strings.HasPrefix(text, "homelab: ") {
		t.Errorf("the protocol's message is printed as written, not prefixed:\n%s", text)
	}
}

func TestBridgeErrorTextExitCodes(t *testing.T) {
	cases := []struct {
		name string
		err  error
		code int
		want string
	}{
		{"action failed", &bb.ActionError{Code: "selector_not_found", Message: "no match"}, 1, "no match"},
		{"usage", &bb.UsageError{Message: "open needs a url"}, 2, "homelab: open needs a url"},
		{"no browser", &bb.NoBrowserError{APIError: &bb.APIError{Code: "no_browser"}}, 3, "No browser is connected."},
		{"tab gone", &bb.ActionError{Code: "tab_closed", Message: "the tab was closed"}, 4, "tab_closed"},
		{"stopped", &bb.StoppedError{APIError: &bb.APIError{Code: "stopped", Message: "kill switch"}}, 5, "kill switch"},
		{"server down", &bb.TransportError{Op: "GET /v1/status", Err: errors.New("connection refused")}, 6, "connection refused"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			text, code := bridgeErrorText(c.err)
			if code != c.code {
				t.Errorf("exit code = %d, want %d", code, c.code)
			}
			if !strings.Contains(text, c.want) {
				t.Errorf("message %q does not contain %q", text, c.want)
			}
		})
	}
}

func TestBridgeServerURL(t *testing.T) {
	t.Setenv("BROWSER_BRIDGE_SERVER", "")
	t.Setenv("BROWSER_BRIDGE_URL", "")
	if got := bridgeServerURL(bridgeOpts{}); got != bb.DefaultBaseURL {
		t.Errorf("default server = %q, want %q", got, bb.DefaultBaseURL)
	}
	t.Setenv("BROWSER_BRIDGE_SERVER", "http://dev:8080")
	if got := bridgeServerURL(bridgeOpts{}); got != "http://dev:8080" {
		t.Errorf("env server = %q", got)
	}
	if got := bridgeServerURL(bridgeOpts{server: "http://flag:9090"}); got != "http://flag:9090" {
		t.Errorf("--server did not win: %q", got)
	}
}

// The token is a credential for driving a human's logged-in browser, and this
// is a shared box.
func TestBridgeTokenRefusesAWorldReadableFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv("BROWSER_BRIDGE_TOKEN", "")
	if err := os.MkdirAll(filepath.Join(dir, "browser-bridge"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "browser-bridge", "token")
	if err := os.WriteFile(path, []byte("t0ken\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := newBridgeClient(bridgeOpts{})
	if err == nil {
		t.Fatal("a 0644 token was accepted")
	}
	text, code := bridgeErrorText(err)
	if code != 2 {
		t.Errorf("exit code = %d, want 2", code)
	}
	if !strings.Contains(text, "chmod 600") {
		t.Errorf("the error does not name the fix:\n%s", text)
	}

	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newBridgeClient(bridgeOpts{}); err != nil {
		t.Fatalf("a 0600 token was refused: %v", err)
	}
}

func TestBridgeHelpTellsTheAgentWhenNotToUseIt(t *testing.T) {
	help := bridgeHelp()
	for _, want := range []string{
		"homelab browser run",
		"every open tab",
		"logged in",
		"homelab browser bridge tabs",
		"homelab browser bridge stop",
		"--tab",
	} {
		if !strings.Contains(help, want) {
			t.Errorf("bridge help does not mention %q", want)
		}
	}
	// Help that does not fit on a screen does not get read.
	if n := strings.Count(help, "\n"); n > 90 {
		t.Errorf("bridge help is %d lines", n)
	}
}

func TestBridgeEnrolTextIsOneCommand(t *testing.T) {
	got := bridgeEnrolText("https://browser-bridge.viktorbarzin.me")
	if !strings.Contains(got, "curl -fsSL https://browser-bridge.viktorbarzin.me/install | sh") {
		t.Errorf("enrol does not print the installer one-liner:\n%s", got)
	}
	if !strings.Contains(got, "every open tab") {
		t.Errorf("enrol does not say what is being granted:\n%s", got)
	}
}

// homelab how must route "act as me on a site I am logged into" here, and must
// NOT take the anti-bot questions off `homelab browser run`.
func TestBridgeCapabilityRouting(t *testing.T) {
	cases := []struct {
		task string
		want string
	}{
		{"act as me on a site I am logged into", "browser bridge"},
		{"use my own browser session", "browser bridge"},
		{"drive the tab I already have open", "browser bridge"},
		{"read the form I half filled in", "browser bridge"},
		{"look at the tabs open on my screen", "browser bridge"},
		{"my chrome extension is not connecting", "browser bridge"},
		{"cloudflare is blocking the headless browser", "browser run"},
		{"the site flags automation and the submit silently fails", "browser run"},
	}
	for _, c := range cases {
		t.Run(c.task, func(t *testing.T) {
			hits := matchCapabilities(capabilities(), c.task)
			if len(hits) == 0 {
				t.Fatalf("no capability matched %q", c.task)
			}
			if !strings.Contains(hits[0].Use, c.want) {
				t.Fatalf("top hit for %q is %q (%s), want one naming %q",
					c.task, hits[0].Intent, hits[0].Use, c.want)
			}
		})
	}
}

func TestBridgeCapabilityIsFindableByItsWords(t *testing.T) {
	var row *capability
	for i, c := range capabilities() {
		if strings.Contains(c.Use, "browser bridge") {
			row = &capabilities()[i]
			break
		}
	}
	if row == nil {
		t.Fatal("no capability row names homelab browser bridge")
	}
	for _, syn := range []string{"tabs", "logged in", "my chrome", "extension", "already open"} {
		found := false
		for _, s := range row.Synonyms {
			if s == syn {
				found = true
			}
		}
		if !found {
			t.Errorf("the bridge capability is not findable by %q", syn)
		}
	}
	if row.Instead == "" {
		t.Error("the row names no built-in it has to beat")
	}
}
