package wire

import "encoding/json"

// Action results, one per action type. A boolean or a count that the
// protocol shows in a result is written without omitempty, because "clicked:
// false" and "count: 0" are answers rather than absences.

// Box is an element's viewport rectangle.
type Box struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// OpenResult is the result of nav.open.
type OpenResult struct {
	Tab   string `json:"tab"`
	URL   string `json:"url"`
	Title string `json:"title"`
	// StatusCode is 0 when the navigation produced no HTTP status, for
	// example a same-document navigation.
	StatusCode int `json:"statusCode"`
	LoadMs     int `json:"loadMs"`
}

// NavResult is the result of nav.back and nav.forward.
type NavResult struct {
	URL   string `json:"url"`
	Title string `json:"title"`
}

// ReloadResult is the result of nav.reload.
type ReloadResult struct {
	URL    string `json:"url"`
	Title  string `json:"title"`
	LoadMs int    `json:"loadMs"`
}

// URLResult is the result of nav.url.
type URLResult struct {
	URL        string `json:"url"`
	Title      string `json:"title"`
	Origin     string `json:"origin"`
	ReadyState string `json:"readyState"`
}

// ReadTextResult is the result of read.text. When Truncated is true the rest
// of the text is in the action's blob.
type ReadTextResult struct {
	Text      string `json:"text"`
	Truncated bool   `json:"truncated"`
}

// ReadHTMLResult is the result of read.html.
type ReadHTMLResult struct {
	HTML      string `json:"html"`
	Truncated bool   `json:"truncated"`
}

// QueryMatch is one element read.query matched.
type QueryMatch struct {
	Index   int               `json:"index"`
	Tag     string            `json:"tag"`
	Text    string            `json:"text"`
	Attrs   map[string]string `json:"attrs,omitempty"`
	Visible bool              `json:"visible"`
	Box     *Box              `json:"box,omitempty"`
}

// QueryResult is the result of read.query.
type QueryResult struct {
	Count   int          `json:"count"`
	Matches []QueryMatch `json:"matches"`
}

// EvalResult is the result of read.eval. Value is whatever the expression
// returned, so it stays raw: the caller knows the shape it asked for and the
// protocol does not.
type EvalResult struct {
	Value json.RawMessage `json:"value"`
	Type  string          `json:"type"`
}

