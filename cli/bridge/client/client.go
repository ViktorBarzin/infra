// Package client is the Go client for a browser-bridge server. It is what
// `homelab browser bridge` runs on: construct one with a base URL and a CLI
// token, call one method per command, and branch on the typed errors.
//
// Every action follows the same path. The client posts it to
// POST /v1/actions, then long-polls GET /v1/actions/{id} until the action
// reaches a terminal state or the deadline passes. Large results, screenshots
// above all, come back from GET /v1/blobs/{id} as bytes rather than as base64
// inside a struct.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/ViktorBarzin/browser-bridge/internal/wire"
)

// Defaults. Every one of them is an Option away from being something else.
const (
	// defaultPollWait is how long the server is asked to hold a poll open.
	// The protocol caps it at 30 seconds.
	defaultPollWait = 25 * time.Second
	// defaultBackoffMin and defaultBackoffMax bound the wait between polls
	// and between retries of a failed poll.
	defaultBackoffMin = 200 * time.Millisecond
	defaultBackoffMax = 2 * time.Second
	// defaultRequestTimeout bounds a single request that is not a poll.
	defaultRequestTimeout = 30 * time.Second
	// defaultBlobTimeout bounds a blob fetch, which can be 16 MB.
	defaultBlobTimeout = 5 * time.Minute
	// deadlineSlack is how long the client keeps polling past the server's
	// own zombie cutoff, so the expiry answer is read rather than guessed.
	deadlineSlack = 3 * time.Second
	// maxErrorBody bounds what is read from a response the client is going
	// to turn into an error.
	maxJSONBody = 32 << 20
)

// Client talks to one browser-bridge server as one CLI user.
type Client struct {
	baseURL string
	token   string
	user    string
	browser string
	session string
	agent   string

	http           *http.Client
	userAgent      string
	pollWait       time.Duration
	backoffMin     time.Duration
	backoffMax     time.Duration
	requestTimeout time.Duration
	blobTimeout    time.Duration
}

// Option configures a Client.
type Option func(*Client)

// WithHTTPClient replaces the HTTP client. The client sets its own per-request
// deadlines, so a Timeout on the one passed here bounds every call including
// a 25 second long poll.
func WithHTTPClient(h *http.Client) Option {
	return func(c *Client) {
		if h != nil {
			c.http = h
		}
	}
}

// WithBrowser sets the browser used when a Target names none. The resolution
// order in the protocol is the --browser flag, then EnvBrowser, then the
// user's default on the server, and the first two belong to the caller.
func WithBrowser(browserID string) Option {
	return func(c *Client) { c.browser = browserID }
}

// WithSession pins an agent session, for two agents sharing one browser.
func WithSession(sessionID string) Option {
	return func(c *Client) { c.session = sessionID }
}

// WithUser names the person this CLI belongs to. It appears in the message
// printed when no browser is connected, and nowhere else.
func WithUser(user string) Option {
	return func(c *Client) { c.user = user }
}

// WithAgentLabel names the agent session in the popup feed and on the tab
// overlay, so a human watching can tell who is driving.
func WithAgentLabel(label string) Option {
	return func(c *Client) { c.agent = label }
}

// WithBackoff sets the wait between polls and between retries of a failed
// poll. The wait grows from min towards max.
func WithBackoff(min, max time.Duration) Option {
	return func(c *Client) {
		if min > 0 {
			c.backoffMin = min
		}
		if max > 0 {
			c.backoffMax = max
		}
		if c.backoffMax < c.backoffMin {
			c.backoffMax = c.backoffMin
		}
	}
}

// WithPollWait sets how long the server is asked to hold each poll open,
// clamped to the protocol's 30 second ceiling.
func WithPollWait(d time.Duration) Option {
	return func(c *Client) {
		if d < 0 {
			d = 0
		}
		if max := time.Duration(wire.MaxPollWaitMs) * time.Millisecond; d > max {
			d = max
		}
		c.pollWait = d
	}
}

