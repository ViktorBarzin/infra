package wire

// Action parameter payloads, one per action type, shaped per section 14 of
// the protocol. The server rejects an unknown field with bad_request, because
// a silently ignored flag is worse than a failed command, so every optional
// field here is omitempty and every field the extension reads is named.

// EmptyParams is the payload for the actions that take none: nav.back,
// nav.forward, nav.url and ctl.ping.
type EmptyParams struct{}

// MouseButton is which button a click dispatches.
type MouseButton string

const (
	ButtonLeft   MouseButton = "left"
	ButtonRight  MouseButton = "right"
	ButtonMiddle MouseButton = "middle"
)

// Valid reports whether b is a button the protocol defines. Empty means left.
func (b MouseButton) Valid() bool {
	switch b {
	case "", ButtonLeft, ButtonRight, ButtonMiddle:
		return true
	default:
		return false
	}
}

// Modifier is a key held during a press.
type Modifier string

const (
	ModCtrl  Modifier = "ctrl"
	ModShift Modifier = "shift"
	ModAlt   Modifier = "alt"
	ModMeta  Modifier = "meta"
)

// Valid reports whether m is a modifier the protocol defines.
func (m Modifier) Valid() bool {
	switch m {
	case ModCtrl, ModShift, ModAlt, ModMeta:
		return true
	default:
		return false
	}
}

// SelectBy says how input.select matches an option.
type SelectBy string

const (
	SelectByValue SelectBy = "value"
	SelectByLabel SelectBy = "label"
	SelectByIndex SelectBy = "index"
)

// Valid reports whether b is a match mode the protocol defines. Empty means
// by value.
func (b SelectBy) Valid() bool {
	switch b {
	case "", SelectByValue, SelectByLabel, SelectByIndex:
		return true
	default:
		return false
	}
}

// ConsoleLevel filters diag.console and labels a captured entry.
type ConsoleLevel string

const (
	LevelLog   ConsoleLevel = "log"
	LevelInfo  ConsoleLevel = "info"
	LevelWarn  ConsoleLevel = "warn"
	LevelError ConsoleLevel = "error"
	LevelDebug ConsoleLevel = "debug"
)

// Valid reports whether l is a level the protocol defines. Empty means every
// level.
func (l ConsoleLevel) Valid() bool {
	switch l {
	case "", LevelLog, LevelInfo, LevelWarn, LevelError, LevelDebug:
		return true
	default:
		return false
	}
}

// ColorScheme is what diag.emulate forces prefers-color-scheme to.
type ColorScheme string

const (
	SchemeDark  ColorScheme = "dark"
	SchemeLight ColorScheme = "light"
	SchemeAuto  ColorScheme = "auto"
)

// Valid reports whether s is a scheme the protocol defines. Empty leaves the
// scheme alone.
func (s ColorScheme) Valid() bool {
	switch s {
	case "", SchemeDark, SchemeLight, SchemeAuto:
		return true
	default:
		return false
	}
}

// NetworkProfile is a throttling preset for diag.emulate.
type NetworkProfile string

const (
	NetOffline NetworkProfile = "offline"
	NetSlow3G  NetworkProfile = "slow-3g"
	NetFast3G  NetworkProfile = "fast-3g"
	NetSlow4G  NetworkProfile = "slow-4g"
	NetFast4G  NetworkProfile = "fast-4g"
	NetNone    NetworkProfile = "none"
)

// Valid reports whether p is a profile the protocol defines. Empty leaves
// throttling alone; "none" clears it.
func (p NetworkProfile) Valid() bool {
	switch p {
	case "", NetOffline, NetSlow3G, NetFast3G, NetSlow4G, NetFast4G, NetNone:
		return true
	default:
		return false
	}
}

// Point is a viewport coordinate pair, for a click on a canvas or a map where
// no selector exists.
type Point struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

// GeoPoint is a geolocation override.
type GeoPoint struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

// Viewport is a device metrics override. DPR 0 means 1.
type Viewport struct {
	Width  int     `json:"width"`
	Height int     `json:"height"`
	DPR    float64 `json:"dpr,omitempty"`
	Mobile bool    `json:"mobile,omitempty"`
	Touch  bool    `json:"touch,omitempty"`
}

// OpenParams drives nav.open. Without NewTab and without a target tab it
// reuses the session's current tab. Focus defaults false, so an agent opening
// a page does not steal the human's attention.
type OpenParams struct {
	URL    string `json:"url"`
	NewTab bool   `json:"newTab,omitempty"`
	Focus  bool   `json:"focus,omitempty"`
	Group  string `json:"group,omitempty"`
}

// ReloadParams drives nav.reload.
type ReloadParams struct {
	IgnoreCache bool `json:"ignoreCache,omitempty"`
}

// ReadTextParams drives read.text. An empty selector reads the document.
type ReadTextParams struct {
	Selector string `json:"selector,omitempty"`
	MaxChars int    `json:"maxChars,omitempty"`
}

// ReadHTMLParams drives read.html. Inner asks for innerHTML rather than
// outerHTML.
type ReadHTMLParams struct {
	Selector string `json:"selector,omitempty"`
	Inner    bool   `json:"inner,omitempty"`
}

// QueryParams drives read.query.
type QueryParams struct {
	Selector string `json:"selector"`
	Max      int    `json:"max,omitempty"`
	Attrs    bool   `json:"attrs,omitempty"`
}

