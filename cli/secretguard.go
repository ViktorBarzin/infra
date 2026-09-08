package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The paste and share verbs both mint internet-reachable URLs, and the content
// most worth pasting (logs, configs, kubectl output) is where a credential
// tends to turn up. Everything below is the gate in front of both.
//
// gitleaks is a net, not a proof: it matches known credential shapes, so a
// clean scan means "nothing matched a rule", not "contains no secrets".

var (
	// errScannerUnavailable means gitleaks isn't installed. Like the repo's
	// pre-commit hook, that warns rather than blocking the operation.
	errScannerUnavailable = errors.New("gitleaks not found")
	// errScanFailed means gitleaks ran and failed. That is not the same as
	// clean content, so it blocks.
	errScanFailed = errors.New("gitleaks scan failed")
)

// leakFinding is one gitleaks hit. Secret is captured because gitleaks reports
// it, but it is deliberately never printed back to the user.
type leakFinding struct {
	RuleID      string `json:"RuleID"`
	Description string `json:"Description"`
	StartLine   int    `json:"StartLine"`
	Secret      string `json:"Secret"`
}

// leakScanner scans content and returns whatever credential-shaped strings it
// matched. Injected so the guard is testable without the binary.
type leakScanner func(content []byte) ([]leakFinding, error)

func parseGitleaksReport(report string) ([]leakFinding, error) {
	s := strings.TrimSpace(report)
	if s == "" {
		return nil, nil
	}
	var out []leakFinding
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return nil, fmt.Errorf("cannot parse gitleaks report: %w", err)
	}
	return out, nil
}

// formatLeakBlock explains what matched and how to proceed anyway. It prints
// the rule and the line, never the matched value — echoing the secret into the
// terminal (and the scrollback, and the transcript) is the thing we are trying
// to avoid.
func formatLeakBlock(findings []leakFinding, what string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "refusing to %s: gitleaks matched %d credential-shaped string(s)\n", what, len(findings))
	for _, f := range findings {
		desc := f.Description
		if desc == "" {
			desc = f.RuleID
		}
		fmt.Fprintf(&b, "  line %d: %s (%s)\n", f.StartLine, desc, f.RuleID)
	}
	b.WriteString("this content would be reachable from the internet — remove the secret, or pass --force if it is a false positive")
	return b.String()
}

// guardContent blocks the operation when the scanner matches something, unless
// force is set. A missing scanner warns; a broken scanner blocks.
func guardContent(scan leakScanner, content []byte, force bool, what string) error {
	findings, err := scan(content)
	switch {
	case errors.Is(err, errScannerUnavailable):
		fmt.Fprintln(os.Stderr, "warning: gitleaks not found — skipping the secret scan")
		return nil
	case err != nil:
		return fmt.Errorf("secret scan failed (not treating that as clean): %w", err)
	}
	if len(findings) == 0 {
		return nil
	}
	if force {
		fmt.Fprintf(os.Stderr, "warning: --force set, uploading despite %d gitleaks finding(s)\n", len(findings))
		return nil
	}
	return errors.New(formatLeakBlock(findings, what))
}

// gitleaksBinary resolves the scanner the same way the repo's pre-commit hook
// does: an explicit GITLEAKS override, then the user-local install, then PATH.
func gitleaksBinary() string {
	if p := os.Getenv("GITLEAKS"); p != "" {
		return p
	}
	if home, err := os.UserHomeDir(); err == nil {
		local := filepath.Join(home, ".local", "bin", "gitleaks")
		if fi, err := os.Stat(local); err == nil && !fi.IsDir() {
			return local
		}
	}
	if p, err := exec.LookPath("gitleaks"); err == nil {
		return p
	}
	return ""
}

// gitleaksScan is the production leakScanner. gitleaks writes its report to a
// file rather than stdout, so findings are read back from a temp path; the
// count decides the outcome rather than the exit code alone.
func gitleaksScan(content []byte) ([]leakFinding, error) {
	bin := gitleaksBinary()
	if bin == "" {
		return nil, errScannerUnavailable
	}
	f, err := os.CreateTemp("", "homelab-gitleaks-*.json")
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errScanFailed, err)
	}
	report := f.Name()
	f.Close()
	defer os.Remove(report)

	cmd := exec.Command(bin, "stdin", "--no-banner", "-l", "error",
		"--report-format", "json", "--report-path", report)
	cmd.Stdin = strings.NewReader(string(content))
	runErr := cmd.Run()

	raw, readErr := os.ReadFile(report)
	if readErr != nil {
		// No report to read: the scan did not complete, so we cannot call the
		// content clean regardless of the exit code.
		return nil, fmt.Errorf("%w: %v", errScanFailed, runErr)
	}
	findings, parseErr := parseGitleaksReport(string(raw))
	if parseErr != nil {
		return nil, fmt.Errorf("%w: %v", errScanFailed, parseErr)
	}
	// gitleaks exits 1 when it finds something, which is expected and already
	// represented by the findings; any other failure with no findings is a
	// genuine error.
	if runErr != nil && len(findings) == 0 {
		return nil, fmt.Errorf("%w: %v", errScanFailed, runErr)
	}
	return findings, nil
}

// homelabUserAgent identifies the CLI on outbound requests. This is
// load-bearing for Sablier-parked services: the ingress middleware treats
// Go's default `Go-http-client` UA as a monitoring probe and answers it
// without waking the workload, so a request carrying that UA can never reach
// a parked app (see ingress_factory `ignoreUserAgent`).
func homelabUserAgent() string { return "homelab-cli/" + version }
