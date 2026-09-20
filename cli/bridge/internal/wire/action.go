package wire

import "encoding/json"

// ActionType names one unit of work the extension can perform. There are 28,
// one for each of the 30 CLI commands except status and stop, which are
// server routes and never reach the browser as an action.
type ActionType string

// Navigation.
const (
	ActionNavOpen    ActionType = "nav.open"
	ActionNavBack    ActionType = "nav.back"
	ActionNavForward ActionType = "nav.forward"
	ActionNavReload  ActionType = "nav.reload"
	ActionNavURL     ActionType = "nav.url"
)

// Reading.
const (
	ActionReadText       ActionType = "read.text"
	ActionReadHTML       ActionType = "read.html"
	ActionReadQuery      ActionType = "read.query"
	ActionReadEval       ActionType = "read.eval"
	ActionReadScreenshot ActionType = "read.screenshot"
)

// Input.
const (
	ActionInputClick  ActionType = "input.click"
	ActionInputType   ActionType = "input.type"
	ActionInputFill   ActionType = "input.fill"
	ActionInputSelect ActionType = "input.select"
	ActionInputPress  ActionType = "input.press"
	ActionInputHover  ActionType = "input.hover"
	ActionInputScroll ActionType = "input.scroll"
	ActionInputDialog ActionType = "input.dialog"
)

// Waiting.
const ActionWaitFor ActionType = "wait.for"

// Diagnostics.
const (
	ActionDiagConsole ActionType = "diag.console"
	ActionDiagNetwork ActionType = "diag.network"
	ActionDiagEmulate ActionType = "diag.emulate"
)

// Tab access. These drive tabs the human opened as readily as tabs the agent
// created, which is the point of the tool.
const (
	ActionTabList     ActionType = "tab.list"
	ActionTabAttach   ActionType = "tab.attach"
	ActionTabDetach   ActionType = "tab.detach"
	ActionTabActivate ActionType = "tab.activate"
	ActionTabClose    ActionType = "tab.close"
)

// Plumbing.
const ActionCtlPing ActionType = "ctl.ping"

// Lane says how the extension schedules an action.
type Lane string

const (
	// LaneSerial shares the debugger attachment and the cursor overlay, so
	// interleaving produces wrong results rather than slow ones.
	LaneSerial Lane = "serial"
	// LaneOffQueue touches chrome.tabs, chrome.windows or chrome.scripting and
	// never the shared debugger, so it stays responsive while the queue is
	// stuck. That is when a human most needs detach, stop and ping.
	LaneOffQueue Lane = "offQueue"
	// LaneSplit serialises the attach, the dispatch and the immediate status
	// read, and runs the load wait off-queue, so one cold dev server cannot
	// starve every other command.
	LaneSplit Lane = "split"
)

var actionLanes = map[ActionType]Lane{
	ActionNavOpen:        LaneSplit,
	ActionNavReload:      LaneSplit,
	ActionTabList:        LaneOffQueue,
	ActionTabDetach:      LaneOffQueue,
	ActionTabActivate:    LaneOffQueue,
	ActionTabClose:       LaneOffQueue,
	ActionWaitFor:        LaneOffQueue,
	ActionCtlPing:        LaneOffQueue,
	ActionNavBack:        LaneSerial,
	ActionNavForward:     LaneSerial,
	ActionNavURL:         LaneSerial,
	ActionReadText:       LaneSerial,
	ActionReadHTML:       LaneSerial,
	ActionReadQuery:      LaneSerial,
	ActionReadEval:       LaneSerial,
	ActionReadScreenshot: LaneSerial,
	ActionInputClick:     LaneSerial,
	ActionInputType:      LaneSerial,
	ActionInputFill:      LaneSerial,
	ActionInputSelect:    LaneSerial,
	ActionInputPress:     LaneSerial,
	ActionInputHover:     LaneSerial,
	ActionInputScroll:    LaneSerial,
	ActionInputDialog:    LaneSerial,
	ActionDiagConsole:    LaneSerial,
	ActionDiagNetwork:    LaneSerial,
	ActionDiagEmulate:    LaneSerial,
	// tab.attach is serialised even though it is tab management, because it
	// takes the debugger attachment and writes the handle map.
	ActionTabAttach: LaneSerial,
}

// actionOrder keeps ActionTypes deterministic, grouped the way section 14 of
// the protocol groups the commands.
var actionOrder = []ActionType{
	ActionNavOpen, ActionNavBack, ActionNavForward, ActionNavReload, ActionNavURL,
	ActionReadText, ActionReadHTML, ActionReadQuery, ActionReadEval, ActionReadScreenshot,
	ActionInputClick, ActionInputType, ActionInputFill, ActionInputSelect, ActionInputPress,
	ActionInputHover, ActionInputScroll, ActionInputDialog,
	ActionWaitFor,
	ActionDiagConsole, ActionDiagNetwork, ActionDiagEmulate,
	ActionTabList, ActionTabAttach, ActionTabDetach, ActionTabActivate, ActionTabClose,
	ActionCtlPing,
}

