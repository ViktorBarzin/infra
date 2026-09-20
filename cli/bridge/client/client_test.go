package client

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ViktorBarzin/browser-bridge/internal/wire"
)

const (
	testToken     = "t0ken-for-tests"
	testActionID  = "a_ZxCvBnMqWeRtYuIoPaSdFg"
	testSessionID = "s_QaZwSxEdCrFvTgByHnUjMi"
	testBrowserID = "b_9Qw8ErTyUiOpAsDfGhJkLm"
)

// newTestClient points a client at ts with a backoff short enough that a test
// waiting on three polls finishes in milliseconds.
func newTestClient(t *testing.T, ts *httptest.Server, opts ...Option) *Client {
	t.Helper()
	all := append([]Option{WithBackoff(time.Millisecond, 5*time.Millisecond), WithUser("wizard")}, opts...)
	c, err := New(ts.URL, testToken, all...)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return c
}

func writeJSON(t *testing.T, w http.ResponseWriter, status int, body string) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if _, err := io.WriteString(w, body); err != nil {
		t.Errorf("writing the stub response: %v", err)
	}
}

func createdBody() string {
	return `{"actionId":"` + testActionID + `","sessionId":"` + testSessionID + `","browserId":"` + testBrowserID +
		`","queueDepth":0,"lane":"serial","createdAt":1758380000000,"expiresAt":4102444800000}`
}

func TestRunReturnsAnImmediateResult(t *testing.T) {
	var posted wire.CreateActionRequest
	var pollWait atomic.Value
	var polls atomic.Int32

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer "+testToken {
			t.Errorf("Authorization = %q", got)
		}
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/actions":
			if got := r.Header.Get("Content-Type"); got != "application/json" {
				t.Errorf("Content-Type = %q", got)
			}
			if err := json.NewDecoder(r.Body).Decode(&posted); err != nil {
				t.Errorf("decoding the posted action: %v", err)
			}
			writeJSON(t, w, http.StatusCreated, createdBody())
		case r.Method == http.MethodGet && r.URL.Path == "/v1/actions/"+testActionID:
			polls.Add(1)
			pollWait.Store(r.URL.Query().Get("wait"))
			writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"done","ok":true,
				"result":{"clicked":true,"selector":"#submit"},
				"tab":{"handle":"t_4k2p9xqa","title":"Sign in","origin":"https://example.com"}}`)
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusTeapot)
		}
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	got, err := c.Click(context.Background(),
		Target{Tab: "t_4k2p9xqa", Timeout: 90 * time.Second, IdempotencyKey: "k1"},
		wire.ClickParams{Selector: "#submit"})
	if err != nil {
		t.Fatalf("Click: %v", err)
	}
	if !got.Clicked || got.Selector != "#submit" {
		t.Fatalf("result = %+v", got)
	}
	if posted.Type != wire.ActionInputClick {
		t.Fatalf("posted type = %q", posted.Type)
	}
	if posted.Tab != "t_4k2p9xqa" || posted.TimeoutMs != 90000 || posted.IdempotencyKey != "k1" {
		t.Fatalf("posted = %+v", posted)
	}
	var params wire.ClickParams
	if err := json.Unmarshal(posted.Params, &params); err != nil {
		t.Fatalf("posted params: %v", err)
	}
	if params.Selector != "#submit" {
		t.Fatalf("posted params = %+v", params)
	}
	if n := polls.Load(); n != 1 {
		t.Fatalf("polled %d times, want 1", n)
	}
	if w, _ := pollWait.Load().(string); w == "" || w == "0" {
		t.Fatalf("the poll did not ask the server to hold the request: wait=%q", w)
	}
}

func TestRunReturnsAResultAfterThreePolls(t *testing.T) {
	var polls atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writeJSON(t, w, http.StatusCreated, createdBody())
			return
		}
		if n := polls.Add(1); n <= 3 {
			writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"running","queuePosition":0}`)
			return
		}
		writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"done","ok":true,"result":{"text":"Sign in","truncated":false}}`)
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	got, err := c.ReadText(context.Background(), Target{}, wire.ReadTextParams{Selector: "main"})
	if err != nil {
		t.Fatalf("ReadText: %v", err)
	}
	if got.Text != "Sign in" {
		t.Fatalf("result = %+v", got)
	}
	if n := polls.Load(); n != 4 {
		t.Fatalf("polled %d times, want 4 (three running, then the result)", n)
	}
}

func TestRunGivesUpAtTheDeadline(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writeJSON(t, w, http.StatusCreated, createdBody())
			return
		}
		writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"running"}`)
	}))
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	c := newTestClient(t, ts, WithBackoff(10*time.Millisecond, 20*time.Millisecond))
	start := time.Now()
	_, err := c.ReadText(ctx, Target{}, wire.ReadTextParams{})
	if err == nil {
		t.Fatal("want a timeout, got a result")
	}
	var timeout *TimeoutError
	if !errors.As(err, &timeout) {
		t.Fatalf("want a *TimeoutError, got %T: %v", err, err)
	}
	if timeout.ActionID != testActionID {
		t.Fatalf("the timeout does not name the action: %+v", timeout)
	}
	if ExitCode(err) != 1 {
		t.Fatalf("ExitCode = %d, want 1", ExitCode(err))
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("waited %s past a 200ms deadline", elapsed)
	}
}

