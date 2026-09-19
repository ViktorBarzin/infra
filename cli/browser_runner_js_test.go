package main

import (
	"os/exec"
	"strings"
	"testing"
)

// TestBrowserRunnerJS runs the node-side unit tests for the pre-connect target
// sweep, so `go test ./cli/...` is the single entry point for both languages.
// The sweep guards against an orphaned CDP target crashing patchright before
// the user's script runs (infra issue #98).
func TestBrowserRunnerJS(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not installed; skipping browser_runner.js tests")
	}
	out, err := exec.Command(node, "browser_runner_test.js").CombinedOutput()
	if err != nil {
		t.Fatalf("browser_runner_test.js failed: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "all browser_runner tests passed") {
		t.Fatalf("browser_runner_test.js did not report success:\n%s", out)
	}
}
