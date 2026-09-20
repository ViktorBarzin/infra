package wire

// Command is one of the 30 CLI commands in v1. Twenty-eight of them enqueue
// an action; status and stop are server routes and never reach the browser.
// The verb can drive its dispatch table from Commands.
type Command string

// Navigation, 5.
const (
	CmdOpen    Command = "open"
	CmdBack    Command = "back"
	CmdForward Command = "forward"
	CmdReload  Command = "reload"
	CmdURL     Command = "url"
)

// Reading, 5.
const (
	CmdReadText   Command = "read-text"
	CmdReadHTML   Command = "read-html"
	CmdQuery      Command = "query"
	CmdEval       Command = "eval"
	CmdScreenshot Command = "screenshot"
)

// Input, 8.
const (
	CmdClick  Command = "click"
	CmdType   Command = "type"
	CmdFill   Command = "fill"
	CmdSelect Command = "select"
	CmdPress  Command = "press"
	CmdHover  Command = "hover"
	CmdScroll Command = "scroll"
	CmdDialog Command = "dialog"
)

// Waiting, 1.
const CmdWaitFor Command = "wait-for"

// Diagnostics, 3.
const (
	CmdConsole Command = "console"
	CmdNetwork Command = "network"
	CmdEmulate Command = "emulate"
)

// Tab access, 5.
const (
	CmdTabs     Command = "tabs"
	CmdAttach   Command = "attach"
	CmdDetach   Command = "detach"
	CmdActivate Command = "activate"
	CmdCloseTab Command = "close-tab"
)

// Plumbing, 3.
const (
	CmdStatus Command = "status"
	CmdPing   Command = "ping"
	CmdStop   Command = "stop"
)

// commandActions maps a command to the action it enqueues. A command absent
// from this map is a server route.
var commandActions = map[Command]ActionType{
	CmdOpen:       ActionNavOpen,
	CmdBack:       ActionNavBack,
	CmdForward:    ActionNavForward,
	CmdReload:     ActionNavReload,
	CmdURL:        ActionNavURL,
	CmdReadText:   ActionReadText,
	CmdReadHTML:   ActionReadHTML,
	CmdQuery:      ActionReadQuery,
	CmdEval:       ActionReadEval,
	CmdScreenshot: ActionReadScreenshot,
	CmdClick:      ActionInputClick,
	CmdType:       ActionInputType,
	CmdFill:       ActionInputFill,
	CmdSelect:     ActionInputSelect,
	CmdPress:      ActionInputPress,
	CmdHover:      ActionInputHover,
	CmdScroll:     ActionInputScroll,
	CmdDialog:     ActionInputDialog,
	CmdWaitFor:    ActionWaitFor,
	CmdConsole:    ActionDiagConsole,
	CmdNetwork:    ActionDiagNetwork,
	CmdEmulate:    ActionDiagEmulate,
	CmdTabs:       ActionTabList,
	CmdAttach:     ActionTabAttach,
	CmdDetach:     ActionTabDetach,
	CmdActivate:   ActionTabActivate,
	CmdCloseTab:   ActionTabClose,
	CmdPing:       ActionCtlPing,
}

var commandOrder = []Command{
	CmdOpen, CmdBack, CmdForward, CmdReload, CmdURL,
	CmdReadText, CmdReadHTML, CmdQuery, CmdEval, CmdScreenshot,
	CmdClick, CmdType, CmdFill, CmdSelect, CmdPress, CmdHover, CmdScroll, CmdDialog,
	CmdWaitFor,
	CmdConsole, CmdNetwork, CmdEmulate,
	CmdTabs, CmdAttach, CmdDetach, CmdActivate, CmdCloseTab,
	CmdStatus, CmdPing, CmdStop,
}

// Commands lists all 30, in protocol order.
func Commands() []Command {
	out := make([]Command, len(commandOrder))
	copy(out, commandOrder)
	return out
}

// Valid reports whether c is one of the 30.
func (c Command) Valid() bool {
	if _, ok := commandActions[c]; ok {
		return true
	}
	return c == CmdStatus || c == CmdStop
}

// ActionType gives the action a command enqueues. ok is false for status and
// stop, which are answered by the server without touching the browser.
func (c Command) ActionType() (ActionType, bool) {
	t, ok := commandActions[c]
	return t, ok
}

func (c Command) String() string { return string(c) }
