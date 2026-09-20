package client

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/ViktorBarzin/browser-bridge/internal/wire"
)

func TestClassifyHTTP(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		body     string
		wantType string
		wantCode wire.ErrorCode
		exitCode int
	}{
		{"no browser enrolled", 404, `{"error":{"code":"no_browser","message":"unknown"}}`, "*client.NoBrowserError", wire.CodeNoBrowser, 3},
		{"no browser live", 412, `{"error":{"code":"no_browser_live","message":"closed"}}`, "*client.NoBrowserError", wire.CodeNoBrowserLive, 3},
		{"two browsers and no default", 409, `{"error":{"code":"no_default_browser","message":"pick one"}}`, "*client.APIError", wire.CodeNoDefaultBrowser, 2},
		{"no target tab", 409, `{"error":{"code":"no_target_tab","message":"nothing to drive"}}`, "*client.APIError", wire.CodeNoTargetTab, 4},
		{"bad request", 400, `{"error":{"code":"bad_request","message":"unknown field"}}`, "*client.APIError", wire.CodeBadRequest, 2},
		{"bad id", 400, `{"error":{"code":"bad_id","message":"wrong prefix"}}`, "*client.APIError", wire.CodeBadID, 2},
		{"no credential", 401, `{"error":{"code":"no_credential","message":"none given"}}`, "*client.APIError", wire.CodeNoCredential, 2},
		{"bad credential", 401, `{"error":{"code":"bad_credential","message":"did not match"}}`, "*client.APIError", wire.CodeBadCredential, 2},
		{"not the owner", 403, `{"error":{"code":"not_owner","message":"someone else's"}}`, "*client.APIError", wire.CodeNotOwner, 2},
		{"unknown tab handle", 409, `{"error":{"code":"no_target_tab","message":"no current tab"}}`, "*client.APIError", wire.CodeNoTargetTab, 4},
		{"stopped", 423, `{"error":{"code":"stopped","message":"kill switch"}}`, "*client.StoppedError", wire.CodeStopped, 5},
		{"rate limited", 429, `{"error":{"code":"rate_limited","message":"slow down"}}`, "*client.APIError", wire.CodeRateLimited, 1},
		{"queue full", 409, `{"error":{"code":"queue_full","message":"64 queued"}}`, "*client.APIError", wire.CodeQueueFull, 1},
		{"store unavailable", 503, `{"error":{"code":"store_unavailable","message":"redis down"}}`, "*client.TransportError", wire.CodeStoreUnavailable, 6},
		{"internal", 500, `{"error":{"code":"internal","message":"a bug"}}`, "*client.TransportError", wire.CodeInternal, 6},
		{"bad gateway with no body", 502, `<html>no</html>`, "*client.TransportError", "", 6},
		{"404 with no body", 404, ``, "*client.APIError", "", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := classifyHTTP(http.MethodPost, "/v1/actions", tc.status, []byte(tc.body), "wizard", DefaultBaseURL)
			if err == nil {
				t.Fatal("want an error")
			}
			if got := fmt.Sprintf("%T", err); got != tc.wantType {
				t.Fatalf("type = %s, want %s (%v)", got, tc.wantType, err)
			}
			if tc.wantCode != "" {
				var api *APIError
				if !errors.As(err, &api) {
					t.Fatalf("want an *APIError somewhere in the chain, got %T", err)
				}
				if api.Code != tc.wantCode {
					t.Fatalf("code = %q, want %q", api.Code, tc.wantCode)
				}
				if api.Status != tc.status {
					t.Fatalf("status = %d, want %d", api.Status, tc.status)
				}
			}
			if got := ExitCode(err); got != tc.exitCode {
				t.Fatalf("ExitCode = %d, want %d", got, tc.exitCode)
			}
		})
	}
}

