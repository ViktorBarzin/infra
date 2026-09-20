package wire

// Browser is one enrolled Chrome, as its owner sees it.
type Browser struct {
	BrowserID string `json:"browserId"`
	Label     string `json:"label"`
	// Default is the browser an agent gets when it names none.
	Default bool `json:"default"`
	// Live reads the liveness key and nothing else.
	Live             bool   `json:"live"`
	LastSeenAt       int64  `json:"lastSeenAt"`
	EnrolledAt       int64  `json:"enrolledAt"`
	ExpiresAt        int64  `json:"expiresAt"`
	ExtensionVersion string `json:"extensionVersion,omitempty"`
	QueueDepth       int    `json:"queueDepth"`
	StopEpoch        int    `json:"stopEpoch"`
	Stopped          bool   `json:"stopped"`
}

// BrowsersResponse is the 200 from GET /v1/browsers.
type BrowsersResponse struct {
	Browsers []Browser `json:"browsers"`
}

// ServerInfo is the server half of GET /v1/status. StoreOk false means Redis
// is unreachable and every action route is answering store_unavailable.
type ServerInfo struct {
	Version  string `json:"version"`
	Protocol int    `json:"protocol"`
	StoreOk  bool   `json:"storeOk"`
}

// BrowserStatus is the browser half of GET /v1/status.
type BrowserStatus struct {
	BrowserID  string `json:"browserId"`
	Label      string `json:"label"`
	Live       bool   `json:"live"`
	Stopped    bool   `json:"stopped"`
	QueueDepth int    `json:"queueDepth"`
	// CurrentAction is null when the browser is idle.
	CurrentAction    *string `json:"currentAction"`
	ExtensionVersion string  `json:"extensionVersion,omitempty"`
}

// SessionInfo is the session half of GET /v1/status.
type SessionInfo struct {
	SessionID  string `json:"sessionId"`
	ExpiresAt  int64  `json:"expiresAt"`
	CurrentTab string `json:"currentTab,omitempty"`
}

// StatusResponse answers "can I drive a browser right now". Browser is null
// when the caller has no enrolled browser, and the call needs no browser at
// all, which is what makes it the first thing to run.
type StatusResponse struct {
	Server  ServerInfo     `json:"server"`
	User    string         `json:"user"`
	Browser *BrowserStatus `json:"browser"`
	Session *SessionInfo   `json:"session,omitempty"`
}

// Settings are the per-browser settings, sent in full on the settings frame.
type Settings struct {
	CursorOverlay  bool   `json:"cursorOverlay"`
	GroupAgentTabs bool   `json:"groupAgentTabs"`
	GroupColor     string `json:"groupColor"`
	// IdleDetachMs is how long a borrowed tab may sit with no action before
	// the extension detaches on its own. Without it a forgotten attach leaves
	// Chrome's banner up on a page the human is using.
	IdleDetachMs int `json:"idleDetachMs"`
	// ActivityMirror false keeps the activity feed on the machine.
	ActivityMirror bool `json:"activityMirror"`
}

// SettingsPatch is a partial settings update. Every field is a pointer
// because PATCH merges field by field under the record's version check, so
// two open settings tabs cannot revert each other.
type SettingsPatch struct {
	CursorOverlay  *bool   `json:"cursorOverlay,omitempty"`
	GroupAgentTabs *bool   `json:"groupAgentTabs,omitempty"`
	GroupColor     *string `json:"groupColor,omitempty"`
	IdleDetachMs   *int    `json:"idleDetachMs,omitempty"`
	ActivityMirror *bool   `json:"activityMirror,omitempty"`
}

// PatchBrowserRequest is the body of PATCH /v1/browsers/{id}.
type PatchBrowserRequest struct {
	Label    string         `json:"label,omitempty"`
	Settings *SettingsPatch `json:"settings,omitempty"`
}

// EnrolRequest is the body of POST /v1/enrol, posted by the enrolment page
// under the human's Authentik session.
type EnrolRequest struct {
	ExtensionID string `json:"extensionId"`
	// Nonce is what stops another page, or a second enrolment tab, from
	// injecting a credential the extension did not ask for.
	Nonce string `json:"nonce"`
	Label string `json:"label,omitempty"`
}

// EnrolResponse is the 201 from POST /v1/enrol. The key is returned once and
// never again. Default is true when this is the user's first browser, which
// is what lets an agent run with no further human action.
type EnrolResponse struct {
	BrowserID  string `json:"browserId"`
	BrowserKey string `json:"browserKey"`
	ExpiresAt  int64  `json:"expiresAt"`
	Default    bool   `json:"default"`
}

// PairRequest is the body of POST /v1/pair. The route takes the CLI
// credential, which is the change from the original design where anyone could
// mint browser credentials.
type PairRequest struct {
	Label string `json:"label,omitempty"`
}

// PairResponse is the 201 from POST /v1/pair.
type PairResponse struct {
	Code         string `json:"code"`
	ExpiresAt    int64  `json:"expiresAt"`
	AttemptsLeft int    `json:"attemptsLeft"`
}

// PairRedeemRequest is the body of POST /v1/pair/redeem. The code is the
// credential on that route, because the browser has no id and no key yet.
type PairRedeemRequest struct {
	Code        string `json:"code"`
	ExtensionID string `json:"extensionId"`
	Label       string `json:"label,omitempty"`
}

// PairRedeemResponse is the 201 from POST /v1/pair/redeem. The enrolment is
// owned by the Authentik user behind the CLI token that minted the code, so
// identity flows from the authenticated side.
type PairRedeemResponse struct {
	BrowserID  string `json:"browserId"`
	BrowserKey string `json:"browserKey"`
	Owner      string `json:"owner"`
	ExpiresAt  int64  `json:"expiresAt"`
}

// StopRequest is the body of POST /v1/control/stop. BrowserID is optional
// and defaults to the caller's default browser.
type StopRequest struct {
	BrowserID string `json:"browserId,omitempty"`
}

// StopResponse is the 200 from POST /v1/control/stop. The epoch bumps even
// when the browser is not live, so a stop issued while a laptop is shut does
// not evaporate when the laptop wakes.
type StopResponse struct {
	BrowserID   string `json:"browserId"`
	StopEpoch   int    `json:"stopEpoch"`
	Cancelled   int    `json:"cancelled"`
	BrowserLive bool   `json:"browserLive"`
}

// AdminTokenRequest is the body of POST /v1/admin/tokens.
type AdminTokenRequest struct {
	OSUser        string `json:"osUser"`
	AuthentikUser string `json:"authentikUser"`
}

// AdminTokenResponse is the 201 from POST /v1/admin/tokens. The token is
// returned once and never again.
type AdminTokenResponse struct {
	Token  string `json:"token"`
	OSUser string `json:"osUser"`
}

// QueueStateRequest is the body of POST /v1/queue-state, sent by the
// extension every 10 seconds while the queue is non-empty and once on the
// transition to empty.
type QueueStateRequest struct {
	QueueDepth int `json:"queueDepth"`
	// OffQueueCount is counted separately, because off-queue work does not
	// count against MaxQueueDepth.
	OffQueueCount int    `json:"offQueueCount"`
	CurrentAction string `json:"currentAction,omitempty"`
	AttachedTabs  int    `json:"attachedTabs"`
}

// OkResponse is the body of the routes that answer nothing but success.
type OkResponse struct {
	Ok bool `json:"ok"`
}