// ScreenshotResult is the result of read.screenshot. The bytes are in the
// blob, fetched from GET /v1/blobs/{blobId}.
type ScreenshotResult struct {
	BlobID string `json:"blobId"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
	Bytes  int64  `json:"bytes"`
}

// ClickResult is the result of input.click.
type ClickResult struct {
	Clicked  bool   `json:"clicked"`
	Selector string `json:"selector,omitempty"`
	Box      *Box   `json:"box,omitempty"`
}

// TypeResult is the result of input.type.
type TypeResult struct {
	Typed bool `json:"typed"`
	Chars int  `json:"chars"`
}

// FillFailure names one field a form fill could not set. The protocol shows
// the field as an empty list; the shape here is this package's, so a caller
// learns which selector failed and why rather than only that one did.
type FillFailure struct {
	Selector string    `json:"selector"`
	Code     ErrorCode `json:"code"`
	Message  string    `json:"message,omitempty"`
}

// FillResult is the result of input.fill.
type FillResult struct {
	Filled int           `json:"filled"`
	Failed []FillFailure `json:"failed"`
}

// SelectResult is the result of input.select. Options lists what the element
// offered, which is what makes a failed match debuggable.
type SelectResult struct {
	Selected string   `json:"selected"`
	Options  []string `json:"options,omitempty"`
}

// PressResult is the result of input.press.
type PressResult struct {
	Pressed bool `json:"pressed"`
}

// HoverResult is the result of input.hover.
type HoverResult struct {
	Hovered bool `json:"hovered"`
	Box     *Box `json:"box,omitempty"`
}

// ScrollResult is the result of input.scroll.
type ScrollResult struct {
	ScrollX  float64 `json:"scrollX"`
	ScrollY  float64 `json:"scrollY"`
	AtBottom bool    `json:"atBottom"`
}

// DialogResult is the result of input.dialog.
type DialogResult struct {
	Handled    bool   `json:"handled"`
	DialogType string `json:"dialogType,omitempty"`
	Message    string `json:"message,omitempty"`
}

// WaitForResult is the result of wait.for. What names the condition that
// matched: "load", "text", "selector" or "url".
type WaitForResult struct {
	Matched  bool   `json:"matched"`
	What     string `json:"what"`
	WaitedMs int    `json:"waitedMs"`
}

// ConsoleEntry is one captured console line.
type ConsoleEntry struct {
	At     int64        `json:"at"`
	Level  ConsoleLevel `json:"level"`
	Text   string       `json:"text"`
	Source string       `json:"source,omitempty"`
	Line   int          `json:"line,omitempty"`
}

// ConsoleResult is the result of diag.console.
type ConsoleResult struct {
	Count   int            `json:"count"`
	Entries []ConsoleEntry `json:"entries,omitempty"`
}

// NetworkRequest is one captured request in the list form.
type NetworkRequest struct {
	ID     int    `json:"id"`
	Method string `json:"method"`
	URL    string `json:"url"`
	Status int    `json:"status"`
	Type   string `json:"type"`
	Bytes  int64  `json:"bytes"`
	Ms     int    `json:"ms"`
}

// NetworkRequestDetail is the single form, returned when the caller named one
// request id.
type NetworkRequestDetail struct {
	NetworkRequest
	RequestHeaders  map[string]string `json:"requestHeaders,omitempty"`
	ResponseHeaders map[string]string `json:"responseHeaders,omitempty"`
	PostData        string            `json:"postData,omitempty"`
	MimeType        string            `json:"mimeType,omitempty"`
}

// NetworkResult is the result of diag.network, in either form. Capture
// starts when the tab is attached, not at the start of time, so Count
// reports what the extension has.
type NetworkResult struct {
	Count    int              `json:"count,omitempty"`
	Requests []NetworkRequest `json:"requests,omitempty"`
	// Request is set in the single form. ResponseBlobID is set with it when
	// the caller asked for the body.
	Request        *NetworkRequestDetail `json:"request,omitempty"`
	ResponseBlobID string                `json:"responseBlobId,omitempty"`
}

// EmulateResult is the result of diag.emulate.
type EmulateResult struct {
	Applied []string `json:"applied"`
	Cleared []string `json:"cleared"`
}

// TabOwner says who opened a tab.
type TabOwner string

const (
	// OwnerAgent means an agent session created the tab.
	OwnerAgent TabOwner = "agent"
	// OwnerUser means the human opened it. An agent about to close a tab
	// should look at this.
	OwnerUser TabOwner = "user"
)

// Valid reports whether o is an owner the protocol defines.
func (o TabOwner) Valid() bool { return o == OwnerAgent || o == OwnerUser }

// TabState is whether a handle still points at a live tab.
type TabState string

const (
	TabOpen TabState = "open"
	// TabClosed handles stay listed for an hour after the tab closes, so an
	// agent that gets tab_closed can see what happened.
	TabClosed TabState = "closed"
)

// Valid reports whether s is a state the protocol defines.
func (s TabState) Valid() bool { return s == TabOpen || s == TabClosed }

// TabGroup is the Chrome tab group a tab sits in. Agent-created tabs get one
// group per agent session; a borrowed tab keeps whatever group the human had.
type TabGroup struct {
	GroupID int    `json:"groupId"`
	Title   string `json:"title,omitempty"`
	Color   string `json:"color,omitempty"`
}

// WindowInfo is one Chrome window.
type WindowInfo struct {
	WindowID int    `json:"windowId"`
	Focused  bool   `json:"focused"`
	TabCount int    `json:"tabCount"`
	State    string `json:"state"`
}

// TabInfo is one tab, as tab.list reports it. The full URL is here because an
// agent needs it to decide what to drive; the activity feed is stricter.
type TabInfo struct {
	Tab string `json:"tab"`
	// ChromeTabID is Chrome's own id. It is reported for diagnosis and is
	// never accepted as a target, because it does not survive a browser
	// restart or a discard.
	ChromeTabID int       `json:"chromeTabId"`
	Title       string    `json:"title"`
	URL         string    `json:"url"`
	Origin      string    `json:"origin"`
	WindowID    int       `json:"windowId"`
	Index       int       `json:"index"`
	Active      bool      `json:"active"`
	Audible     bool      `json:"audible"`
	Discarded   bool      `json:"discarded"`
	Group       *TabGroup `json:"group,omitempty"`
	Owner       TabOwner  `json:"owner"`
	// SessionID is present only for agent-owned tabs and names the session
	// that created it.
	SessionID string `json:"sessionId,omitempty"`
	Attached  bool   `json:"attached"`
	// AttachedBy names the session holding the debugger, when one does.
	AttachedBy string `json:"attachedBy,omitempty"`
	AttachedAt int64  `json:"attachedAt,omitempty"`
	// Rebound is true when reconciliation rebound this handle to a new Chrome
	// tab id, which is the signature of a discard.
	Rebound bool     `json:"rebound"`
	State   TabState `json:"state"`
}

// TabListResult is the result of tab.list. Enumeration needs no debugger and
// leaves no trace in the page, and is recorded in the activity feed anyway.
type TabListResult struct {
	BrowserID string       `json:"browserId"`
	At        int64        `json:"at"`
	Windows   []WindowInfo `json:"windows"`
	Tabs      []TabInfo    `json:"tabs"`
	// Truncated is true past MaxTabsListed tabs, in which case the list is
	// the most recently active ones.
	Truncated bool `json:"truncated"`
}

// AttachResult is the result of tab.attach. BannerShown records that Chrome
// raised its own "started debugging this browser" banner, which we never try
// to suppress.
type AttachResult struct {
	Tab         string   `json:"tab"`
	Title       string   `json:"title"`
	Origin      string   `json:"origin"`
	Owner       TabOwner `json:"owner"`
	BannerShown bool     `json:"bannerShown"`
}

// DetachResult is the result of tab.detach. ClearedOverrides names the
// override groups that died with the debugger session.
type DetachResult struct {
	Tab              string   `json:"tab"`
	WasAttached      bool     `json:"wasAttached"`
	ClearedOverrides []string `json:"clearedOverrides,omitempty"`
}

// ActivateResult is the result of tab.activate.
type ActivateResult struct {
	Tab      string `json:"tab"`
	WindowID int    `json:"windowId"`
	Focused  bool   `json:"focused"`
}

// CloseTabResult is the result of tab.close.
type CloseTabResult struct {
	Tab    string   `json:"tab"`
	Closed bool     `json:"closed"`
	Owner  TabOwner `json:"owner"`
}

// PingResult is the result of ctl.ping, which runs off-queue so it answers
// while the queue is stuck.
type PingResult struct {
	RoundTripMs      int    `json:"roundTripMs"`
	ExtensionVersion string `json:"extensionVersion"`
	QueueDepth       int    `json:"queueDepth"`
	AttachedTabs     int    `json:"attachedTabs"`
}
