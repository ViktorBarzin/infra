package client

import "github.com/ViktorBarzin/browser-bridge/internal/wire"

// The protocol types live in internal/wire, which another module cannot
// import. These aliases are how a consumer such as the homelab CLI names
// them: client.ClickParams is wire.ClickParams, the same type, so a value
// built here passes straight into a method on Client.
//
// Only the CLI-facing surface is re-exported. The SSE frames, the enrolment
// bodies and the extension's own uploads belong to the server and the
// extension, which are in this module and import wire directly.

// Protocol enums.
type (
	ActionState     = wire.ActionState
	ActionType      = wire.ActionType
	ActivityKind    = wire.ActivityKind
	ActivityOutcome = wire.ActivityOutcome
	ColorScheme     = wire.ColorScheme
	Command         = wire.Command
	ConsoleLevel    = wire.ConsoleLevel
	ErrorCode       = wire.ErrorCode
	IDKind          = wire.IDKind
	Lane            = wire.Lane
	Modifier        = wire.Modifier
	MouseButton     = wire.MouseButton
	NetworkProfile  = wire.NetworkProfile
	SelectBy        = wire.SelectBy
	TabOwner        = wire.TabOwner
	TabState        = wire.TabState
)

// Action parameters, results and the bodies a CLI reads.
type (
	ActionStatus         = wire.ActionStatus
	ActivateParams       = wire.ActivateParams
	ActivateResult       = wire.ActivateResult
	ActivityEntry        = wire.ActivityEntry
	AttachParams         = wire.AttachParams
	AttachResult         = wire.AttachResult
	BlobRef              = wire.BlobRef
	Box                  = wire.Box
	Browser              = wire.Browser
	BrowserStatus        = wire.BrowserStatus
	CancelActionResponse = wire.CancelActionResponse
	ClickParams          = wire.ClickParams
	ClickResult          = wire.ClickResult
	CloseTabParams       = wire.CloseTabParams
	CloseTabResult       = wire.CloseTabResult
	ConsoleEntry         = wire.ConsoleEntry
	ConsoleParams        = wire.ConsoleParams
	ConsoleResult        = wire.ConsoleResult
	CreateActionResponse = wire.CreateActionResponse
	DetachParams         = wire.DetachParams
	DetachResult         = wire.DetachResult
	DialogParams         = wire.DialogParams
	DialogResult         = wire.DialogResult
	EmulateParams        = wire.EmulateParams
	EmulateResult        = wire.EmulateResult
	Error                = wire.Error
	ErrorEnvelope        = wire.ErrorEnvelope
	EvalParams           = wire.EvalParams
	EvalResult           = wire.EvalResult
	FillFailure          = wire.FillFailure
	FillField            = wire.FillField
	FillParams           = wire.FillParams
	FillResult           = wire.FillResult
	GeoPoint             = wire.GeoPoint
	HoverParams          = wire.HoverParams
	HoverResult          = wire.HoverResult
	NavResult            = wire.NavResult
	NetworkParams        = wire.NetworkParams
	NetworkRequest       = wire.NetworkRequest
	NetworkRequestDetail = wire.NetworkRequestDetail
	NetworkResult        = wire.NetworkResult
	OpenParams           = wire.OpenParams
	OpenResult           = wire.OpenResult
	PairResponse         = wire.PairResponse
	PingResult           = wire.PingResult
	Point                = wire.Point
	PressParams          = wire.PressParams
	PressResult          = wire.PressResult
	QueryMatch           = wire.QueryMatch
	QueryParams          = wire.QueryParams
	QueryResult          = wire.QueryResult
	ReadHTMLParams       = wire.ReadHTMLParams
	ReadHTMLResult       = wire.ReadHTMLResult
	ReadTextParams       = wire.ReadTextParams
	ReadTextResult       = wire.ReadTextResult
	ReloadParams         = wire.ReloadParams
	ReloadResult         = wire.ReloadResult
	ScreenshotParams     = wire.ScreenshotParams
	ScreenshotResult     = wire.ScreenshotResult
	ScrollParams         = wire.ScrollParams
	ScrollResult         = wire.ScrollResult
	SelectParams         = wire.SelectParams
	SelectResult         = wire.SelectResult
	ServerInfo           = wire.ServerInfo
	SessionInfo          = wire.SessionInfo
	Settings             = wire.Settings
	StatusResponse       = wire.StatusResponse
	StopResponse         = wire.StopResponse
	TabGroup             = wire.TabGroup
	TabInfo              = wire.TabInfo
	TabListParams        = wire.TabListParams
	TabListResult        = wire.TabListResult
	TabRef               = wire.TabRef
	TypeParams           = wire.TypeParams
	TypeResult           = wire.TypeResult
	URLResult            = wire.URLResult
	Viewport             = wire.Viewport
	WaitForParams        = wire.WaitForParams
	WaitForResult        = wire.WaitForResult
	WindowInfo           = wire.WindowInfo
)