// WithUserAgent sets the User-Agent header.
func WithUserAgent(ua string) Option {
	return func(c *Client) {
		if ua != "" {
			c.userAgent = ua
		}
	}
}

// New builds a client. An empty baseURL means DefaultBaseURL. The token is
// required, because every route except the CRX files takes a credential.
func New(baseURL, token string, opts ...Option) (*Client, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, &UsageError{
			Message: fmt.Sprintf("no browser-bridge token at %s", TokenPath()),
			Hint:    fmt.Sprintf("the provisioner writes one per OS user at mode 0600, or set %s", EnvToken),
		}
	}
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return nil, &UsageError{Message: fmt.Sprintf("browser-bridge server %q is not a URL", baseURL)}
	}

	c := &Client{
		baseURL:        strings.TrimRight(baseURL, "/"),
		token:          token,
		http:           &http.Client{},
		userAgent:      "browser-bridge-client/1 (protocol " + strconv.Itoa(wire.Version) + ")",
		pollWait:       defaultPollWait,
		backoffMin:     defaultBackoffMin,
		backoffMax:     defaultBackoffMax,
		requestTimeout: defaultRequestTimeout,
		blobTimeout:    defaultBlobTimeout,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c, nil
}

// BaseURL is the server this client talks to, without a trailing slash.
func (c *Client) BaseURL() string { return c.baseURL }

// Target says which browser and which tab an action runs against. The zero
// value means the user's default browser and the session's current tab.
type Target struct {
	// Browser overrides the client's default browser.
	Browser string
	// Tab may name any tab handle in that browser, including one the human
	// opened and the agent never touched.
	Tab string
	// Session pins an agent session for this action.
	Session string
	// Timeout overrides the action's timeout, between 1 and 600 seconds.
	Timeout time.Duration
	// IdempotencyKey makes a retried enqueue return the original action
	// instead of creating a second one.
	IdempotencyKey string
}

func (c *Client) resolveBrowser(t Target) string {
	if t.Browser != "" {
		return t.Browser
	}
	return c.browser
}

func (c *Client) resolveSession(t Target) string {
	if t.Session != "" {
		return t.Session
	}
	return c.session
}

// request is one HTTP call. Body nil means no body.
func (c *Client) request(ctx context.Context, method, path string, query url.Values, body []byte, session string) (*http.Response, error) {
	full := c.baseURL + path
	if len(query) > 0 {
		full += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, full, reader)
	if err != nil {
		return nil, &UsageError{Message: fmt.Sprintf("cannot build a request for %s %s, %v", method, path, err)}
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.userAgent)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if session != "" {
		req.Header.Set(wire.HeaderSession, session)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, &TransportError{Op: method + " " + path, URL: full, Err: err}
	}
	return resp, nil
}

// do runs a JSON call and returns the response body. A non-2xx status comes
// back as one of the typed errors.
func (c *Client) do(ctx context.Context, method, path string, query url.Values, body []byte, session string) ([]byte, error) {
	ctx, cancel := c.withTimeout(ctx, c.requestTimeout)
	defer cancel()

	resp, err := c.request(ctx, method, path, query, body, session)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	out, readErr := io.ReadAll(io.LimitReader(resp.Body, maxJSONBody))
	if resp.StatusCode >= 300 {
		return nil, classifyHTTP(method, path, resp.StatusCode, out, c.user, c.baseURL)
	}
	if readErr != nil {
		return nil, &TransportError{Op: method + " " + path, Status: resp.StatusCode, Err: readErr}
	}
	return out, nil
}

// withTimeout applies a deadline unless the caller already set an earlier one.
func (c *Client) withTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if d <= 0 {
		return ctx, func() {}
	}
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) <= d {
		return ctx, func() {}
	}
	return context.WithTimeout(ctx, d)
}

func decodeJSON[T any](method, path string, body []byte) (*T, error) {
	var out T
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, &TransportError{
			Op:  method + " " + path,
			Err: fmt.Errorf("the server's answer is not the JSON this client expects, %w", err),
		}
	}
	return &out, nil
}

