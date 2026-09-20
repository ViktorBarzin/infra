package wire

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// EventName is the SSE event name. The extension dispatches on this alone.
// There is no unnamed default event and no frame is identified by which of
// its fields happen to be truthy, so the server can add a frame type without
// breaking an older extension.
type EventName string

const (
	EventReady     EventName = "ready"
	EventHeartbeat EventName = "heartbeat"
	EventAction    EventName = "action"
	EventCancel    EventName = "cancel"
	EventControl   EventName = "control"
	EventSettings  EventName = "settings"
	EventError     EventName = "error"
)

// Valid reports whether n is an event name this protocol version defines. An
// unknown name is logged and ignored rather than guessed at.
func (n EventName) Valid() bool {
	switch n {
	case EventReady, EventHeartbeat, EventAction, EventCancel, EventControl, EventError, EventSettings:
		return true
	default:
		return false
	}
}

// ControlOp is an out-of-band instruction, handled the moment the frame is
// parsed, even while the action queue is stuck.
type ControlOp string

const (
	// OpStop is a full local teardown. The extension does not reconnect until
	// the human resumes.
	OpStop ControlOp = "stop"
	// OpDetachAll releases every debugger attachment and every borrowed tab
	// but keeps the stream.
	OpDetachAll ControlOp = "detachAll"
	// OpSuperseded says another stream took over this browserId.
	OpSuperseded ControlOp = "superseded"
	// OpReloadSettings asks the extension to re-read settings from the next
	// settings frame.
	OpReloadSettings ControlOp = "reloadSettings"
)

// Valid reports whether o is an op this protocol version defines.
func (o ControlOp) Valid() bool {
	switch o {
	case OpStop, OpDetachAll, OpSuperseded, OpReloadSettings:
		return true
	default:
		return false
	}
}

// CancelReason says why an action is no longer wanted.
type CancelReason string

const (
	ReasonExpired   CancelReason = "expired"
	ReasonCancelled CancelReason = "cancelled"
	ReasonStopped   CancelReason = "stopped"
)

// Valid reports whether r is a reason this protocol version defines.
func (r CancelReason) Valid() bool {
	switch r {
	case ReasonExpired, ReasonCancelled, ReasonStopped:
		return true
	default:
		return false
	}
}

// ReadyFrame is sent once, immediately on open, before anything else.
type ReadyFrame struct {
	V   int `json:"v"`
	Seq int `json:"seq"`

	BrowserID     string `json:"browserId"`
	ServerTime    int64  `json:"serverTime"`
	ServerVersion string `json:"serverVersion"`
	HeartbeatMs   int    `json:"heartbeatMs"`
	// StopEpoch lets the extension see that a stop landed while it was
	// offline, so it tears down before executing anything.
	StopEpoch int `json:"stopEpoch"`
	// ReplayCount is how many actions from the active index follow.
	ReplayCount        int   `json:"replayCount"`
	EnrolmentExpiresAt int64 `json:"enrolmentExpiresAt"`
}

// HeartbeatFrame is sent every HeartbeatMs, whether or not anything else was
// sent. It is a named event rather than an SSE comment, so the extension has
// one parsing path.
type HeartbeatFrame struct {
	V          int   `json:"v"`
	Seq        int   `json:"seq"`
	ServerTime int64 `json:"serverTime"`
	QueueDepth int   `json:"queueDepth"`
}

// ActionFrame carries one action to execute. It is the only frame that
// causes side effects.
type ActionFrame struct {
	V   int `json:"v"`
	Seq int `json:"seq"`

	ActionID  string     `json:"actionId"`
	SessionID string     `json:"sessionId"`
	Type      ActionType `json:"type"`
	// Params stays raw on this hop: the extension picks the shape by type.
	Params json.RawMessage `json:"params,omitempty"`
	Tab    string          `json:"tab,omitempty"`

	CreatedAt int64 `json:"createdAt"`
	TimeoutMs int   `json:"timeoutMs"`
	// ExpiresAt is the zombie cutoff, computed by the server so the two sides
	// cannot disagree.
	ExpiresAt int64 `json:"expiresAt"`
	Lane      Lane  `json:"lane"`
	// Replay is true on a redelivery. The extension uses it for logging;
	// deduplication is by ActionID.
	Replay bool `json:"replay"`
	// AgentLabel is a short name for the originating session, shown in the
	// popup feed and on the tab overlay.
	AgentLabel string `json:"agentLabel,omitempty"`
}

// CancelFrame tells the extension to stop caring about an action. A cancel
// for an unknown actionId is ignored silently, which is normal after a worker
// restart.
type CancelFrame struct {
	V        int          `json:"v"`
	Seq      int          `json:"seq"`
	ActionID string       `json:"actionId"`
	Reason   CancelReason `json:"reason"`
}

// ControlFrame carries an out-of-band instruction.
type ControlFrame struct {
	V   int       `json:"v"`
	Seq int       `json:"seq"`
	Op  ControlOp `json:"op"`
	// StopEpoch is set on a stop op.
	StopEpoch int `json:"stopEpoch,omitempty"`
	// Reason is optional prose for a superseded or detachAll op.
	Reason string `json:"reason,omitempty"`
}

// SettingsFrame carries the browser's settings, sent once after ready and
// again whenever they change. The extension ignores a frame whose Version is
// not greater than the one it holds, which makes a replay harmless.
type SettingsFrame struct {
	V        int      `json:"v"`
	Seq      int      `json:"seq"`
	Settings Settings `json:"settings"`
	Label    string   `json:"label,omitempty"`
	Version  int      `json:"version"`
}

// ErrorFrame reports a server-side problem that did not kill the stream. The
// extension surfaces it and keeps the connection, because reconnecting will
// not fix Redis being down.
type ErrorFrame struct {
	V       int       `json:"v"`
	Seq     int       `json:"seq"`
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

// EventID is the value of an SSE id line, <streamEpoch>.<seq>. The server
// uses a returned Last-Event-ID for exactly two things: skipping a settings
// frame the extension already has, and writing a correlated log line. It
// never decides from it which actions to replay, because the active index in
// Redis already answers that and a second source of truth would let the two
// disagree.
type EventID struct {
	StreamEpoch int64
	Seq         int
}

// String renders an EventID for the id line.
func (e EventID) String() string {
	return strconv.FormatInt(e.StreamEpoch, 10) + "." + strconv.Itoa(e.Seq)
}

// ParseEventID reads a Last-Event-ID header value.
func ParseEventID(s string) (EventID, error) {
	epoch, seq, ok := strings.Cut(s, ".")
	if !ok {
		return EventID{}, fmt.Errorf("event id %q has no dot", s)
	}
	e, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return EventID{}, fmt.Errorf("event id %q has a bad stream epoch: %w", s, err)
	}
	n, err := strconv.Atoi(seq)
	if err != nil {
		return EventID{}, fmt.Errorf("event id %q has a bad seq: %w", s, err)
	}
	if e < 0 || n < 0 {
		return EventID{}, fmt.Errorf("event id %q is negative", s)
	}
	return EventID{StreamEpoch: e, Seq: n}, nil
}
