package client

import (
	"context"
	"net/http"
	"net/url"
	"strconv"

	"github.com/ViktorBarzin/browser-bridge/internal/wire"
)

// One method per CLI command, in the order section 14 lists them. Each action
// method enqueues, waits and decodes the typed result; status and stop answer
// from the server without touching the browser.

// Open navigates. Without NewTab it reuses the session's current tab, or the
// tab the Target names.
func (c *Client) Open(ctx context.Context, t Target, p wire.OpenParams) (*wire.OpenResult, error) {
	return runAction[wire.OpenParams, wire.OpenResult](ctx, c, t, wire.ActionNavOpen, p)
}

// Back goes back one entry in the tab's history.
func (c *Client) Back(ctx context.Context, t Target, p wire.EmptyParams) (*wire.NavResult, error) {
	return runAction[wire.EmptyParams, wire.NavResult](ctx, c, t, wire.ActionNavBack, p)
}

// Forward goes forward one entry.
func (c *Client) Forward(ctx context.Context, t Target, p wire.EmptyParams) (*wire.NavResult, error) {
	return runAction[wire.EmptyParams, wire.NavResult](ctx, c, t, wire.ActionNavForward, p)
}

// Reload reloads the tab.
func (c *Client) Reload(ctx context.Context, t Target, p wire.ReloadParams) (*wire.ReloadResult, error) {
	return runAction[wire.ReloadParams, wire.ReloadResult](ctx, c, t, wire.ActionNavReload, p)
}

// URL reports where the tab is.
func (c *Client) URL(ctx context.Context, t Target, p wire.EmptyParams) (*wire.URLResult, error) {
	return runAction[wire.EmptyParams, wire.URLResult](ctx, c, t, wire.ActionNavURL, p)
}

// ReadText reads text, the whole document when the selector is empty.
func (c *Client) ReadText(ctx context.Context, t Target, p wire.ReadTextParams) (*wire.ReadTextResult, error) {
	return runAction[wire.ReadTextParams, wire.ReadTextResult](ctx, c, t, wire.ActionReadText, p)
}

// ReadHTML reads markup.
func (c *Client) ReadHTML(ctx context.Context, t Target, p wire.ReadHTMLParams) (*wire.ReadHTMLResult, error) {
	return runAction[wire.ReadHTMLParams, wire.ReadHTMLResult](ctx, c, t, wire.ActionReadHTML, p)
}

// Query matches elements and reports what it found.
func (c *Client) Query(ctx context.Context, t Target, p wire.QueryParams) (*wire.QueryResult, error) {
	return runAction[wire.QueryParams, wire.QueryResult](ctx, c, t, wire.ActionReadQuery, p)
}

// Eval evaluates an expression in the page.
func (c *Client) Eval(ctx context.Context, t Target, p wire.EvalParams) (*wire.EvalResult, error) {
	return runAction[wire.EvalParams, wire.EvalResult](ctx, c, t, wire.ActionReadEval, p)
}

// Screenshot captures the tab. The bytes are in a blob; ScreenshotTo fetches
// them in the same call.
func (c *Client) Screenshot(ctx context.Context, t Target, p wire.ScreenshotParams) (*wire.ScreenshotResult, error) {
	return runAction[wire.ScreenshotParams, wire.ScreenshotResult](ctx, c, t, wire.ActionReadScreenshot, p)
}

// Click clicks a selector, or a coordinate pair on a canvas or a map.
func (c *Client) Click(ctx context.Context, t Target, p wire.ClickParams) (*wire.ClickResult, error) {
	return runAction[wire.ClickParams, wire.ClickResult](ctx, c, t, wire.ActionInputClick, p)
}

// Type types into a field.
func (c *Client) Type(ctx context.Context, t Target, p wire.TypeParams) (*wire.TypeResult, error) {
	return runAction[wire.TypeParams, wire.TypeResult](ctx, c, t, wire.ActionInputType, p)
}

// Fill fills one field or a whole form, which is one queue slot and one
// activity entry rather than six.
func (c *Client) Fill(ctx context.Context, t Target, p wire.FillParams) (*wire.FillResult, error) {
	return runAction[wire.FillParams, wire.FillResult](ctx, c, t, wire.ActionInputFill, p)
}

