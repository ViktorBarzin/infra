package wire

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"reflect"
	"strings"
	"testing"
)

// Every wire type round trips through JSON with every field set to something
// other than its zero value, so an omitempty that should not be there, or a
// tag that names the wrong key, shows up as a changed value rather than as a
// field quietly missing in production.

type roundTripCase interface {
	caseName() string
	typeName() string
	run(t *testing.T)
}

type rt[T any] struct {
	name string
	v    T
}

func (c rt[T]) caseName() string { return c.name }

func (c rt[T]) typeName() string {
	return reflect.TypeOf(c.v).Name()
}

func (c rt[T]) run(t *testing.T) {
	t.Helper()
	first, err := json.Marshal(c.v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var back T
	if err := json.Unmarshal(first, &back); err != nil {
		t.Fatalf("unmarshal of %s: %v", first, err)
	}
	if !reflect.DeepEqual(c.v, back) {
		t.Fatalf("value changed over a round trip\nsent: %#v\ngot:  %#v\njson: %s", c.v, back, first)
	}
	second, err := json.Marshal(back)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("encoding is not stable\nfirst:  %s\nsecond: %s", first, second)
	}
}

func ptr[T any](v T) *T { return &v }

func roundTripCases() []roundTripCase {
	box := Box{X: 12.5, Y: 480, Width: 96, Height: 32}
	tabRef := TabRef{Handle: "t_4k2p9xqa", Title: "Sign in", Origin: "https://example.com"}
	wireErr := Error{Code: CodeTabClosed, Message: "the tab was closed", Hint: "run tabs", Retryable: true}
	settings := Settings{CursorOverlay: true, GroupAgentTabs: true, GroupColor: "cyan", IdleDetachMs: 600000, ActivityMirror: true}

	return []roundTripCase{
		rt[Error]{"Error", wireErr},
		rt[ErrorEnvelope]{"ErrorEnvelope", ErrorEnvelope{Error: &wireErr}},

		rt[CreateActionRequest]{"CreateActionRequest", CreateActionRequest{
			BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm", Type: ActionInputClick,
			Params: json.RawMessage(`{"selector":"#submit"}`), Tab: "t_4k2p9xqa",
			TimeoutMs: 60000, IdempotencyKey: "retry-1",
		}},
		rt[CreateActionResponse]{"CreateActionResponse", CreateActionResponse{
			ActionID: "a_ZxCvBnMqWeRtYuIoPaSdFg", SessionID: "s_QaZwSxEdCrFvTgByHnUjMi",
			BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm", QueueDepth: 2, Lane: LaneSerial,
			CreatedAt: 1758380000000, ExpiresAt: 1758380090000,
		}},
		rt[TabRef]{"TabRef", tabRef},
		rt[BlobRef]{"BlobRef", BlobRef{BlobID: "bl_MnBvCxZlKjHgFdSaPoIu", Bytes: 148213, ContentType: "image/png"}},
		rt[ActionStatus]{"ActionStatus", ActionStatus{
			ActionID: "a_ZxCvBnMqWeRtYuIoPaSdFg", State: StateDone, QueuePosition: ptr(3), Ok: ptr(true),
			Result: json.RawMessage(`{"text":"Sign in"}`), Error: &wireErr,
			Blob: &BlobRef{BlobID: "bl_MnBvCxZlKjHgFdSaPoIu", Bytes: 1, ContentType: "image/png"},
			Tab:  &tabRef, StartedAt: 1758380000123, FinishedAt: 1758380000456,
		}},
		rt[CancelActionResponse]{"CancelActionResponse", CancelActionResponse{State: StateCancelled}},
		rt[ResultRequest]{"ResultRequest", ResultRequest{
			ActionID: "a_ZxCvBnMqWeRtYuIoPaSdFg", Ok: true, Result: json.RawMessage(`{"text":"Sign in"}`),
			Error: &wireErr, BlobID: "bl_MnBvCxZlKjHgFdSaPoIu", Tab: &tabRef,
			StartedAt: 1758380000123, FinishedAt: 1758380000456,
		}},
		rt[ResultResponse]{"ResultResponse", ResultResponse{Ok: true, Duplicate: true}},

		rt[EmptyParams]{"EmptyParams", EmptyParams{}},
		rt[Point]{"Point", Point{X: 41.5, Y: 92}},
		rt[GeoPoint]{"GeoPoint", GeoPoint{Lat: 51.5072, Lon: -0.1276}},
		rt[Viewport]{"Viewport", Viewport{Width: 390, Height: 844, DPR: 3, Mobile: true, Touch: true}},
		rt[OpenParams]{"OpenParams", OpenParams{URL: "https://example.com", NewTab: true, Focus: true, Group: "research"}},
		rt[ReloadParams]{"ReloadParams", ReloadParams{IgnoreCache: true}},
		rt[ReadTextParams]{"ReadTextParams", ReadTextParams{Selector: "main", MaxChars: 5000}},
		rt[ReadHTMLParams]{"ReadHTMLParams", ReadHTMLParams{Selector: "main", Inner: true}},
		rt[QueryParams]{"QueryParams", QueryParams{Selector: "a[href]", Max: 10, Attrs: true}},
		rt[EvalParams]{"EvalParams", EvalParams{Expression: "document.title", AwaitPromise: true}},
		rt[ScreenshotParams]{"ScreenshotParams", ScreenshotParams{FullPage: true, Selector: "#chart", Format: "png", Quality: 80}},
		rt[ClickParams]{"ClickParams", ClickParams{Selector: "#submit", At: &Point{X: 10, Y: 20}, Double: true, Button: ButtonRight}},
		rt[TypeParams]{"TypeParams", TypeParams{Selector: "#q", Text: "hello", Clear: true, SubmitKey: true, DelayMs: 30}},
		rt[FillField]{"FillField", FillField{Selector: "#user", Value: "wizard"}},
		rt[FillParams]{"FillParams", FillParams{Fields: []FillField{{Selector: "#user", Value: "wizard"}}}},
		rt[SelectParams]{"SelectParams", SelectParams{Selector: "#country", Value: "BG", By: SelectByLabel}},
		rt[PressParams]{"PressParams", PressParams{Key: "Enter", Modifiers: []Modifier{ModCtrl, ModShift}}},
		rt[HoverParams]{"HoverParams", HoverParams{Selector: "nav a"}},
		rt[ScrollParams]{"ScrollParams", ScrollParams{Selector: "#footer", DX: 10, DY: -200}},
		rt[DialogParams]{"DialogParams", DialogParams{Accept: true, PromptText: "yes"}},
		rt[WaitForParams]{"WaitForParams", WaitForParams{Texts: []string{"Welcome"}, Selector: "#done", Gone: true, URLContains: "/inbox"}},
		rt[ConsoleParams]{"ConsoleParams", ConsoleParams{Tail: 20, Head: 5, Level: LevelError, CountOnly: true, Clear: true}},
		rt[NetworkParams]{"NetworkParams", NetworkParams{RequestID: 7, Types: []string{"xhr", "fetch"}, Limit: 50, IncludePreNav: true, WantBody: true}},
		rt[EmulateParams]{"EmulateParams", EmulateParams{
			ColorScheme: SchemeDark, CPUThrottle: 4, Network: NetSlow3G, Geolocation: &GeoPoint{Lat: 1, Lon: 2},
			UserAgent: "bb/0.1", Viewport: &Viewport{Width: 390, Height: 844, DPR: 3, Mobile: true, Touch: true},
			ExtraHeaders: map[string]string{"X-Debug": "1"}, Reset: true,
		}},
		rt[TabListParams]{"TabListParams", TabListParams{WindowID: 12, OnlyAgent: true}},
		rt[AttachParams]{"AttachParams", AttachParams{Tab: "t_4k2p9xqa"}},
		rt[DetachParams]{"DetachParams", DetachParams{Tab: "t_4k2p9xqa", All: true}},
		rt[ActivateParams]{"ActivateParams", ActivateParams{Tab: "t_4k2p9xqa"}},
		rt[CloseTabParams]{"CloseTabParams", CloseTabParams{Tab: "t_4k2p9xqa"}},

		rt[Box]{"Box", box},
		rt[OpenResult]{"OpenResult", OpenResult{Tab: "t_4k2p9xqa", URL: "https://example.com", Title: "Example", StatusCode: 200, LoadMs: 812}},
		rt[NavResult]{"NavResult", NavResult{URL: "https://example.com", Title: "Example"}},
		rt[ReloadResult]{"ReloadResult", ReloadResult{URL: "https://example.com", Title: "Example", LoadMs: 91}},
		rt[URLResult]{"URLResult", URLResult{URL: "https://example.com/a", Title: "A", Origin: "https://example.com", ReadyState: "complete"}},
		rt[ReadTextResult]{"ReadTextResult", ReadTextResult{Text: "Sign in", Truncated: true}},
		rt[ReadHTMLResult]{"ReadHTMLResult", ReadHTMLResult{HTML: "<h1>Sign in</h1>", Truncated: true}},
		rt[QueryMatch]{"QueryMatch", QueryMatch{Index: 1, Tag: "button", Text: "Sign in", Attrs: map[string]string{"type": "submit"}, Visible: true, Box: &box}},
		rt[QueryResult]{"QueryResult", QueryResult{Count: 1, Matches: []QueryMatch{{Index: 0, Tag: "a", Text: "Home", Visible: true}}}},
		rt[EvalResult]{"EvalResult", EvalResult{Value: json.RawMessage(`{"ok":true}`), Type: "object"}},
		rt[ScreenshotResult]{"ScreenshotResult", ScreenshotResult{BlobID: "bl_MnBvCxZlKjHgFdSaPoIu", Width: 1512, Height: 982, Bytes: 148213}},
		rt[ClickResult]{"ClickResult", ClickResult{Clicked: true, Selector: "#submit", Box: &box}},
		rt[TypeResult]{"TypeResult", TypeResult{Typed: true, Chars: 5}},
		rt[FillFailure]{"FillFailure", FillFailure{Selector: "#missing", Code: CodeSelectorNotFound, Message: "no match"}},
		rt[FillResult]{"FillResult", FillResult{Filled: 3, Failed: []FillFailure{{Selector: "#x", Code: CodeSelectorNotFound}}}},
		rt[SelectResult]{"SelectResult", SelectResult{Selected: "BG", Options: []string{"BG", "UK"}}},
		rt[PressResult]{"PressResult", PressResult{Pressed: true}},
		rt[HoverResult]{"HoverResult", HoverResult{Hovered: true, Box: &box}},
		rt[ScrollResult]{"ScrollResult", ScrollResult{ScrollX: 0, ScrollY: 1200.5, AtBottom: true}},
		rt[DialogResult]{"DialogResult", DialogResult{Handled: true, DialogType: "confirm", Message: "Are you sure?"}},
		rt[WaitForResult]{"WaitForResult", WaitForResult{Matched: true, What: "selector", WaitedMs: 1840}},
		rt[ConsoleEntry]{"ConsoleEntry", ConsoleEntry{At: 1758380000456, Level: LevelError, Text: "boom", Source: "app.js", Line: 42}},
		rt[ConsoleResult]{"ConsoleResult", ConsoleResult{Count: 1, Entries: []ConsoleEntry{{At: 1, Level: LevelWarn, Text: "slow"}}}},
		rt[NetworkRequest]{"NetworkRequest", NetworkRequest{ID: 7, Method: "POST", URL: "https://example.com/login", Status: 302, Type: "document", Bytes: 1841, Ms: 219}},
		rt[NetworkRequestDetail]{"NetworkRequestDetail", NetworkRequestDetail{
			NetworkRequest:  NetworkRequest{ID: 7, Method: "POST", URL: "https://example.com/login", Status: 302, Type: "document", Bytes: 1841, Ms: 219},
			RequestHeaders:  map[string]string{"Accept": "*/*"},
			ResponseHeaders: map[string]string{"Location": "/inbox"},
			PostData:        "user=wizard", MimeType: "text/html",
		}},
		rt[NetworkResult]{"NetworkResult", NetworkResult{
			Count:    1,
			Requests: []NetworkRequest{{ID: 7, Method: "GET", URL: "https://example.com", Status: 200, Type: "document", Bytes: 10, Ms: 5}},
			Request: &NetworkRequestDetail{
				NetworkRequest: NetworkRequest{ID: 7, Method: "GET", URL: "https://example.com", Status: 200, Type: "document", Bytes: 10, Ms: 5},
				MimeType:       "text/html",
			},
			ResponseBlobID: "bl_MnBvCxZlKjHgFdSaPoIu",
		}},
		rt[EmulateResult]{"EmulateResult", EmulateResult{Applied: []string{"viewport"}, Cleared: []string{"network"}}},
		rt[TabGroup]{"TabGroup", TabGroup{GroupID: 88, Title: "agent wizard@devvm", Color: "cyan"}},
		rt[WindowInfo]{"WindowInfo", WindowInfo{WindowID: 12, Focused: true, TabCount: 9, State: "normal"}},
		rt[TabInfo]{"TabInfo", TabInfo{
			Tab: "t_4k2p9xqa", ChromeTabID: 4471, Title: "Sign in", URL: "https://example.com/login",
			Origin: "https://example.com", WindowID: 12, Index: 3, Active: true, Audible: true, Discarded: true,
			Group: &TabGroup{GroupID: 88, Title: "agent", Color: "cyan"}, Owner: OwnerUser,
			SessionID: "s_QaZwSxEdCrFvTgByHnUjMi", Attached: true, AttachedBy: "s_QaZwSxEdCrFvTgByHnUjMi",
			AttachedAt: 1758379000000, Rebound: true, State: TabOpen,
		}},
		rt[TabListResult]{"TabListResult", TabListResult{
			BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm", At: 1758380000000,
			Windows:   []WindowInfo{{WindowID: 12, Focused: true, TabCount: 1, State: "normal"}},
			Tabs:      []TabInfo{{Tab: "t_4k2p9xqa", ChromeTabID: 1, Owner: OwnerAgent, State: TabOpen}},
			Truncated: true,
		}},
		rt[AttachResult]{"AttachResult", AttachResult{Tab: "t_4k2p9xqa", Title: "Sign in", Origin: "https://example.com", Owner: OwnerUser, BannerShown: true}},
		rt[DetachResult]{"DetachResult", DetachResult{Tab: "t_4k2p9xqa", WasAttached: true, ClearedOverrides: []string{"emulation", "network"}}},
		rt[ActivateResult]{"ActivateResult", ActivateResult{Tab: "t_4k2p9xqa", WindowID: 12, Focused: true}},
		rt[CloseTabResult]{"CloseTabResult", CloseTabResult{Tab: "t_4k2p9xqa", Closed: true, Owner: OwnerUser}},
		rt[PingResult]{"PingResult", PingResult{RoundTripMs: 41, ExtensionVersion: "0.1.0", QueueDepth: 2, AttachedTabs: 3}},

		rt[ReadyFrame]{"ReadyFrame", ReadyFrame{
			V: Version, Seq: 1, BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm", ServerTime: 1758380000000,
			ServerVersion: "0.1.0", HeartbeatMs: HeartbeatMs, StopEpoch: 7, ReplayCount: 2,
			EnrolmentExpiresAt: 1760972000000,
		}},
		rt[HeartbeatFrame]{"HeartbeatFrame", HeartbeatFrame{V: Version, Seq: 42, ServerTime: 1758380015000, QueueDepth: 1}},
		rt[ActionFrame]{"ActionFrame", ActionFrame{
			V: Version, Seq: 43, ActionID: "a_ZxCvBnMqWeRtYuIoPaSdFg", SessionID: "s_QaZwSxEdCrFvTgByHnUjMi",
			Type: ActionInputClick, Params: json.RawMessage(`{"selector":"#submit"}`), Tab: "t_4k2p9xqa",
			CreatedAt: 1758380000000, TimeoutMs: 60000, ExpiresAt: 1758380090000, Lane: LaneSerial,
			Replay: true, AgentLabel: "wizard@devvm",
		}},
		rt[CancelFrame]{"CancelFrame", CancelFrame{V: Version, Seq: 44, ActionID: "a_ZxCvBnMqWeRtYuIoPaSdFg", Reason: ReasonExpired}},
		rt[ControlFrame]{"ControlFrame", ControlFrame{V: Version, Seq: 45, Op: OpStop, StopEpoch: 8, Reason: "the human pulled it"}},
		rt[SettingsFrame]{"SettingsFrame", SettingsFrame{V: Version, Seq: 2, Settings: settings, Label: "wizard-mbp Chrome", Version: 12}},
		rt[ErrorFrame]{"ErrorFrame", ErrorFrame{V: Version, Seq: 46, Code: CodeStoreUnavailable, Message: "redis is unreachable"}},

		rt[Browser]{"Browser", Browser{
			BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm", Label: "wizard-mbp Chrome", Default: true, Live: true,
			LastSeenAt: 1758380000000, EnrolledAt: 1755780000000, ExpiresAt: 1760972000000,
			ExtensionVersion: "0.1.0", QueueDepth: 1, StopEpoch: 7, Stopped: true,
		}},
		rt[BrowsersResponse]{"BrowsersResponse", BrowsersResponse{Browsers: []Browser{{BrowserID: "b_x", Label: "l"}}}},
		rt[ServerInfo]{"ServerInfo", ServerInfo{Version: "0.1.0", Protocol: Version, StoreOk: true}},
		rt[BrowserStatus]{"BrowserStatus", BrowserStatus{
			BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm", Label: "wizard-mbp Chrome", Live: true, Stopped: true,
			QueueDepth: 2, CurrentAction: ptr("a_ZxCvBnMqWeRtYuIoPaSdFg"), ExtensionVersion: "0.1.0",
		}},
		rt[SessionInfo]{"SessionInfo", SessionInfo{SessionID: "s_QaZwSxEdCrFvTgByHnUjMi", ExpiresAt: 1758466400000, CurrentTab: "t_4k2p9xqa"}},
		rt[StatusResponse]{"StatusResponse", StatusResponse{
			Server: ServerInfo{Version: "0.1.0", Protocol: Version, StoreOk: true}, User: "wizard",
			Browser: &BrowserStatus{BrowserID: "b_x", CurrentAction: nil},
			Session: &SessionInfo{SessionID: "s_y", ExpiresAt: 1},
		}},
		rt[Settings]{"Settings", settings},
		rt[SettingsPatch]{"SettingsPatch", SettingsPatch{
			CursorOverlay: ptr(true), GroupAgentTabs: ptr(false), GroupColor: ptr("orange"),
			IdleDetachMs: ptr(300000), ActivityMirror: ptr(false),
		}},
		rt[PatchBrowserRequest]{"PatchBrowserRequest", PatchBrowserRequest{Label: "laptop", Settings: &SettingsPatch{CursorOverlay: ptr(true)}}},
		rt[EnrolRequest]{"EnrolRequest", EnrolRequest{ExtensionID: "abcdefghijklmnopabcdefghijklmnop", Nonce: "3f2a", Label: "laptop"}},
		rt[EnrolResponse]{"EnrolResponse", EnrolResponse{BrowserID: "b_x", BrowserKey: "k", ExpiresAt: 1, Default: true}},
		rt[PairRequest]{"PairRequest", PairRequest{Label: "work laptop"}},
		rt[PairResponse]{"PairResponse", PairResponse{Code: "K7M2QX", ExpiresAt: 1758380600000, AttemptsLeft: 5}},
		rt[PairRedeemRequest]{"PairRedeemRequest", PairRedeemRequest{Code: "K7M2QX", ExtensionID: "abc", Label: "work laptop"}},
		rt[PairRedeemResponse]{"PairRedeemResponse", PairRedeemResponse{BrowserID: "b_x", BrowserKey: "k", Owner: "wizard", ExpiresAt: 1}},
		rt[StopRequest]{"StopRequest", StopRequest{BrowserID: "b_9Qw8ErTyUiOpAsDfGhJkLm"}},
		rt[StopResponse]{"StopResponse", StopResponse{BrowserID: "b_x", StopEpoch: 7, Cancelled: 3, BrowserLive: true}},
		rt[AdminTokenRequest]{"AdminTokenRequest", AdminTokenRequest{OSUser: "emo", AuthentikUser: "emo"}},
		rt[AdminTokenResponse]{"AdminTokenResponse", AdminTokenResponse{Token: "t", OSUser: "emo"}},
		rt[QueueStateRequest]{"QueueStateRequest", QueueStateRequest{QueueDepth: 2, OffQueueCount: 1, CurrentAction: "a_x", AttachedTabs: 3}},
		rt[OkResponse]{"OkResponse", OkResponse{Ok: true}},

		rt[ActivityEntry]{"ActivityEntry", ActivityEntry{
			Seq: 412, At: 1758380000456, Kind: ActivityAction, Type: ActionInputClick,
			ActionID: "a_x", SessionID: "s_y", AgentLabel: "wizard@devvm", Tab: "t_4k2p9xqa",
			Title: "Sign in", Origin: "https://example.com", Path: "/login", Owner: OwnerUser,
			Outcome: OutcomeOK, DurationMs: 312,
		}},
		rt[ActivityResponse]{"ActivityResponse", ActivityResponse{Entries: []ActivityEntry{{Seq: 1, At: 2, Kind: ActivityStop}}}},
		rt[ActivityPushRequest]{"ActivityPushRequest", ActivityPushRequest{Entries: []ActivityEntry{{Seq: 1, At: 2, Kind: ActivityResume}}}},
		rt[ActivityPushResponse]{"ActivityPushResponse", ActivityPushResponse{Accepted: 12}},
		rt[BlobUploadResponse]{"BlobUploadResponse", BlobUploadResponse{BlobID: "bl_x", Bytes: 148213, ExpiresAt: 1758380600000}},
	}
}

