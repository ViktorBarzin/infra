package wire

// The activity record is what stands in for an approval gate. Every action
// and every enumeration produces exactly one entry, including off-queue
// commands, including tab.list, including actions that failed and actions a
// stop cancelled.

// ActivityKind says what produced an entry.
type ActivityKind string

const (
	ActivityAction      ActivityKind = "action"
	ActivityEnumeration ActivityKind = "enumeration"
	ActivityAttach      ActivityKind = "attach"
	ActivityDetach      ActivityKind = "detach"
	ActivityAutoDetach  ActivityKind = "autoDetach"
	ActivityTabClosed   ActivityKind = "tabClosed"
	ActivityStop        ActivityKind = "stop"
	ActivityResume      ActivityKind = "resume"
)

// Valid reports whether k is a kind this protocol version defines.
func (k ActivityKind) Valid() bool {
	switch k {
	case ActivityAction, ActivityEnumeration, ActivityAttach, ActivityDetach,
		ActivityAutoDetach, ActivityTabClosed, ActivityStop, ActivityResume:
		return true
	default:
		return false
	}
}

// ActivityOutcome is how an entry ended.
type ActivityOutcome string

const (
	OutcomeOK    ActivityOutcome = "ok"
	OutcomeError ActivityOutcome = "error"
	// OutcomeRunning is updated in place once, on completion.
	OutcomeRunning ActivityOutcome = "running"
)

// Valid reports whether o is an outcome this protocol version defines.
func (o ActivityOutcome) Valid() bool {
	switch o {
	case OutcomeOK, OutcomeError, OutcomeRunning:
		return true
	default:
		return false
	}
}

// ActivityEntry is one line of the feed the popup renders and the web UI and
// the CLI mirror.
type ActivityEntry struct {
	// Seq is monotonic per browser, never reused, and survives a worker
	// restart.
	Seq  int64        `json:"seq"`
	At   int64        `json:"at"`
	Kind ActivityKind `json:"kind"`
	// Type is the action type, or tab.list for an enumeration.
	Type       ActionType `json:"type,omitempty"`
	ActionID   string     `json:"actionId,omitempty"`
	SessionID  string     `json:"sessionId,omitempty"`
	AgentLabel string     `json:"agentLabel,omitempty"`

	Tab string `json:"tab,omitempty"`
	// Title is truncated to 120 characters.
	Title  string `json:"title,omitempty"`
	Origin string `json:"origin,omitempty"`
	// Path carries no query string. A query can hold a token or a search
	// term, and this feed is the most shoulder-surfable thing in the system.
	// An agent that needs the full URL has it in the tab.list result.
	Path string `json:"path,omitempty"`
	// Owner makes borrowing a human's tab visibly different from driving one
	// the agent opened.
	Owner      TabOwner        `json:"owner,omitempty"`
	Outcome    ActivityOutcome `json:"outcome,omitempty"`
	DurationMs int             `json:"durationMs,omitempty"`
}

// ActivityResponse is the 200 from GET /v1/activity, newest first.
type ActivityResponse struct {
	Entries []ActivityEntry `json:"entries"`
}

// ActivityPushRequest is the body of POST /v1/activity, at most
// MaxActivityBatch entries. The extension's own ring buffer stays
// authoritative; this mirror exists so the web UI has something to show.
type ActivityPushRequest struct {
	Entries []ActivityEntry `json:"entries"`
}

// ActivityPushResponse is the 200 from POST /v1/activity.
type ActivityPushResponse struct {
	Accepted int `json:"accepted"`
}