// Select picks an option.
func (c *Client) Select(ctx context.Context, t Target, p wire.SelectParams) (*wire.SelectResult, error) {
	return runAction[wire.SelectParams, wire.SelectResult](ctx, c, t, wire.ActionInputSelect, p)
}

// Press sends a key.
func (c *Client) Press(ctx context.Context, t Target, p wire.PressParams) (*wire.PressResult, error) {
	return runAction[wire.PressParams, wire.PressResult](ctx, c, t, wire.ActionInputPress, p)
}

// Hover hovers an element.
func (c *Client) Hover(ctx context.Context, t Target, p wire.HoverParams) (*wire.HoverResult, error) {
	return runAction[wire.HoverParams, wire.HoverResult](ctx, c, t, wire.ActionInputHover, p)
}

// Scroll scrolls the page or an element into view.
func (c *Client) Scroll(ctx context.Context, t Target, p wire.ScrollParams) (*wire.ScrollResult, error) {
	return runAction[wire.ScrollParams, wire.ScrollResult](ctx, c, t, wire.ActionInputScroll, p)
}

// Dialog answers an open JavaScript dialog.
func (c *Client) Dialog(ctx context.Context, t Target, p wire.DialogParams) (*wire.DialogResult, error) {
	return runAction[wire.DialogParams, wire.DialogResult](ctx, c, t, wire.ActionInputDialog, p)
}

// WaitFor waits for a load, a text, a selector or a URL fragment. It runs
// off-queue, so it can wait for minutes without blocking anything else.
func (c *Client) WaitFor(ctx context.Context, t Target, p wire.WaitForParams) (*wire.WaitForResult, error) {
	return runAction[wire.WaitForParams, wire.WaitForResult](ctx, c, t, wire.ActionWaitFor, p)
}

// Console reads what the page logged since the tab was attached.
func (c *Client) Console(ctx context.Context, t Target, p wire.ConsoleParams) (*wire.ConsoleResult, error) {
	return runAction[wire.ConsoleParams, wire.ConsoleResult](ctx, c, t, wire.ActionDiagConsole, p)
}

// Network reads captured requests, in list form or one request in detail.
func (c *Client) Network(ctx context.Context, t Target, p wire.NetworkParams) (*wire.NetworkResult, error) {
	return runAction[wire.NetworkParams, wire.NetworkResult](ctx, c, t, wire.ActionDiagNetwork, p)
}

// Emulate applies device, network and media overrides. They are bound to the
// debugger session and die on detach, on a stop and on the idle detach.
func (c *Client) Emulate(ctx context.Context, t Target, p wire.EmulateParams) (*wire.EmulateResult, error) {
	return runAction[wire.EmulateParams, wire.EmulateResult](ctx, c, t, wire.ActionDiagEmulate, p)
}

// Tabs enumerates every tab in the browser, the human's included. It needs no
// debugger and leaves no trace in the page, and it is recorded in the
// activity feed like any other action.
func (c *Client) Tabs(ctx context.Context, t Target, p wire.TabListParams) (*wire.TabListResult, error) {
	return runAction[wire.TabListParams, wire.TabListResult](ctx, c, t, wire.ActionTabList, p)
}

// Attach takes control of a tab the human already had open. Chrome raises its
// own debugging banner, which is deliberate and is never suppressed.
func (c *Client) Attach(ctx context.Context, t Target, p wire.AttachParams) (*wire.AttachResult, error) {
	return runAction[wire.AttachParams, wire.AttachResult](ctx, c, t, wire.ActionTabAttach, p)
}

// Detach hands a borrowed tab back, clearing the overrides bound to the
// debugger session. What the agent typed into the page stays where it is.
func (c *Client) Detach(ctx context.Context, t Target, p wire.DetachParams) (*wire.DetachResult, error) {
	return runAction[wire.DetachParams, wire.DetachResult](ctx, c, t, wire.ActionTabDetach, p)
}

// Activate focuses a tab and raises its window, which is how an agent shows a
// human what it is looking at.
func (c *Client) Activate(ctx context.Context, t Target, p wire.ActivateParams) (*wire.ActivateResult, error) {
	return runAction[wire.ActivateParams, wire.ActivateResult](ctx, c, t, wire.ActionTabActivate, p)
}

// CloseTab closes a tab. Closing one the human opened is allowed and is
// recorded with owner "user".
func (c *Client) CloseTab(ctx context.Context, t Target, p wire.CloseTabParams) (*wire.CloseTabResult, error) {
	return runAction[wire.CloseTabParams, wire.CloseTabResult](ctx, c, t, wire.ActionTabClose, p)
}

