package client

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/ViktorBarzin/browser-bridge/internal/wire"
)

// The CLI prints a different message for each of these, so they are separate
// types rather than one error with a field. ExitCode maps any of them to the
// exit codes in section 14.1 of the protocol.

// APIError is a non-2xx answer the server meant to give: the request reached
// it, it understood the request, and it refused.
type APIError struct {
	Method  string
	Path    string
	Status  int
	Code    wire.ErrorCode
	Message string
	Hint    string
	// Retryable is the server's own judgement, from the error body.
	Retryable bool
}

func (e *APIError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s %s returned %d", e.Method, e.Path, e.Status)
	if e.Code != "" {
		fmt.Fprintf(&b, " %s", e.Code)
	}
	if e.Message != "" {
		fmt.Fprintf(&b, ", %s", e.Message)
	}
	if e.Hint != "" {
		fmt.Fprintf(&b, " (%s)", e.Hint)
	}
	return b.String()
}

// NoBrowserError is the one an agent hits most: nothing is enrolled, or the
// enrolled Chrome is not running. Its text is part of the protocol, because
// the fix and the alternative both belong in front of whoever reads it.
type NoBrowserError struct {
	*APIError
	// User is the name the message greets, when the caller knows it.
	User string
	// BaseURL is the server the installer one-liner should name.
	BaseURL string
}

func (e *NoBrowserError) Error() string {
	who := "No browser is connected."
	if e.User != "" {
		who = "No browser is connected for " + e.User + "."
	}
	base := e.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	return who + `

Open Chrome on the machine you enrolled. The extension reconnects on its own
within about 30 seconds, then retry.

Never enrolled? Run the installer on that machine:
  curl -fsSL ` + base + `/install | sh

If you do not actually need the human's logged-in session, use the cluster's
own headless Chrome instead, which needs no human at all:
  homelab browser run <script.js>`
}

func (e *NoBrowserError) Unwrap() error { return e.APIError }

// StoppedError means the kill switch was pulled and the browser has not
// resumed. A human clears it from the toolbar popup.
type StoppedError struct {
	*APIError
}

func (e *StoppedError) Unwrap() error { return e.APIError }

// TransportError is the server being unreachable or broken: a connection
// that never completed, or a 5xx. Distinct from APIError because the fix is
// somewhere else, and because a retry is worth trying.
type TransportError struct {
	Op     string
	URL    string
	Status int
	// API carries the server's own error body when it sent one.
	API *APIError
	// Err carries the underlying network failure when the request never
	// completed.
	Err error
}

func (e *TransportError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "browser-bridge %s failed", e.Op)
	if e.Status != 0 {
		fmt.Fprintf(&b, " with %d", e.Status)
	}
	switch {
	case e.API != nil && e.API.Message != "":
		fmt.Fprintf(&b, ", %s", e.API.Message)
	case e.Err != nil:
		fmt.Fprintf(&b, ", %v", e.Err)
	}
	return b.String()
}

func (e *TransportError) Unwrap() error {
	if e.API != nil {
		return e.API
	}
	return e.Err
}

// ActionError means the action reached the browser and failed there. The
// code is one of the action codes in section 5.1.
type ActionError struct {
	ActionID string
	State    wire.ActionState
	Code     wire.ErrorCode
	Message  string
	Hint     string
	// Tab is the handle the action ran against, when it named one.
	Tab string
}

func (e *ActionError) Error() string {
	var b strings.Builder
	b.WriteString("the browser could not run this action")
	if e.Code != "" {
		fmt.Fprintf(&b, " (%s)", e.Code)
	}
	if e.Message != "" {
		fmt.Fprintf(&b, ", %s", e.Message)
	}
	if e.Tab != "" {
		fmt.Fprintf(&b, " on tab %s", e.Tab)
	}
	if e.Hint != "" {
		fmt.Fprintf(&b, ". %s", e.Hint)
	}
	return b.String()
}

// TimeoutError means no result arrived before the deadline. The action may
// still be running in the browser; the server expires it at its own cutoff.
type TimeoutError struct {
	ActionID  string
	Waited    time.Duration
	LastState wire.ActionState
	Err       error
}