func TestEnqueueOn500IsAServerProblem(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, http.StatusInternalServerError, `{"error":{"code":"internal","message":"a server bug","retryable":true}}`)
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	_, err := c.Ping(context.Background(), Target{})
	var transport *TransportError
	if !errors.As(err, &transport) {
		t.Fatalf("want a *TransportError, got %T: %v", err, err)
	}
	if transport.Status != http.StatusInternalServerError {
		t.Fatalf("status = %d", transport.Status)
	}
	if ExitCode(err) != 6 {
		t.Fatalf("ExitCode = %d, want 6", ExitCode(err))
	}
	if !strings.Contains(err.Error(), "a server bug") {
		t.Fatalf("the error drops the server's message: %v", err)
	}
}

func TestPollRetriesA500AndThenSucceeds(t *testing.T) {
	var polls atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writeJSON(t, w, http.StatusCreated, createdBody())
			return
		}
		if polls.Add(1) == 1 {
			writeJSON(t, w, http.StatusServiceUnavailable, `{"error":{"code":"store_unavailable","message":"redis is unreachable","retryable":true}}`)
			return
		}
		writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"done","ok":true,"result":{"pressed":true}}`)
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	got, err := c.Press(context.Background(), Target{}, wire.PressParams{Key: "Enter"})
	if err != nil {
		t.Fatalf("Press: %v", err)
	}
	if !got.Pressed {
		t.Fatalf("result = %+v", got)
	}
	if n := polls.Load(); n != 2 {
		t.Fatalf("polled %d times, want 2", n)
	}
}

func TestPollKeepsFailingIsAServerProblem(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writeJSON(t, w, http.StatusCreated, createdBody())
			return
		}
		writeJSON(t, w, http.StatusInternalServerError, `{"error":{"code":"internal","message":"still broken"}}`)
	}))
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	c := newTestClient(t, ts, WithBackoff(10*time.Millisecond, 20*time.Millisecond))
	_, err := c.URL(ctx, Target{}, wire.EmptyParams{})
	var transport *TransportError
	if !errors.As(err, &transport) {
		t.Fatalf("want a *TransportError, got %T: %v", err, err)
	}
	if ExitCode(err) != 6 {
		t.Fatalf("ExitCode = %d, want 6", ExitCode(err))
	}
}

func TestServerDownIsAServerProblem(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := ts.URL
	ts.Close()

	c, err := New(url, testToken, WithBackoff(time.Millisecond, 2*time.Millisecond))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := c.Status(context.Background()); err == nil {
		t.Fatal("want an error against a closed server")
	} else {
		var transport *TransportError
		if !errors.As(err, &transport) {
			t.Fatalf("want a *TransportError, got %T: %v", err, err)
		}
		if ExitCode(err) != 6 {
			t.Fatalf("ExitCode = %d, want 6", ExitCode(err))
		}
	}
}

func TestNoBrowserEnrolled(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"404 no_browser", http.StatusNotFound, `{"error":{"code":"no_browser","message":"unknown browser"}}`},
		{"412 no_browser_live", http.StatusPreconditionFailed, `{"error":{"code":"no_browser_live","message":"no extension stream is open","retryable":true}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				writeJSON(t, w, tc.status, tc.body)
			}))
			defer ts.Close()

			c := newTestClient(t, ts)
			_, err := c.Tabs(context.Background(), Target{}, wire.TabListParams{})
			var noBrowser *NoBrowserError
			if !errors.As(err, &noBrowser) {
				t.Fatalf("want a *NoBrowserError, got %T: %v", err, err)
			}
			if ExitCode(err) != 3 {
				t.Fatalf("ExitCode = %d, want 3", ExitCode(err))
			}
			msg := err.Error()
			for _, want := range []string{
				"No browser is connected for wizard",
				"/install | sh",
				"homelab browser run",
			} {
				if !strings.Contains(msg, want) {
					t.Fatalf("the message does not name %q:\n%s", want, msg)
				}
			}
		})
	}
}

