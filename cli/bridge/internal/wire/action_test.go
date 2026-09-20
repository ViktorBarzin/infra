package wire

import "testing"

func TestActionTypeValid(t *testing.T) {
	cases := []struct {
		in   ActionType
		want bool
	}{
		{ActionNavOpen, true},
		{ActionTabList, true},
		{ActionCtlPing, true},
		{ActionDiagEmulate, true},
		{"nav.teleport", false},
		{"", false},
		{"NAV.OPEN", false},
		{"status", false},
		{"stop", false},
	}
	for _, c := range cases {
		t.Run(string(c.in), func(t *testing.T) {
			if got := c.in.Valid(); got != c.want {
				t.Fatalf("%q.Valid() = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestActionTypesCoverTheProtocol(t *testing.T) {
	all := ActionTypes()
	if len(all) != 28 {
		t.Fatalf("got %d action types, want 28 (30 commands minus status and stop, which are routes)", len(all))
	}
	seen := map[ActionType]bool{}
	for _, a := range all {
		if seen[a] {
			t.Fatalf("duplicate action type %q", a)
		}
		seen[a] = true
		if !a.Valid() {
			t.Fatalf("ActionTypes() returned %q, which Valid() rejects", a)
		}
	}
	for _, want := range []ActionType{
		ActionNavOpen, ActionNavBack, ActionNavForward, ActionNavReload, ActionNavURL,
		ActionReadText, ActionReadHTML, ActionReadQuery, ActionReadEval, ActionReadScreenshot,
		ActionInputClick, ActionInputType, ActionInputFill, ActionInputSelect, ActionInputPress,
		ActionInputHover, ActionInputScroll, ActionInputDialog,
		ActionWaitFor,
		ActionDiagConsole, ActionDiagNetwork, ActionDiagEmulate,
		ActionTabList, ActionTabAttach, ActionTabDetach, ActionTabActivate, ActionTabClose,
		ActionCtlPing,
	} {
		if !seen[want] {
			t.Fatalf("ActionTypes() is missing %q", want)
		}
	}
}

func TestActionTypeLane(t *testing.T) {
	cases := []struct {
		in   ActionType
		want Lane
	}{
		{ActionTabList, LaneOffQueue},
		{ActionTabActivate, LaneOffQueue},
		{ActionTabClose, LaneOffQueue},
		{ActionTabDetach, LaneOffQueue},
		{ActionWaitFor, LaneOffQueue},
		{ActionCtlPing, LaneOffQueue},
		{ActionNavOpen, LaneSplit},
		{ActionNavReload, LaneSplit},
		{ActionTabAttach, LaneSerial},
		{ActionNavBack, LaneSerial},
		{ActionNavForward, LaneSerial},
		{ActionNavURL, LaneSerial},
		{ActionReadEval, LaneSerial},
		{ActionInputClick, LaneSerial},
		{ActionDiagNetwork, LaneSerial},
	}
	for _, c := range cases {
		t.Run(string(c.in), func(t *testing.T) {
			if got := c.in.Lane(); got != c.want {
				t.Fatalf("%q.Lane() = %q, want %q", c.in, got, c.want)
			}
		})
	}
	if got := ActionType("nav.teleport").Lane(); got != LaneSerial {
		t.Fatalf("unknown action type must default to the serial lane, got %q", got)
	}
}

func TestActionStateTerminal(t *testing.T) {
	cases := []struct {
		in   ActionState
		want bool
	}{
		{StateQueued, false},
		{StateRunning, false},
		{StateDone, true},
		{StateExpired, true},
		{StateCancelled, true},
		{StateStopped, true},
		{"", false},
	}
	for _, c := range cases {
		t.Run(string(c.in), func(t *testing.T) {
			if got := c.in.Terminal(); got != c.want {
				t.Fatalf("%q.Terminal() = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestCommandsCoverThirtyCLICommands(t *testing.T) {
	all := Commands()
	if len(all) != 30 {
		t.Fatalf("got %d commands, want the 30 in protocol section 14", len(all))
	}
	withAction := 0
	for _, c := range all {
		if !c.Valid() {
			t.Fatalf("Commands() returned %q, which Valid() rejects", c)
		}
		typ, ok := c.ActionType()
		if ok {
			withAction++
			if !typ.Valid() {
				t.Fatalf("command %q maps to invalid action type %q", c, typ)
			}
		}
	}
	if withAction != 28 {
		t.Fatalf("%d commands map to an action type, want 28", withAction)
	}
	for _, routeOnly := range []Command{CmdStatus, CmdStop} {
		if _, ok := routeOnly.ActionType(); ok {
			t.Fatalf("%q is a server route, not an action", routeOnly)
		}
	}
	if typ, ok := CmdCloseTab.ActionType(); !ok || typ != ActionTabClose {
		t.Fatalf("close-tab maps to %q, %v", typ, ok)
	}
}
