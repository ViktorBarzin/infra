package wire

import (
	"encoding/json"
	"testing"
)

func TestErrorCodeValid(t *testing.T) {
	cases := []struct {
		in   ErrorCode
		want bool
	}{
		{CodeBadRequest, true},
		{CodeNoBrowserLive, true},
		{CodeStopped, true},
		{CodeStoreUnavailable, true},
		{CodeTabClosed, true},
		{CodeSelectorNotFound, true},
		{"kaboom", false},
		{"", false},
	}
	for _, c := range cases {
		t.Run(string(c.in), func(t *testing.T) {
			if got := c.in.Valid(); got != c.want {
				t.Fatalf("%q.Valid() = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestErrorCodeTransportAndAction(t *testing.T) {
	cases := []struct {
		in        ErrorCode
		transport bool
		action    bool
		status    int
	}{
		{CodeBadRequest, true, false, 400},
		{CodeNoCredential, true, false, 401},
		{CodeNotOwner, true, false, 403},
		{CodeNoBrowser, true, false, 404},
		{CodeNoDefaultBrowser, true, false, 409},
		{CodeExpired, true, true, 410},
		{CodeLengthRequired, true, false, 411},
		{CodeNoBrowserLive, true, false, 412},
		{CodeTooLarge, true, false, 413},
		{CodeStopped, true, true, 423},
		{CodeRateLimited, true, false, 429},
		{CodeInternal, true, true, 500},
		{CodeStoreUnavailable, true, false, 503},
		{CodeTabUnknown, false, true, 0},
		{CodeTabClosed, false, true, 0},
		{CodeTabHeld, false, true, 0},
		{CodeTabForbidden, false, true, 0},
		{CodeTabDiscarded, false, true, 0},
		{CodeAttachFailed, false, true, 0},
		{CodeSelectorNotFound, false, true, 0},
		{CodeNavigationFailed, false, true, 0},
		{CodeTimeout, false, true, 0},
		{CodeJSError, false, true, 0},
		{CodeDialogAbsent, false, true, 0},
	}
	for _, c := range cases {
		t.Run(string(c.in), func(t *testing.T) {
			if got := c.in.Transport(); got != c.transport {
				t.Fatalf("%q.Transport() = %v, want %v", c.in, got, c.transport)
			}
			if got := c.in.Action(); got != c.action {
				t.Fatalf("%q.Action() = %v, want %v", c.in, got, c.action)
			}
			if got := c.in.HTTPStatus(); got != c.status {
				t.Fatalf("%q.HTTPStatus() = %d, want %d", c.in, got, c.status)
			}
		})
	}
}

func TestErrorCodeTabFailure(t *testing.T) {
	for _, c := range []ErrorCode{CodeTabUnknown, CodeTabClosed, CodeTabHeld, CodeTabForbidden, CodeTabDiscarded} {
		if !c.TabFailure() {
			t.Fatalf("%q.TabFailure() = false, want true", c)
		}
	}
	for _, c := range []ErrorCode{CodeTimeout, CodeJSError, CodeNoBrowserLive, CodeAttachFailed} {
		if c.TabFailure() {
			t.Fatalf("%q.TabFailure() = true, want false", c)
		}
	}
}

func TestErrorEnvelopeRoundTrip(t *testing.T) {
	const doc = `{"error":{"code":"tab_closed","message":"human readable","hint":"what to do","retryable":false}}`
	var env ErrorEnvelope
	if err := json.Unmarshal([]byte(doc), &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if env.Error == nil {
		t.Fatal("envelope carried no error")
	}
	if env.Error.Code != CodeTabClosed || env.Error.Message != "human readable" || env.Error.Hint != "what to do" || env.Error.Retryable {
		t.Fatalf("decoded wrong: %+v", env.Error)
	}
	out, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(out) != doc {
		t.Fatalf("round trip changed the bytes:\n got %s\nwant %s", out, doc)
	}
}

func TestErrorMessageFallsBackToCode(t *testing.T) {
	e := &Error{Code: CodeNoBrowserLive}
	if got := e.Error(); got == "" {
		t.Fatal("Error() returned an empty string")
	}
	e.Message = "no extension stream is open"
	if got := e.Error(); got != "no_browser_live: no extension stream is open" {
		t.Fatalf("Error() = %q", got)
	}
}