func TestRoundTrip(t *testing.T) {
	for _, c := range roundTripCases() {
		t.Run(c.caseName(), c.run)
	}
}

// notJSONTypes are the exported structs that never cross the wire as a JSON
// body, with the reason.
var notJSONTypes = map[string]string{
	"EventID": "the SSE id line, rendered as <streamEpoch>.<seq> rather than as JSON",
}

// TestEveryExportedStructIsRoundTripped reads this package's own source and
// fails when a type was added without a round-trip case. Without it the table
// above rots the first time someone adds a field to the protocol.
func TestEveryExportedStructIsRoundTripped(t *testing.T) {
	covered := map[string]bool{}
	for _, c := range roundTripCases() {
		covered[c.typeName()] = true
	}

	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi fs.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatalf("parsing the package: %v", err)
	}
	found := 0
	for _, pkg := range pkgs {
		for _, file := range pkg.Files {
			for _, decl := range file.Decls {
				gen, ok := decl.(*ast.GenDecl)
				if !ok || gen.Tok != token.TYPE {
					continue
				}
				for _, spec := range gen.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || !ts.Name.IsExported() {
						continue
					}
					if _, ok := ts.Type.(*ast.StructType); !ok {
						continue
					}
					found++
					name := ts.Name.Name
					if _, skip := notJSONTypes[name]; skip {
						continue
					}
					if !covered[name] {
						t.Errorf("%s has no round-trip case in roundTripCases()", name)
					}
				}
			}
		}
	}
	if found < 50 {
		t.Fatalf("only found %d exported structs, the source scan is not working", found)
	}
}