func (e *TimeoutError) Error() string {
	state := string(e.LastState)
	if state == "" {
		state = "unknown"
	}
	return fmt.Sprintf("no result for %s after %s, last state %s", e.ActionID, e.Waited.Round(time.Millisecond), state)
}

func (e *TimeoutError) Unwrap() error { return e.Err }

// UsageError is the caller's mistake, caught before the request went out.
type UsageError struct {
	Message string
	Hint    string
}

func (e *UsageError) Error() string {
	if e.Hint == "" {
		return e.Message
	}
	return e.Message + ". " + e.Hint
}

// usageCodes are the server-side refusals a person fixes by changing the
// command, rather than by changing the browser or waiting.
var usageCodes = map[wire.ErrorCode]bool{
	wire.CodeBadRequest:       true,
	wire.CodeBadID:            true,
	wire.CodeNoCredential:     true,
	wire.CodeBadCredential:    true,
	wire.CodeBadCode:          true,
	wire.CodeSessionExpired:   true,
	wire.CodeNotOwner:         true,
	wire.CodeRevoked:          true,
	wire.CodeAdminRequired:    true,
	wire.CodeNoDefaultBrowser: true,
	wire.CodeProtocolMismatch: true,
}

// ExitCode maps an error to the process exit code in section 14.1: 0 success,
// 1 action failed, 2 usage error, 3 no browser connected, 4 tab not
// resolvable, 5 stopped, 6 server or store unreachable.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}

	var noBrowser *NoBrowserError
	if errors.As(err, &noBrowser) {
		return 3
	}
	var stopped *StoppedError
	if errors.As(err, &stopped) {
		return 5
	}
	var transport *TransportError
	if errors.As(err, &transport) {
		return 6
	}
	var usage *UsageError
	if errors.As(err, &usage) {
		return 2
	}
	var action *ActionError
	if errors.As(err, &action) {
		switch {
		case action.Code.TabFailure():
			return 4
		case action.Code == wire.CodeStopped:
			return 5
		default:
			return 1
		}
	}
	var timeout *TimeoutError
	if errors.As(err, &timeout) {
		return 1
	}
	var api *APIError
	if errors.As(err, &api) {
		switch {
		case api.Code.TabFailure() || api.Code == wire.CodeNoTargetTab:
			return 4
		case usageCodes[api.Code]:
			return 2
		case api.Code == wire.CodeStopped:
			return 5
		case api.Code == wire.CodeNoBrowser || api.Code == wire.CodeNoBrowserLive:
			return 3
		case api.Code == wire.CodeInternal || api.Code == wire.CodeStoreUnavailable:
			return 6
		default:
			return 1
		}
	}
	return 1
}

// classifyHTTP turns a non-2xx response into the typed error the CLI
// branches on. It never guesses beyond what the body says: a response with no
// error envelope keeps its status and loses nothing else.
func classifyHTTP(method, path string, status int, body []byte, user, baseURL string) error {
	api := &APIError{Method: method, Path: path, Status: status}

	var env wire.ErrorEnvelope
	if err := json.Unmarshal(body, &env); err == nil && env.Error != nil {
		api.Code = env.Error.Code
		api.Message = env.Error.Message
		api.Hint = env.Error.Hint
		api.Retryable = env.Error.Retryable
	} else if trimmed := strings.TrimSpace(string(body)); trimmed != "" && len(trimmed) <= 200 {
		// A body from something that is not our server, a proxy error page
		// for example. Keep it, truncated, rather than throwing it away.
		api.Message = trimmed
	}

	switch {
	case api.Code == wire.CodeNoBrowser || api.Code == wire.CodeNoBrowserLive:
		return &NoBrowserError{APIError: api, User: user, BaseURL: baseURL}
	case api.Code == wire.CodeStopped || status == 423:
		return &StoppedError{APIError: api}
	case status >= 500 || api.Code == wire.CodeStoreUnavailable || api.Code == wire.CodeInternal:
		return &TransportError{Op: method + " " + path, Status: status, API: api}
	default:
		return api
	}
}