// Enqueue posts one action and returns as soon as the server has accepted it.
// Most callers want a command method, or Run, which also waits for the
// result.
func (c *Client) Enqueue(ctx context.Context, t Target, typ wire.ActionType, params json.RawMessage) (*wire.CreateActionResponse, error) {
	if !typ.Valid() {
		return nil, &UsageError{Message: fmt.Sprintf("%q is not an action type this protocol version defines", typ)}
	}
	req := wire.CreateActionRequest{
		BrowserID:      c.resolveBrowser(t),
		Type:           typ,
		Params:         params,
		Tab:            t.Tab,
		IdempotencyKey: t.IdempotencyKey,
	}
	if t.Timeout > 0 {
		ms := int(t.Timeout / time.Millisecond)
		if ms < wire.MinActionTimeoutMs || ms > wire.MaxActionTimeoutMs {
			return nil, &UsageError{Message: fmt.Sprintf(
				"a timeout of %s is outside the protocol's range of %ds to %ds",
				t.Timeout, wire.MinActionTimeoutMs/1000, wire.MaxActionTimeoutMs/1000)}
		}
		req.TimeoutMs = ms
	}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, &UsageError{Message: fmt.Sprintf("cannot encode a %s action, %v", typ, err)}
	}

	const path = wire.RoutePrefix + "/actions"
	out, err := c.do(ctx, http.MethodPost, path, nil, body, c.resolveSession(t))
	if err != nil {
		return nil, err
	}
	return decodeJSON[wire.CreateActionResponse](http.MethodPost, path, out)
}

// Await polls one action until it reaches a terminal state, the deadline
// passes or the context is done. It is exported so a caller that lost a
// result, or that enqueued without waiting, can pick the action back up.
func (c *Client) Await(ctx context.Context, actionID string, deadline time.Time) (*wire.ActionStatus, error) {
	path := wire.RoutePrefix + "/actions/" + actionID
	started := time.Now()
	backoff := c.backoffMin

	var last *wire.ActionStatus
	// serverFailure remembers a 5xx or an unreachable server, so the error
	// returned at the deadline says "the server is broken" rather than "your
	// action was slow".
	var serverFailure error

	for {
		remaining := time.Until(deadline)
		if remaining <= 0 || ctx.Err() != nil {
			if serverFailure != nil {
				return last, serverFailure
			}
			return last, &TimeoutError{
				ActionID: actionID, Waited: time.Since(started),
				LastState: stateOf(last), Err: ctx.Err(),
			}
		}

		wait := c.pollWait
		if remaining < wait {
			wait = remaining
		}
		query := url.Values{"wait": {strconv.Itoa(int(wait / time.Millisecond))}}

		pollCtx, cancel := c.withTimeout(ctx, wait+c.requestTimeout)
		body, err := c.poll(pollCtx, path, query)
		cancel()

		switch {
		case err == nil:
			status, derr := decodeJSON[wire.ActionStatus](http.MethodGet, path, body)
			if derr != nil {
				return last, derr
			}
			last = status
			if status.State.Terminal() {
				return status, nil
			}
		default:
			var transport *TransportError
			if !errors.As(err, &transport) {
				return last, err
			}
			if ctx.Err() == nil {
				serverFailure = err
			}
		}

		if !sleepUntil(ctx, backoff, deadline) {
			if serverFailure != nil {
				return last, serverFailure
			}
			return last, &TimeoutError{
				ActionID: actionID, Waited: time.Since(started),
				LastState: stateOf(last), Err: ctx.Err(),
			}
		}
		backoff = nextBackoff(backoff, c.backoffMax)
	}
}