// Protocol constants, so a caller can compare a code or name an action
// without reaching into the module.
const (
	ActionCtlPing          = wire.ActionCtlPing
	ActionDiagConsole      = wire.ActionDiagConsole
	ActionDiagEmulate      = wire.ActionDiagEmulate
	ActionDiagNetwork      = wire.ActionDiagNetwork
	ActionInputClick       = wire.ActionInputClick
	ActionInputDialog      = wire.ActionInputDialog
	ActionInputFill        = wire.ActionInputFill
	ActionInputHover       = wire.ActionInputHover
	ActionInputPress       = wire.ActionInputPress
	ActionInputScroll      = wire.ActionInputScroll
	ActionInputSelect      = wire.ActionInputSelect
	ActionInputType        = wire.ActionInputType
	ActionNavBack          = wire.ActionNavBack
	ActionNavForward       = wire.ActionNavForward
	ActionNavOpen          = wire.ActionNavOpen
	ActionNavReload        = wire.ActionNavReload
	ActionNavURL           = wire.ActionNavURL
	ActionReadEval         = wire.ActionReadEval
	ActionReadHTML         = wire.ActionReadHTML
	ActionReadQuery        = wire.ActionReadQuery
	ActionReadScreenshot   = wire.ActionReadScreenshot
	ActionReadText         = wire.ActionReadText
	ActionTabActivate      = wire.ActionTabActivate
	ActionTabAttach        = wire.ActionTabAttach
	ActionTabClose         = wire.ActionTabClose
	ActionTabDetach        = wire.ActionTabDetach
	ActionTabList          = wire.ActionTabList
	ActionWaitFor          = wire.ActionWaitFor
	ActivityAction         = wire.ActivityAction
	ActivityAttach         = wire.ActivityAttach
	ActivityAutoDetach     = wire.ActivityAutoDetach
	ActivityDetach         = wire.ActivityDetach
	ActivityEnumeration    = wire.ActivityEnumeration
	ActivityResume         = wire.ActivityResume
	ActivityStop           = wire.ActivityStop
	ActivityTabClosed      = wire.ActivityTabClosed
	ButtonLeft             = wire.ButtonLeft
	ButtonMiddle           = wire.ButtonMiddle
	ButtonRight            = wire.ButtonRight
	CmdActivate            = wire.CmdActivate
	CmdAttach              = wire.CmdAttach
	CmdBack                = wire.CmdBack
	CmdClick               = wire.CmdClick
	CmdCloseTab            = wire.CmdCloseTab
	CmdConsole             = wire.CmdConsole
	CmdDetach              = wire.CmdDetach
	CmdDialog              = wire.CmdDialog
	CmdEmulate             = wire.CmdEmulate
	CmdEval                = wire.CmdEval
	CmdFill                = wire.CmdFill
	CmdForward             = wire.CmdForward
	CmdHover               = wire.CmdHover
	CmdNetwork             = wire.CmdNetwork
	CmdOpen                = wire.CmdOpen
	CmdPing                = wire.CmdPing
	CmdPress               = wire.CmdPress
	CmdQuery               = wire.CmdQuery
	CmdReadHTML            = wire.CmdReadHTML
	CmdReadText            = wire.CmdReadText
	CmdReload              = wire.CmdReload
	CmdScreenshot          = wire.CmdScreenshot
	CmdScroll              = wire.CmdScroll
	CmdSelect              = wire.CmdSelect
	CmdStatus              = wire.CmdStatus
	CmdStop                = wire.CmdStop
	CmdTabs                = wire.CmdTabs
	CmdType                = wire.CmdType
	CmdURL                 = wire.CmdURL
	CmdWaitFor             = wire.CmdWaitFor
	CodeAdminRequired      = wire.CodeAdminRequired
	CodeAlreadyComplete    = wire.CodeAlreadyComplete
	CodeAlreadyRunning     = wire.CodeAlreadyRunning
	CodeAttachFailed       = wire.CodeAttachFailed
	CodeBadCode            = wire.CodeBadCode
	CodeBadCredential      = wire.CodeBadCredential
	CodeBadID              = wire.CodeBadID
	CodeBadRequest         = wire.CodeBadRequest
	CodeDialogAbsent       = wire.CodeDialogAbsent
	CodeExpired            = wire.CodeExpired
	CodeInternal           = wire.CodeInternal
	CodeJSError            = wire.CodeJSError
	CodeLengthRequired     = wire.CodeLengthRequired
	CodeNavigationFailed   = wire.CodeNavigationFailed
	CodeNoAction           = wire.CodeNoAction
	CodeNoBlob             = wire.CodeNoBlob
	CodeNoBrowser          = wire.CodeNoBrowser
	CodeNoBrowserLive      = wire.CodeNoBrowserLive
	CodeNoCredential       = wire.CodeNoCredential
	CodeNoDefaultBrowser   = wire.CodeNoDefaultBrowser
	CodeNoTargetTab        = wire.CodeNoTargetTab
	CodeNotOwner           = wire.CodeNotOwner
	CodeProtocolMismatch   = wire.CodeProtocolMismatch
	CodeQueueFull          = wire.CodeQueueFull
	CodeRateLimited        = wire.CodeRateLimited
	CodeRevoked            = wire.CodeRevoked
	CodeSelectorNotFound   = wire.CodeSelectorNotFound
	CodeSessionExpired     = wire.CodeSessionExpired
	CodeStopped            = wire.CodeStopped
	CodeStoreUnavailable   = wire.CodeStoreUnavailable
	CodeTabClosed          = wire.CodeTabClosed
	CodeTabDiscarded       = wire.CodeTabDiscarded
	CodeTabForbidden       = wire.CodeTabForbidden
	CodeTabHeld            = wire.CodeTabHeld
	CodeTabUnknown         = wire.CodeTabUnknown
	CodeTimeout            = wire.CodeTimeout
	CodeTooLarge           = wire.CodeTooLarge
	CodeVersionConflict    = wire.CodeVersionConflict
	DefaultActionTimeoutMs = wire.DefaultActionTimeoutMs
	KindAction             = wire.KindAction
	KindBlob               = wire.KindBlob
	KindBrowser            = wire.KindBrowser
	KindSession            = wire.KindSession
	KindTab                = wire.KindTab
	KindUnknown            = wire.KindUnknown
	LaneOffQueue           = wire.LaneOffQueue
	LaneSerial             = wire.LaneSerial
	LaneSplit              = wire.LaneSplit
	LevelDebug             = wire.LevelDebug
	LevelError             = wire.LevelError
	LevelInfo              = wire.LevelInfo
	LevelLog               = wire.LevelLog
	LevelWarn              = wire.LevelWarn
	MaxActionTimeoutMs     = wire.MaxActionTimeoutMs
	MaxActivityLimit       = wire.MaxActivityLimit
	MaxBlobBytes           = wire.MaxBlobBytes
	MaxQueueDepth          = wire.MaxQueueDepth
	MaxReadChars           = wire.MaxReadChars
	MaxTabsListed          = wire.MaxTabsListed
	MinActionTimeoutMs     = wire.MinActionTimeoutMs
	ModAlt                 = wire.ModAlt
	ModCtrl                = wire.ModCtrl
	ModMeta                = wire.ModMeta
	ModShift               = wire.ModShift
	NetFast3G              = wire.NetFast3G
	NetFast4G              = wire.NetFast4G
	NetNone                = wire.NetNone
	NetOffline             = wire.NetOffline
	NetSlow3G              = wire.NetSlow3G
	NetSlow4G              = wire.NetSlow4G
	OutcomeError           = wire.OutcomeError
	OutcomeOK              = wire.OutcomeOK
	OutcomeRunning         = wire.OutcomeRunning
	OwnerAgent             = wire.OwnerAgent
	OwnerUser              = wire.OwnerUser
	PrefixAction           = wire.PrefixAction
	PrefixBlob             = wire.PrefixBlob
	PrefixBrowser          = wire.PrefixBrowser
	PrefixSession          = wire.PrefixSession
	PrefixTab              = wire.PrefixTab
	SchemeAuto             = wire.SchemeAuto
	SchemeDark             = wire.SchemeDark
	SchemeLight            = wire.SchemeLight
	SelectByIndex          = wire.SelectByIndex
	SelectByLabel          = wire.SelectByLabel
	SelectByValue          = wire.SelectByValue
	StateCancelled         = wire.StateCancelled
	StateDone              = wire.StateDone
	StateExpired           = wire.StateExpired
	StateQueued            = wire.StateQueued
	StateRunning           = wire.StateRunning
	StateStopped           = wire.StateStopped
	TabClosed              = wire.TabClosed
	TabOpen                = wire.TabOpen
	// ProtocolVersion is the wire protocol this client speaks.
	ProtocolVersion = wire.Version
)

// Helpers a CLI needs before it sends anything: what the 30 commands are,
// and whether an id the user typed is well formed.
var (
	ActionTypes    = wire.ActionTypes
	Commands       = wire.Commands
	IDKindOf       = wire.IDKindOf
	ValidActionID  = wire.ValidActionID
	ValidBlobID    = wire.ValidBlobID
	ValidBrowserID = wire.ValidBrowserID
	ValidPairCode  = wire.ValidPairCode
	ValidSessionID = wire.ValidSessionID
	ValidTabHandle = wire.ValidTabHandle
)