func TestEventID(t *testing.T) {
	cases := []struct {
		in      string
		want    EventID
		wantErr bool
	}{
		{"4.118", EventID{StreamEpoch: 4, Seq: 118}, false},
		{"1758380000000.1", EventID{StreamEpoch: 1758380000000, Seq: 1}, false},
		{"4", EventID{}, true},
		{"x.1", EventID{}, true},
		{"4.x", EventID{}, true},
		{"-4.1", EventID{}, true},
		{"", EventID{}, true},
	}
	for _, c := range cases {
		t.Run(c.in, func(t *testing.T) {
			got, err := ParseEventID(c.in)
			if c.wantErr {
				if err == nil {
					t.Fatalf("ParseEventID(%q) returned %+v, want an error", c.in, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseEventID(%q): %v", c.in, err)
			}
			if got != c.want {
				t.Fatalf("ParseEventID(%q) = %+v, want %+v", c.in, got, c.want)
			}
			if round := got.String(); round != c.in {
				t.Fatalf("String() = %q, want %q", round, c.in)
			}
		})
	}
}

func TestEnumValidators(t *testing.T) {
	type enumCase struct {
		name  string
		valid bool
		got   bool
	}
	cases := []enumCase{
		{"EventName ready", true, EventReady.Valid()},
		{"EventName message", false, EventName("message").Valid()},
		{"ControlOp stop", true, OpStop.Valid()},
		{"ControlOp nope", false, ControlOp("nope").Valid()},
		{"CancelReason expired", true, ReasonExpired.Valid()},
		{"CancelReason nope", false, CancelReason("nope").Valid()},
		{"MouseButton empty means left", true, MouseButton("").Valid()},
		{"MouseButton scroll", false, MouseButton("scroll").Valid()},
		{"Modifier ctrl", true, ModCtrl.Valid()},
		{"Modifier empty", false, Modifier("").Valid()},
		{"SelectBy empty means value", true, SelectBy("").Valid()},
		{"SelectBy regex", false, SelectBy("regex").Valid()},
		{"ConsoleLevel empty means all", true, ConsoleLevel("").Valid()},
		{"ConsoleLevel trace", false, ConsoleLevel("trace").Valid()},
		{"ColorScheme dark", true, SchemeDark.Valid()},
		{"ColorScheme sepia", false, ColorScheme("sepia").Valid()},
		{"NetworkProfile slow-3g", true, NetSlow3G.Valid()},
		{"NetworkProfile dialup", false, NetworkProfile("dialup").Valid()},
		{"TabOwner user", true, OwnerUser.Valid()},
		{"TabOwner nobody", false, TabOwner("nobody").Valid()},
		{"TabState closed", true, TabClosed.Valid()},
		{"TabState frozen", false, TabState("frozen").Valid()},
		{"ActivityKind autoDetach", true, ActivityAutoDetach.Valid()},
		{"ActivityKind gossip", false, ActivityKind("gossip").Valid()},
		{"ActivityOutcome running", true, OutcomeRunning.Valid()},
		{"ActivityOutcome maybe", false, ActivityOutcome("maybe").Valid()},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.got != c.valid {
				t.Fatalf("Valid() = %v, want %v", c.got, c.valid)
			}
		})
	}
}