func TestActionFailedInTheBrowser(t *testing.T) {
	cases := []struct {
		name     string
		code     wire.ErrorCode
		exitCode int
	}{
		{"a tab that is gone", wire.CodeTabClosed, 4},
		{"a tab another session holds", wire.CodeTabHeld, 4},
		{"a selector that matched nothing", wire.CodeSelectorNotFound, 1},
		{"the kill switch landed mid-action", wire.CodeStopped, 5},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					writeJSON(t, w, http.StatusCreated, createdBody())
					return
				}
				writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"done","ok":false,
					"error":{"code":"`+string(tc.code)+`","message":"it did not work","hint":"try t_4k2p9xqa"},
					"tab":{"handle":"t_4k2p9xqa","title":"Sign in","origin":"https://example.com"}}`)
			}))
			defer ts.Close()

			c := newTestClient(t, ts)
			_, err := c.Click(context.Background(), Target{Tab: "t_4k2p9xqa"}, wire.ClickParams{Selector: "#submit"})
			var actionErr *ActionError
			if !errors.As(err, &actionErr) {
				t.Fatalf("want an *ActionError, got %T: %v", err, err)
			}
			if actionErr.Code != tc.code {
				t.Fatalf("code = %q, want %q", actionErr.Code, tc.code)
			}
			if actionErr.ActionID != testActionID || actionErr.Tab != "t_4k2p9xqa" {
				t.Fatalf("the error does not name the action and tab: %+v", actionErr)
			}
			if actionErr.Hint != "try t_4k2p9xqa" {
				t.Fatalf("the hint was dropped: %+v", actionErr)
			}
			if got := ExitCode(err); got != tc.exitCode {
				t.Fatalf("ExitCode = %d, want %d", got, tc.exitCode)
			}
		})
	}
}

func TestExpiredActionIsAFailure(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writeJSON(t, w, http.StatusCreated, createdBody())
			return
		}
		writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"expired",
			"error":{"code":"expired","message":"no result arrived before the cutoff"}}`)
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	_, err := c.Hover(context.Background(), Target{}, wire.HoverParams{Selector: "nav"})
	var actionErr *ActionError
	if !errors.As(err, &actionErr) {
		t.Fatalf("want an *ActionError, got %T: %v", err, err)
	}
	if actionErr.State != wire.StateExpired || actionErr.Code != wire.CodeExpired {
		t.Fatalf("error = %+v", actionErr)
	}
}

func TestKillSwitchPulled(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, http.StatusLocked, `{"error":{"code":"stopped","message":"the kill switch was pulled","hint":"resume in the popup"}}`)
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	_, err := c.Open(context.Background(), Target{}, wire.OpenParams{URL: "https://example.com"})
	var stopped *StoppedError
	if !errors.As(err, &stopped) {
		t.Fatalf("want a *StoppedError, got %T: %v", err, err)
	}
	if ExitCode(err) != 5 {
		t.Fatalf("ExitCode = %d, want 5", ExitCode(err))
	}
	if !strings.Contains(err.Error(), "resume in the popup") {
		t.Fatalf("the hint was dropped: %v", err)
	}
}