// Ping measures the round trip to the extension. It runs off-queue, so it
// answers while the queue is stuck, which is when it is worth asking.
func (c *Client) Ping(ctx context.Context, t Target) (*wire.PingResult, error) {
	return runAction[wire.EmptyParams, wire.PingResult](ctx, c, t, wire.ActionCtlPing, wire.EmptyParams{})
}

// Status answers "can I drive a browser right now". It needs no browser and
// answers when Chrome is closed, which makes it the first thing to run.
func (c *Client) Status(ctx context.Context) (*wire.StatusResponse, error) {
	const path = wire.RoutePrefix + "/status"
	body, err := c.do(ctx, http.MethodGet, path, nil, nil, c.session)
	if err != nil {
		return nil, err
	}
	return decodeJSON[wire.StatusResponse](http.MethodGet, path, body)
}

// Stop is the kill switch. The browser's stop epoch bumps whether or not
// Chrome is running, so a stop issued while a laptop is shut still lands when
// it wakes.
func (c *Client) Stop(ctx context.Context, browserID string) (*wire.StopResponse, error) {
	if browserID == "" {
		browserID = c.browser
	}
	payload, err := marshal(wire.StopRequest{BrowserID: browserID})
	if err != nil {
		return nil, err
	}
	const path = wire.RoutePrefix + "/control/stop"
	body, err := c.do(ctx, http.MethodPost, path, nil, payload, c.session)
	if err != nil {
		return nil, err
	}
	return decodeJSON[wire.StopResponse](http.MethodPost, path, body)
}

// Browsers lists the caller's enrolled browsers.
func (c *Client) Browsers(ctx context.Context) ([]wire.Browser, error) {
	const path = wire.RoutePrefix + "/browsers"
	body, err := c.do(ctx, http.MethodGet, path, nil, nil, c.session)
	if err != nil {
		return nil, err
	}
	out, err := decodeJSON[wire.BrowsersResponse](http.MethodGet, path, body)
	if err != nil {
		return nil, err
	}
	return out.Browsers, nil
}

// Activity reads the live feed, newest first. It is capped, short-lived state
// rather than a history, so an entry that matters belongs somewhere else.
func (c *Client) Activity(ctx context.Context, browserID string, limit int) ([]wire.ActivityEntry, error) {
	query := url.Values{}
	if browserID == "" {
		browserID = c.browser
	}
	if browserID != "" {
		query.Set("browserId", browserID)
	}
	if limit > 0 {
		if limit > wire.MaxActivityLimit {
			limit = wire.MaxActivityLimit
		}
		query.Set("limit", strconv.Itoa(limit))
	}
	const path = wire.RoutePrefix + "/activity"
	body, err := c.do(ctx, http.MethodGet, path, query, nil, c.session)
	if err != nil {
		return nil, err
	}
	out, err := decodeJSON[wire.ActivityResponse](http.MethodGet, path, body)
	if err != nil {
		return nil, err
	}
	return out.Entries, nil
}

// Pair mints a pair code for a Chrome that cannot reach Authentik. The
// enrolment it produces is owned by this token's user, so identity flows from
// the authenticated side.
func (c *Client) Pair(ctx context.Context, label string) (*wire.PairResponse, error) {
	payload, err := marshal(wire.PairRequest{Label: label})
	if err != nil {
		return nil, err
	}
	const path = wire.RoutePrefix + "/pair"
	body, err := c.do(ctx, http.MethodPost, path, nil, payload, c.session)
	if err != nil {
		return nil, err
	}
	return decodeJSON[wire.PairResponse](http.MethodPost, path, body)
}

// Cancel drops a queued action. An action already running cannot be recalled,
// and the server answers already_running; the kill switch is the lever then.
func (c *Client) Cancel(ctx context.Context, actionID string) (wire.ActionState, error) {
	path := wire.RoutePrefix + "/actions/" + actionID
	body, err := c.do(ctx, http.MethodDelete, path, nil, nil, c.session)
	if err != nil {
		return "", err
	}
	out, err := decodeJSON[wire.CancelActionResponse](http.MethodDelete, path, body)
	if err != nil {
		return "", err
	}
	return out.State, nil
}