func TestClassifyHTTPKeepsTheServersWords(t *testing.T) {
	err := classifyHTTP(http.MethodGet, "/v1/actions/a_x", 409,
		[]byte(`{"error":{"code":"already_running","message":"it is in flight","hint":"use stop","retryable":false}}`),
		"wizard", DefaultBaseURL)
	var api *APIError
	if !errors.As(err, &api) {
		t.Fatalf("want an *APIError, got %T", err)
	}
	if api.Message != "it is in flight" || api.Hint != "use stop" || api.Retryable {
		t.Fatalf("api = %+v", api)
	}
	if !strings.Contains(err.Error(), "it is in flight") || !strings.Contains(err.Error(), "use stop") {
		t.Fatalf("Error() = %q", err.Error())
	}
}

func TestExitCodes(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"nothing went wrong", nil, 0},
		{"an action failed", &ActionError{Code: wire.CodeJSError}, 1},
		{"a tab is gone", &ActionError{Code: wire.CodeTabClosed}, 4},
		{"a tab was never seen", &ActionError{Code: wire.CodeTabUnknown}, 4},
		{"another session holds the tab", &ActionError{Code: wire.CodeTabHeld}, 4},
		{"chrome forbids the page", &ActionError{Code: wire.CodeTabForbidden}, 4},
		{"the kill switch landed", &ActionError{Code: wire.CodeStopped}, 5},
		{"no browser", &NoBrowserError{APIError: &APIError{Code: wire.CodeNoBrowserLive}}, 3},
		{"stopped", &StoppedError{APIError: &APIError{Code: wire.CodeStopped}}, 5},
		{"the server is unreachable", &TransportError{Op: "GET /v1/status"}, 6},
		{"the client was misused", &UsageError{Message: "no token"}, 2},
		{"the wait ran out", &TimeoutError{ActionID: "a_x"}, 1},
		{"something else entirely", errors.New("kaboom"), 1},
		{"a cancelled context", context.Canceled, 1},
		{"a wrapped action error", fmt.Errorf("running click: %w", &ActionError{Code: wire.CodeTabClosed}), 4},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ExitCode(tc.err); got != tc.want {
				t.Fatalf("ExitCode = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestNoBrowserMessageNamesTheFixAndTheAlternative(t *testing.T) {
	err := &NoBrowserError{
		APIError: &APIError{Status: 412, Code: wire.CodeNoBrowserLive, Message: "no extension stream is open"},
		User:     "emo",
		BaseURL:  "https://browser-bridge.viktorbarzin.me",
	}
	msg := err.Error()
	for _, want := range []string{
		"No browser is connected for emo.",
		"Open Chrome on the machine you enrolled.",
		"curl -fsSL https://browser-bridge.viktorbarzin.me/install | sh",
		"homelab browser run <script.js>",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("the message does not contain %q:\n%s", want, msg)
		}
	}
	var api *APIError
	if !errors.As(err, &api) {
		t.Fatal("a NoBrowserError must unwrap to its APIError")
	}
}

func TestNoBrowserMessageWithoutAUser(t *testing.T) {
	err := &NoBrowserError{APIError: &APIError{Code: wire.CodeNoBrowser}, BaseURL: DefaultBaseURL}
	if strings.Contains(err.Error(), " for .") {
		t.Fatalf("an unknown user leaves a dangling name:\n%s", err.Error())
	}
	if !strings.Contains(err.Error(), "No browser is connected.") {
		t.Fatalf("message = %q", err.Error())
	}
}

func TestActionErrorMessage(t *testing.T) {
	err := &ActionError{
		ActionID: "a_x", State: wire.StateDone, Code: wire.CodeSelectorNotFound,
		Message: "#submit matched nothing", Hint: "run query to see what is there", Tab: "t_4k2p9xqa",
	}
	msg := err.Error()
	for _, want := range []string{"selector_not_found", "#submit matched nothing", "t_4k2p9xqa", "run query"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("the message does not contain %q:\n%s", want, msg)
		}
	}
}