func TestPlumbingRoutes(t *testing.T) {
	var seen atomic.Value
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen.Store(r.Method + " " + r.URL.Path + "?" + r.URL.RawQuery)
		switch r.URL.Path {
		case "/v1/status":
			writeJSON(t, w, http.StatusOK, `{"server":{"version":"0.1.0","protocol":1,"storeOk":true},"user":"wizard",
				"browser":{"browserId":"`+testBrowserID+`","label":"mbp","live":true,"stopped":false,"queueDepth":0,"currentAction":null},
				"session":{"sessionId":"`+testSessionID+`","expiresAt":1758466400000,"currentTab":"t_4k2p9xqa"}}`)
		case "/v1/browsers":
			writeJSON(t, w, http.StatusOK, `{"browsers":[{"browserId":"`+testBrowserID+`","label":"mbp","default":true,"live":true,
				"lastSeenAt":1,"enrolledAt":2,"expiresAt":3,"queueDepth":0,"stopEpoch":7,"stopped":false}]}`)
		case "/v1/control/stop":
			writeJSON(t, w, http.StatusOK, `{"browserId":"`+testBrowserID+`","stopEpoch":8,"cancelled":3,"browserLive":true}`)
		case "/v1/activity":
			writeJSON(t, w, http.StatusOK, `{"entries":[{"seq":412,"at":1,"kind":"action","type":"input.click","tab":"t_4k2p9xqa","outcome":"ok"}]}`)
		case "/v1/pair":
			writeJSON(t, w, http.StatusCreated, `{"code":"K7M2QX","expiresAt":1,"attemptsLeft":5}`)
		case "/v1/actions/" + testActionID:
			writeJSON(t, w, http.StatusOK, `{"state":"cancelled"}`)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	ctx := context.Background()

	status, err := c.Status(ctx)
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if status.User != "wizard" || status.Browser == nil || !status.Browser.Live || status.Browser.CurrentAction != nil {
		t.Fatalf("status = %+v", status)
	}

	browsers, err := c.Browsers(ctx)
	if err != nil {
		t.Fatalf("Browsers: %v", err)
	}
	if len(browsers) != 1 || !browsers[0].Default {
		t.Fatalf("browsers = %+v", browsers)
	}

	stop, err := c.Stop(ctx, testBrowserID)
	if err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if stop.StopEpoch != 8 || stop.Cancelled != 3 {
		t.Fatalf("stop = %+v", stop)
	}

	entries, err := c.Activity(ctx, testBrowserID, 5)
	if err != nil {
		t.Fatalf("Activity: %v", err)
	}
	if len(entries) != 1 || entries[0].Seq != 412 {
		t.Fatalf("activity = %+v", entries)
	}
	if q, _ := seen.Load().(string); !strings.Contains(q, "limit=5") || !strings.Contains(q, "browserId="+testBrowserID) {
		t.Fatalf("activity query = %q", q)
	}

	pair, err := c.Pair(ctx, "work laptop")
	if err != nil {
		t.Fatalf("Pair: %v", err)
	}
	if pair.Code != "K7M2QX" {
		t.Fatalf("pair = %+v", pair)
	}

	state, err := c.Cancel(ctx, testActionID)
	if err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	if state != wire.StateCancelled {
		t.Fatalf("cancel state = %q", state)
	}
}

func TestBrowserTargetResolution(t *testing.T) {
	var posted wire.CreateActionRequest
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			if err := json.NewDecoder(r.Body).Decode(&posted); err != nil {
				t.Errorf("decode: %v", err)
			}
			writeJSON(t, w, http.StatusCreated, createdBody())
			return
		}
		writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"done","ok":true,"result":{"roundTripMs":4,"extensionVersion":"0.1.0","queueDepth":0,"attachedTabs":1}}`)
	}))
	defer ts.Close()

	c := newTestClient(t, ts, WithBrowser("b_configured0000000000"))
	if _, err := c.Ping(context.Background(), Target{}); err != nil {
		t.Fatalf("Ping: %v", err)
	}
	if posted.BrowserID != "b_configured0000000000" {
		t.Fatalf("the client's default browser was not used: %+v", posted)
	}
	if _, err := c.Ping(context.Background(), Target{Browser: "b_override0000000000000"}); err != nil {
		t.Fatalf("Ping: %v", err)
	}
	if posted.BrowserID != "b_override0000000000000" {
		t.Fatalf("--browser did not override: %+v", posted)
	}
}

func TestScreenshotFetchesTheBlobAsBytes(t *testing.T) {
	const png = "\x89PNG\r\n\x1a\nnot really a png"
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/actions":
			writeJSON(t, w, http.StatusCreated, createdBody())
		case r.Method == http.MethodGet && r.URL.Path == "/v1/actions/"+testActionID:
			writeJSON(t, w, http.StatusOK, `{"actionId":"`+testActionID+`","state":"done","ok":true,
				"result":{"blobId":"bl_MnBvCxZlKjHgFdSaPoIu","width":1512,"height":982,"bytes":24},
				"blob":{"blobId":"bl_MnBvCxZlKjHgFdSaPoIu","bytes":24,"contentType":"image/png"}}`)
		case r.Method == http.MethodGet && r.URL.Path == "/v1/blobs/bl_MnBvCxZlKjHgFdSaPoIu":
			w.Header().Set("Content-Type", "image/png")
			if _, err := io.WriteString(w, png); err != nil {
				t.Errorf("write: %v", err)
			}
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer ts.Close()

	c := newTestClient(t, ts)
	var out strings.Builder
	shot, err := c.ScreenshotTo(context.Background(), Target{}, wire.ScreenshotParams{FullPage: true}, &out)
	if err != nil {
		t.Fatalf("ScreenshotTo: %v", err)
	}
	if shot.Width != 1512 || shot.BlobID != "bl_MnBvCxZlKjHgFdSaPoIu" {
		t.Fatalf("result = %+v", shot)
	}
	if out.String() != png {
		t.Fatalf("wrote %q", out.String())
	}

	body, info, err := c.FetchBlob(context.Background(), "bl_MnBvCxZlKjHgFdSaPoIu")
	if err != nil {
		t.Fatalf("FetchBlob: %v", err)
	}
	defer body.Close()
	if info.ContentType != "image/png" {
		t.Fatalf("blob info = %+v", info)
	}
	got, err := io.ReadAll(body)
	if err != nil {
		t.Fatalf("reading the blob: %v", err)
	}
	if string(got) != png {
		t.Fatalf("blob = %q", got)
	}
}

func TestNewRejectsAMissingToken(t *testing.T) {
	_, err := New("https://browser-bridge.viktorbarzin.me", "")
	if err == nil {
		t.Fatal("want an error with no token")
	}
	if !strings.Contains(err.Error(), TokenPath()) {
		t.Fatalf("the error does not name the token file: %v", err)
	}
	if ExitCode(err) != 2 {
		t.Fatalf("ExitCode = %d, want 2", ExitCode(err))
	}
}

func TestNewNormalisesTheBaseURL(t *testing.T) {
	c, err := New("https://browser-bridge.viktorbarzin.me/", testToken)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if got := c.BaseURL(); got != "https://browser-bridge.viktorbarzin.me" {
		t.Fatalf("BaseURL = %q", got)
	}
	if _, err := New("://nonsense", testToken); err == nil {
		t.Fatal("want an error for an unparseable base URL")
	}
	empty, err := New("", testToken)
	if err != nil {
		t.Fatalf("New with no base URL: %v", err)
	}
	if empty.BaseURL() != DefaultBaseURL {
		t.Fatalf("BaseURL = %q, want the default", empty.BaseURL())
	}
}

func TestEveryCommandHasAClientMethod(t *testing.T) {
	// The verb builds one CLI command per protocol command. A command with no
	// method here is a command the verb cannot implement.
	methods := map[wire.Command]bool{
		wire.CmdOpen: true, wire.CmdBack: true, wire.CmdForward: true, wire.CmdReload: true, wire.CmdURL: true,
		wire.CmdReadText: true, wire.CmdReadHTML: true, wire.CmdQuery: true, wire.CmdEval: true, wire.CmdScreenshot: true,
		wire.CmdClick: true, wire.CmdType: true, wire.CmdFill: true, wire.CmdSelect: true, wire.CmdPress: true,
		wire.CmdHover: true, wire.CmdScroll: true, wire.CmdDialog: true,
		wire.CmdWaitFor: true,
		wire.CmdConsole: true, wire.CmdNetwork: true, wire.CmdEmulate: true,
		wire.CmdTabs: true, wire.CmdAttach: true, wire.CmdDetach: true, wire.CmdActivate: true, wire.CmdCloseTab: true,
		wire.CmdStatus: true, wire.CmdPing: true, wire.CmdStop: true,
	}
	for _, cmd := range wire.Commands() {
		if !methods[cmd] {
			t.Errorf("no client method claimed for %q", cmd)
		}
	}
	if len(methods) != len(wire.Commands()) {
		t.Errorf("the method list has %d entries, the protocol has %d commands", len(methods), len(wire.Commands()))
	}
}
