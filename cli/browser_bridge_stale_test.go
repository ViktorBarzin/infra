package main

import (
	"strings"
	"testing"

	bb "github.com/ViktorBarzin/browser-bridge/client"
)

// Chrome never auto-updates a "Load unpacked" extension, which is how this
// is installed, so a stale extension against a fixed server is the normal
// state after any extension change. On 2026-09-21 that silently cost two
// debugging cycles. status is the first thing anyone runs, so it is where
// this has to be said.
func TestStatusSaysWhenTheExtensionIsStale(t *testing.T) {
	status := func(ext, server string) *bb.StatusResponse {
		cur := ""
		return &bb.StatusResponse{
			Server: bb.ServerInfo{Version: server, Protocol: 1, Store: "ok"},
			User:   "vbarzin",
			Browser: &bb.BrowserStatus{
				BrowserID: "b_x", Label: "MacIntel Chrome", Live: true,
				QueueDepth: 0, CurrentAction: &cur, ExtensionVersion: ext,
			},
		}
	}

	t.Run("warns, names both versions, and says what to do", func(t *testing.T) {
		out := renderStatusResponse(status("0.1.0", "0.1.1"))
		if !strings.Contains(out, "0.1.0") || !strings.Contains(out, "0.1.1") {
			t.Errorf("both versions must appear, got:\n%s", out)
		}
		low := strings.ToLower(out)
		if !strings.Contains(low, "out of date") && !strings.Contains(low, "stale") {
			t.Errorf("no staleness wording, got:\n%s", out)
		}
		if !strings.Contains(low, "reload") {
			t.Errorf("must say how to fix it, got:\n%s", out)
		}
	})

	t.Run("stays quiet when the versions match", func(t *testing.T) {
		out := strings.ToLower(renderStatusResponse(status("0.1.1", "0.1.1")))
		if strings.Contains(out, "out of date") || strings.Contains(out, "stale") {
			t.Errorf("must not warn when current, got:\n%s", out)
		}
	})

	t.Run("stays quiet against a dev server", func(t *testing.T) {
		out := strings.ToLower(renderStatusResponse(status("0.1.0", "0.0.0-dev")))
		if strings.Contains(out, "out of date") {
			t.Errorf("must not warn against an unversioned server, got:\n%s", out)
		}
	})
}