// ActionTypes lists every action type, in protocol order.
func ActionTypes() []ActionType {
	out := make([]ActionType, len(actionOrder))
	copy(out, actionOrder)
	return out
}

// Valid reports whether t is an action type this protocol version defines.
func (t ActionType) Valid() bool {
	_, ok := actionLanes[t]
	return ok
}

// Lane gives the queue lane for t. An unknown type is treated as serial,
// which is the safe answer: it takes the queue rather than racing whatever
// holds the debugger.
func (t ActionType) Lane() Lane {
	if l, ok := actionLanes[t]; ok {
		return l
	}
	return LaneSerial
}

func (t ActionType) String() string { return string(t) }

// ActionState is where an action has got to.
type ActionState string

const (
	StateQueued    ActionState = "queued"
	StateRunning   ActionState = "running"
	StateDone      ActionState = "done"
	StateExpired   ActionState = "expired"
	StateCancelled ActionState = "cancelled"
	StateStopped   ActionState = "stopped"
)

// Terminal reports whether the state is final, so a poller can stop.
func (s ActionState) Terminal() bool {
	switch s {
	case StateDone, StateExpired, StateCancelled, StateStopped:
		return true
	default:
		return false
	}
}

// CreateActionRequest is the body of POST /v1/actions, the only route that
// creates work.
type CreateActionRequest struct {
	// BrowserID is optional. Absent, the server uses the caller's default
	// browser.
	BrowserID string     `json:"browserId,omitempty"`
	Type      ActionType `json:"type"`
	// Params is the action's own payload. It is opaque at this layer; the
	// typed shapes are in params.go.
	Params json.RawMessage `json:"params,omitempty"`
	// Tab may name any tab handle in that browser, including one the human
	// opened. Absent, the action targets the session's current tab.
	Tab string `json:"tab,omitempty"`
	// TimeoutMs defaults per action type, DefaultActionTimeoutMs where the
	// type has no default.
	TimeoutMs int `json:"timeoutMs,omitempty"`
	// IdempotencyKey makes a retried POST return the original actionId.
	// Scoped to the session and remembered for 10 minutes.
	IdempotencyKey string `json:"idempotencyKey,omitempty"`
}

// CreateActionResponse is the 201 from POST /v1/actions.
type CreateActionResponse struct {
	ActionID   string `json:"actionId"`
	SessionID  string `json:"sessionId"`
	BrowserID  string `json:"browserId"`
	QueueDepth int    `json:"queueDepth"`
	// Lane lets the caller set an honest progress message.
	Lane      Lane  `json:"lane"`
	CreatedAt int64 `json:"createdAt"`
	// ExpiresAt is the zombie cutoff, createdAt + timeoutMs + GraceMs. It is
	// not the record's TTL.
	ExpiresAt int64 `json:"expiresAt"`
}

// TabRef names the tab an action touched, as the extension saw it at the time.
type TabRef struct {
	Handle string `json:"handle"`
	Title  string `json:"title,omitempty"`
	Origin string `json:"origin,omitempty"`
}

// ActionStatus is the 200 from GET /v1/actions/{actionId}, both while the
// action runs and once it has finished.
type ActionStatus struct {
	ActionID string      `json:"actionId"`
	State    ActionState `json:"state"`
	// QueuePosition is present while the action is queued or running.
	QueuePosition *int `json:"queuePosition,omitempty"`
	// Ok is present only when State is done.
	Ok *bool `json:"ok,omitempty"`
	// Result is the action's typed result, shaped per results.go. It is
	// opaque here because one field carries 28 different shapes.
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
	Blob   *BlobRef        `json:"blob,omitempty"`
	Tab    *TabRef         `json:"tab,omitempty"`

	StartedAt  int64 `json:"startedAt,omitempty"`
	FinishedAt int64 `json:"finishedAt,omitempty"`
}

// Succeeded reports whether the action finished and reported success.
func (s *ActionStatus) Succeeded() bool {
	return s != nil && s.State == StateDone && s.Ok != nil && *s.Ok
}

// CancelActionResponse is the 200 from DELETE /v1/actions/{actionId}.
type CancelActionResponse struct {
	State ActionState `json:"state"`
}

// ResultRequest is the body of POST /v1/results, sent by the extension.
type ResultRequest struct {
	ActionID string          `json:"actionId"`
	Ok       bool            `json:"ok"`
	Result   json.RawMessage `json:"result,omitempty"`
	Error    *Error          `json:"error,omitempty"`
	// BlobID names a payload already uploaded through POST /v1/blobs. Bytes
	// never travel through the stream and never go into Redis.
	BlobID     string  `json:"blobId,omitempty"`
	Tab        *TabRef `json:"tab,omitempty"`
	StartedAt  int64   `json:"startedAt,omitempty"`
	FinishedAt int64   `json:"finishedAt,omitempty"`
}

// ResultResponse is the 200 from POST /v1/results. Duplicate is true when the
// same result was already recorded, which makes a retry after a lost response
// safe.
type ResultResponse struct {
	Ok        bool `json:"ok"`
	Duplicate bool `json:"duplicate,omitempty"`
}
