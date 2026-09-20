package wire

import "fmt"

// ErrorCode is the machine-readable half of an error. A client branches on
// the code and never on the message. Codes are stable.
type ErrorCode string

// Transport codes. Each belongs to exactly one HTTP status, given by
// HTTPStatus.
const (
	CodeBadRequest       ErrorCode = "bad_request"
	CodeBadID            ErrorCode = "bad_id"
	CodeNoCredential     ErrorCode = "no_credential"
	CodeBadCredential    ErrorCode = "bad_credential"
	CodeBadCode          ErrorCode = "bad_code"
	CodeSessionExpired   ErrorCode = "session_expired"
	CodeNotOwner         ErrorCode = "not_owner"
	CodeRevoked          ErrorCode = "revoked"
	CodeAdminRequired    ErrorCode = "admin_required"
	CodeNoBrowser        ErrorCode = "no_browser"
	CodeNoAction         ErrorCode = "no_action"
	CodeNoBlob           ErrorCode = "no_blob"
	CodeNoDefaultBrowser ErrorCode = "no_default_browser"
	CodeNoTargetTab      ErrorCode = "no_target_tab"
	CodeQueueFull        ErrorCode = "queue_full"
	CodeAlreadyRunning   ErrorCode = "already_running"
	CodeAlreadyComplete  ErrorCode = "already_complete"
	CodeVersionConflict  ErrorCode = "version_conflict"
	CodeExpired          ErrorCode = "expired"
	CodeLengthRequired   ErrorCode = "length_required"
	CodeNoBrowserLive    ErrorCode = "no_browser_live"
	CodeTooLarge         ErrorCode = "too_large"
	CodeStopped          ErrorCode = "stopped"
	CodeRateLimited      ErrorCode = "rate_limited"
	CodeInternal         ErrorCode = "internal"
	CodeStoreUnavailable ErrorCode = "store_unavailable"
	// CodeProtocolMismatch is what a party reports when it reads a protocol
	// version it does not know.
	CodeProtocolMismatch ErrorCode = "protocol_mismatch"
)

// Action codes. These arrive inside a result body rather than as an HTTP
// status, and the extension produces them.
const (
	CodeTabUnknown       ErrorCode = "tab_unknown"
	CodeTabClosed        ErrorCode = "tab_closed"
	CodeTabHeld          ErrorCode = "tab_held"
	CodeTabForbidden     ErrorCode = "tab_forbidden"
	CodeTabDiscarded     ErrorCode = "tab_discarded"
	CodeAttachFailed     ErrorCode = "attach_failed"
	CodeSelectorNotFound ErrorCode = "selector_not_found"
	CodeNavigationFailed ErrorCode = "navigation_failed"
	CodeTimeout          ErrorCode = "timeout"
	CodeJSError          ErrorCode = "js_error"
	CodeDialogAbsent     ErrorCode = "dialog_absent"
)

// transportStatus maps a transport code to its one HTTP status.
var transportStatus = map[ErrorCode]int{
	CodeBadRequest:       400,
	CodeBadID:            400,
	CodeProtocolMismatch: 400,
	CodeNoCredential:     401,
	CodeBadCredential:    401,
	CodeBadCode:          401,
	CodeSessionExpired:   401,
	CodeNotOwner:         403,
	CodeRevoked:          403,
	CodeAdminRequired:    403,
	CodeNoBrowser:        404,
	CodeNoAction:         404,
	CodeNoBlob:           404,
	CodeNoDefaultBrowser: 409,
	CodeNoTargetTab:      409,
	CodeQueueFull:        409,
	CodeAlreadyRunning:   409,
	CodeAlreadyComplete:  409,
	CodeVersionConflict:  409,
	CodeExpired:          410,
	CodeLengthRequired:   411,
	CodeNoBrowserLive:    412,
	CodeTooLarge:         413,
	CodeStopped:          423,
	CodeRateLimited:      429,
	CodeInternal:         500,
	CodeStoreUnavailable: 503,
}

// actionCodes are the codes the extension can put in a result. Three of them
// also exist as HTTP statuses, because the same condition can be reported from
// either side.
var actionCodes = map[ErrorCode]bool{
	CodeTabUnknown:       true,
	CodeTabClosed:        true,
	CodeTabHeld:          true,
	CodeTabForbidden:     true,
	CodeTabDiscarded:     true,
	CodeAttachFailed:     true,
	CodeSelectorNotFound: true,
	CodeNavigationFailed: true,
	CodeTimeout:          true,
	CodeJSError:          true,
	CodeDialogAbsent:     true,
	CodeStopped:          true,
	CodeExpired:          true,
	CodeInternal:         true,
}

// tabCodes are the action codes that mean "the tab you named is not usable".
// The CLI exits 4 for these, distinct from a general action failure, so a
// script can branch on it.
var tabCodes = map[ErrorCode]bool{
	CodeTabUnknown:   true,
	CodeTabClosed:    true,
	CodeTabHeld:      true,
	CodeTabForbidden: true,
	CodeTabDiscarded: true,
}

// Valid reports whether c is a code this protocol version defines.
func (c ErrorCode) Valid() bool {
	if _, ok := transportStatus[c]; ok {
		return true
	}
	return actionCodes[c]
}

// Transport reports whether c can be returned as an HTTP error.
func (c ErrorCode) Transport() bool {
	_, ok := transportStatus[c]
	return ok
}

// Action reports whether c can appear inside a result body.
func (c ErrorCode) Action() bool { return actionCodes[c] }

// TabFailure reports whether c means the named tab is not usable.
func (c ErrorCode) TabFailure() bool { return tabCodes[c] }

// HTTPStatus gives the one status this code belongs to, or 0 when the code
// only ever appears inside a result body.
func (c ErrorCode) HTTPStatus() int { return transportStatus[c] }

// Error is the body of every non-2xx response, and also the failure half of a
// result.
type Error struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
	Hint    string    `json:"hint,omitempty"`
	// Retryable tells a client whether the same request can be repeated
	// unchanged.
	Retryable bool `json:"retryable"`
}

// ErrorEnvelope wraps an Error for transport, so an error body is never
// confused with a result body.
type ErrorEnvelope struct {
	Error *Error `json:"error"`
}

func (e *Error) Error() string {
	if e == nil {
		return "<nil>"
	}
	if e.Message == "" {
		return string(e.Code)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}