func (c *Client) poll(ctx context.Context, path string, query url.Values) ([]byte, error) {
	resp, err := c.request(ctx, http.MethodGet, path, query, nil, c.session)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	out, readErr := io.ReadAll(io.LimitReader(resp.Body, maxJSONBody))
	if resp.StatusCode >= 300 {
		return nil, classifyHTTP(http.MethodGet, path, resp.StatusCode, out, c.user, c.baseURL)
	}
	if readErr != nil {
		return nil, &TransportError{Op: "GET " + path, Status: resp.StatusCode, Err: readErr}
	}
	return out, nil
}

// Run enqueues an action and waits for its result. It returns the status even
// when it also returns an error, so a caller printing raw JSON has something
// to print.
func (c *Client) Run(ctx context.Context, t Target, typ wire.ActionType, params json.RawMessage) (*wire.ActionStatus, error) {
	created, err := c.Enqueue(ctx, t, typ, params)
	if err != nil {
		return nil, err
	}

	deadline := time.Now().Add(c.fallbackWait(t))
	if created.ExpiresAt > 0 {
		deadline = time.UnixMilli(created.ExpiresAt).Add(deadlineSlack)
	}

	status, err := c.Await(ctx, created.ActionID, deadline)
	if err != nil {
		return status, err
	}
	if status.State != wire.StateDone || (status.Ok != nil && !*status.Ok) {
		return status, actionErrorFrom(created.ActionID, t.Tab, status)
	}
	return status, nil
}

// fallbackWait is how long to wait when the server sent no expiresAt, which
// should not happen and is not worth failing over.
func (c *Client) fallbackWait(t Target) time.Duration {
	timeout := t.Timeout
	if timeout <= 0 {
		timeout = time.Duration(wire.DefaultActionTimeoutMs) * time.Millisecond
	}
	return timeout + time.Duration(wire.GraceMs)*time.Millisecond + deadlineSlack
}

func actionErrorFrom(actionID, tab string, status *wire.ActionStatus) error {
	out := &ActionError{ActionID: actionID, State: status.State, Tab: tab}
	if status.Tab != nil && status.Tab.Handle != "" {
		out.Tab = status.Tab.Handle
	}
	if status.Error != nil {
		out.Code = status.Error.Code
		out.Message = status.Error.Message
		out.Hint = status.Error.Hint
	}
	if out.Code == "" {
		switch status.State {
		case wire.StateExpired:
			out.Code = wire.CodeExpired
		case wire.StateStopped, wire.StateCancelled:
			out.Code = wire.CodeStopped
		default:
			out.Code = wire.CodeInternal
		}
	}
	if out.Message == "" {
		out.Message = "the action ended " + string(status.State) + " with no message"
	}
	return out
}

func stateOf(status *wire.ActionStatus) wire.ActionState {
	if status == nil {
		return ""
	}
	return status.State
}

func nextBackoff(current, max time.Duration) time.Duration {
	next := current * 2
	if next > max {
		return max
	}
	return next
}

// sleepUntil waits for d, or until the deadline or the context, whichever
// comes first. It reports whether waiting is still worth it.
func sleepUntil(ctx context.Context, d time.Duration, deadline time.Time) bool {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return false
	}
	if d > remaining {
		d = remaining
	}
	if d <= 0 {
		return ctx.Err() == nil
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

// runAction is the path every typed command method takes.
func runAction[P any, R any](ctx context.Context, c *Client, t Target, typ wire.ActionType, params P) (*R, error) {
	raw, err := json.Marshal(params)
	if err != nil {
		return nil, &UsageError{Message: fmt.Sprintf("cannot encode the parameters for %s, %v", typ, err)}
	}
	status, err := c.Run(ctx, t, typ, raw)
	if err != nil {
		return nil, err
	}
	var out R
	if len(status.Result) > 0 {
		if err := json.Unmarshal(status.Result, &out); err != nil {
			return nil, &TransportError{
				Op:  "GET " + wire.RoutePrefix + "/actions/" + status.ActionID,
				Err: fmt.Errorf("the browser's %s result is not the shape this client expects, %w", typ, err),
			}
		}
	}
	return &out, nil
}
