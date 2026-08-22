package main

import (
	"strings"
	"testing"
)

func TestParseGitleaksReport(t *testing.T) {
	report := `[{"RuleID":"github-pat","Description":"GitHub Personal Access Token","StartLine":2,"Secret":"ghp_xxx"},
	            {"RuleID":"aws-access-token","Description":"AWS","StartLine":9,"Secret":"AKIA"}]`
	got, err := parseGitleaksReport(report)
	if err != nil {
		t.Fatalf("parseGitleaksReport: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 findings, got %d", len(got))
	}
	if got[0].RuleID != "github-pat" || got[0].StartLine != 2 {
		t.Errorf("unexpected first finding: %+v", got[0])
	}
}

func TestParseGitleaksReportEmpty(t *testing.T) {
	for _, in := range []string{"[]", "", "  \n"} {
		got, err := parseGitleaksReport(in)
		if err != nil {
			t.Fatalf("parseGitleaksReport(%q): %v", in, err)
		}
		if len(got) != 0 {
			t.Errorf("parseGitleaksReport(%q) = %+v, want none", in, got)
		}
	}
}

func TestFormatLeakBlockNamesRuleAndLineButNotTheSecret(t *testing.T) {
	f := []leakFinding{{RuleID: "github-pat", Description: "GitHub PAT", StartLine: 2, Secret: "ghp_supersecretvalue"}}
	out := formatLeakBlock(f, "paste")
	if !strings.Contains(out, "github-pat") || !strings.Contains(out, "line 2") {
		t.Errorf("want rule id and line number, got:\n%s", out)
	}
	if strings.Contains(out, "ghp_supersecretvalue") {
		t.Errorf("the finding message must not reprint the secret itself:\n%s", out)
	}
	if !strings.Contains(out, "--force") {
		t.Errorf("want the override documented in the block message, got:\n%s", out)
	}
}

func TestGuardContentBlocksOnFindings(t *testing.T) {
	scan := func(content []byte) ([]leakFinding, error) {
		return []leakFinding{{RuleID: "github-pat", StartLine: 1}}, nil
	}
	err := guardContent(scan, []byte("ghp_x"), false, "paste")
	if err == nil {
		t.Fatal("want a blocking error when a secret is found")
	}
	if !strings.Contains(err.Error(), "github-pat") {
		t.Errorf("error should name the rule, got: %v", err)
	}
}

func TestGuardContentAllowsCleanContent(t *testing.T) {
	scan := func(content []byte) ([]leakFinding, error) { return nil, nil }
	if err := guardContent(scan, []byte("hello"), false, "paste"); err != nil {
		t.Errorf("clean content must pass, got: %v", err)
	}
}

func TestGuardContentForceOverrides(t *testing.T) {
	scan := func(content []byte) ([]leakFinding, error) {
		return []leakFinding{{RuleID: "github-pat", StartLine: 1}}, nil
	}
	if err := guardContent(scan, []byte("ghp_x"), true, "paste"); err != nil {
		t.Errorf("--force must override the block, got: %v", err)
	}
}

func TestGuardContentDegradesWhenScannerUnavailable(t *testing.T) {
	// Matching the pre-commit hook: a missing gitleaks warns rather than
	// blocking the operation outright.
	scan := func(content []byte) ([]leakFinding, error) { return nil, errScannerUnavailable }
	if err := guardContent(scan, []byte("anything"), false, "paste"); err != nil {
		t.Errorf("missing scanner should degrade to a warning, got: %v", err)
	}
}

func TestGuardContentPropagatesRealScannerErrors(t *testing.T) {
	// A scanner that ran but failed is different from one that is absent: we
	// must not silently treat "the scan broke" as "the content is clean".
	scan := func(content []byte) ([]leakFinding, error) { return nil, errScanFailed }
	if err := guardContent(scan, []byte("anything"), false, "paste"); err == nil {
		t.Error("a failed scan must not be treated as clean")
	}
}
