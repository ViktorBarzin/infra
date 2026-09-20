// Package wire holds the browser-bridge v1 wire types: every HTTP request and
// response body, every SSE frame, and every action payload.
//
// The authoritative description is docs/protocol.md in this repo. Where a type
// here narrows something the document leaves open, the field carries a comment
// saying so. Nothing in this package talks to the network; it is shared by the
// server, the Go client and anything else that has to parse the same bytes.
package wire

// Version is the protocol version. It appears in every route prefix and on
// every SSE frame. A party that reads a version it does not know reports
// protocol_mismatch and stops rather than guessing at the payload.
const Version = 1

// RoutePrefix is the path prefix every versioned route lives under.
const RoutePrefix = "/v1"

// UIPrefix is the path prefix every route a signed-in human writes through
// lives under. It is a deployment fact as much as a naming one: Traefik
// routes by longest matching prefix, and only the forward-auth router carries
// the prefixes listed here, so a mutation parked outside this prefix reaches
// the server with no identity on it and is refused.
const UIPrefix = RoutePrefix + "/ui"

// Action timing. Durations are milliseconds, per the document's naming rule.
const (
	// DefaultActionTimeoutMs is the timeout an action gets when the caller
	// names none.
	DefaultActionTimeoutMs = 60000
	// MinActionTimeoutMs and MaxActionTimeoutMs bound timeoutMs on
	// POST /v1/actions.
	MinActionTimeoutMs = 1000
	MaxActionTimeoutMs = 600000
	// GraceMs is added to createdAt + timeoutMs to get the zombie cutoff.
	GraceMs = 30000
	// SessionTTLMs is how long an agent session lives from creation, not from
	// last use.
	SessionTTLMs = 86400000
	// EnrolmentTTLMs is the enrolment lifetime, refreshed on every reconnect.
	EnrolmentTTLMs = 2592000000
)

// Stream timing.
const (
	// HeartbeatMs is the interval between heartbeat frames.
	HeartbeatMs = 15000
	// StreamDeadMs is how long the extension waits with no frame of any kind
	// before it treats the stream as dead. Three missed heartbeats, because a
	// laptop suspending for a few seconds is normal.
	StreamDeadMs = 45000
	// ResendMs is how often the server resends an action that has been
	// delivered but has no result yet.
	ResendMs = 5000
	// LivenessTTLMs is the TTL on the liveness key, refreshed every
	// LivenessRefreshMs while a stream is open.
	LivenessTTLMs     = 90000
	LivenessRefreshMs = 30000
	// QueueStateTTLMs is the TTL on a queue-state report, so it clears itself
	// when the extension stops reporting.
	QueueStateTTLMs = 25000
)

// Long polling on GET /v1/actions/{actionId}.
const (
	DefaultPollWaitMs = 25000
	MaxPollWaitMs     = 30000
)

// Limits the server enforces.
const (
	// MaxQueueDepth is the per-browser cap on queued actions. Off-queue work
	// is not counted against it.
	MaxQueueDepth = 64
	// MaxBlobBytes is the per-blob cap, MaxBlobTotalBytes the cap across every
	// live blob on the server.
	MaxBlobBytes      = 16 << 20
	MaxBlobTotalBytes = 256 << 20
	// MaxActivityBatch is the most entries one POST /v1/activity may carry.
	MaxActivityBatch = 50
	// MaxActivityLimit is the largest limit GET /v1/activity accepts.
	MaxActivityLimit     = 50
	DefaultActivityLimit = 20
	// MaxTabsListed is where the tabs result truncates.
	MaxTabsListed = 300
	// MaxReadChars is where read.text and read.html truncate inline, spilling
	// the rest into a blob.
	MaxReadChars = 200000
)

// Header names. Credentials travel in headers, never in a query string.
const (
	// HeaderBrowserID and HeaderBrowserKey carry the browser credential.
	HeaderBrowserID  = "X-BB-Browser"
	HeaderBrowserKey = "X-BB-Key"
	// HeaderIngress carries the shared secret Traefik injects, which is what
	// stops a pod inside the cluster from reaching a UI route directly with a
	// forged identity header.
	HeaderIngress = "X-BB-Ingress"
	// HeaderAuthentikUser is the identity header the forward-auth middleware
	// stamps. Traefik deletes any inbound copy; the server fails closed when
	// it is absent.
	HeaderAuthentikUser = "X-authentik-username"
	// HeaderSession pins an agent session, for two agents sharing one browser.
	HeaderSession = "X-BB-Session"
	// HeaderIdempotency makes a retried POST /v1/actions return the original
	// actionId instead of creating a second action.
	HeaderIdempotency = "X-BB-Idempotency-Key"
	// HeaderExtensionVersion is optional on GET /v1/stream. It is how the
	// enrolment record learns which build is running, which is what
	// GET /v1/browsers reports as extensionVersion.
	HeaderExtensionVersion = "X-BB-Extension-Version"
)