// EvalParams drives read.eval.
type EvalParams struct {
	Expression   string `json:"expression"`
	AwaitPromise bool   `json:"awaitPromise,omitempty"`
}

// ScreenshotParams drives read.screenshot. The result is always a blob,
// never inline bytes.
type ScreenshotParams struct {
	FullPage bool   `json:"fullPage,omitempty"`
	Selector string `json:"selector,omitempty"`
	Format   string `json:"format,omitempty"`
	Quality  int    `json:"quality,omitempty"`
}

// ClickParams drives input.click.
type ClickParams struct {
	Selector string      `json:"selector,omitempty"`
	At       *Point      `json:"at,omitempty"`
	Double   bool        `json:"double,omitempty"`
	Button   MouseButton `json:"button,omitempty"`
}

// TypeParams drives input.type. SubmitKey sends Enter after the text.
type TypeParams struct {
	Selector  string `json:"selector"`
	Text      string `json:"text"`
	Clear     bool   `json:"clear,omitempty"`
	SubmitKey bool   `json:"submitKey,omitempty"`
	DelayMs   int    `json:"delayMs,omitempty"`
}

// FillField is one field of a form fill.
type FillField struct {
	Selector string `json:"selector"`
	Value    string `json:"value"`
}

// FillParams drives input.fill. A whole form in one action is one queue slot
// and one activity entry instead of six.
type FillParams struct {
	Fields []FillField `json:"fields"`
}

// SelectParams drives input.select.
type SelectParams struct {
	Selector string   `json:"selector"`
	Value    string   `json:"value"`
	By       SelectBy `json:"by,omitempty"`
}

// PressParams drives input.press.
type PressParams struct {
	Key       string     `json:"key"`
	Modifiers []Modifier `json:"modifiers,omitempty"`
}

// HoverParams drives input.hover.
type HoverParams struct {
	Selector string `json:"selector"`
}

// ScrollParams drives input.scroll. With a selector it scrolls that element
// into view; with DX or DY it scrolls the page by that many pixels.
type ScrollParams struct {
	Selector string  `json:"selector,omitempty"`
	DX       float64 `json:"dx,omitempty"`
	DY       float64 `json:"dy,omitempty"`
}

// DialogParams drives input.dialog.
type DialogParams struct {
	Accept     bool   `json:"accept"`
	PromptText string `json:"promptText,omitempty"`
}

// WaitForParams drives wait.for. With no field set it waits for the tab's
// in-flight load to finish. Otherwise it resolves on the first condition that
// matches.
type WaitForParams struct {
	Texts       []string `json:"texts,omitempty"`
	Selector    string   `json:"selector,omitempty"`
	Gone        bool     `json:"gone,omitempty"`
	URLContains string   `json:"urlContains,omitempty"`
}

// ConsoleParams drives diag.console.
type ConsoleParams struct {
	Tail      int          `json:"tail,omitempty"`
	Head      int          `json:"head,omitempty"`
	Level     ConsoleLevel `json:"level,omitempty"`
	CountOnly bool         `json:"countOnly,omitempty"`
	Clear     bool         `json:"clear,omitempty"`
}

// NetworkParams drives diag.network. With RequestID it returns one request in
// the single form; otherwise it returns a list.
type NetworkParams struct {
	RequestID int `json:"requestId,omitempty"`
	// Types filters by resource type, as CDP names them: document, xhr,
	// fetch, script, stylesheet, image and so on.
	Types         []string `json:"types,omitempty"`
	Limit         int      `json:"limit,omitempty"`
	IncludePreNav bool     `json:"includePreNav,omitempty"`
	WantBody      bool     `json:"wantBody,omitempty"`
}

// EmulateParams drives diag.emulate. Everything it sets is bound to the
// debugger session and is cleared by a detach, a stop or the idle detach, so
// it never outlives the attachment.
type EmulateParams struct {
	ColorScheme  ColorScheme       `json:"colorScheme,omitempty"`
	CPUThrottle  float64           `json:"cpuThrottle,omitempty"`
	Network      NetworkProfile    `json:"network,omitempty"`
	Geolocation  *GeoPoint         `json:"geolocation,omitempty"`
	UserAgent    string            `json:"userAgent,omitempty"`
	Viewport     *Viewport         `json:"viewport,omitempty"`
	ExtraHeaders map[string]string `json:"extraHeaders,omitempty"`
	Reset        bool              `json:"reset,omitempty"`
}

// TabListParams drives tab.list. WindowID 0 lists every window. OnlyAgent
// keeps the result to tabs an agent session created.
type TabListParams struct {
	WindowID  int  `json:"windowId,omitempty"`
	OnlyAgent bool `json:"onlyAgent,omitempty"`
}

// AttachParams drives tab.attach. The tab may be one the human opened.
type AttachParams struct {
	Tab string `json:"tab"`
}

// DetachParams drives tab.detach. All releases every tab this session holds.
type DetachParams struct {
	Tab string `json:"tab,omitempty"`
	All bool   `json:"all,omitempty"`
}

// ActivateParams drives tab.activate, which focuses a tab and raises its
// window. It is how an agent shows a human what it is looking at.
type ActivateParams struct {
	Tab string `json:"tab"`
}

// CloseTabParams drives tab.close. Closing a tab the human opened is allowed
// and is recorded with owner "user"; the CLI's --force flag suppresses only
// its own warning line, never the record, so it is not a wire field.
type CloseTabParams struct {
	Tab string `json:"tab"`
}
