# Testing Patterns

**Analysis Date:** 2026-02-23

## Test Framework

**Language-Specific Runners:**

**Go:**
- Runner: `go test` (standard library `testing` package)
- Config: No config file (uses built-in conventions)
- Run Commands:
  ```bash
  go test ./...                    # Run all tests
  go test -v ./...                 # Verbose output
  go test -run TestContains ./...  # Run specific test
  go test -cover ./...             # Show coverage
  ```

**Bash:**
- Runner: Custom shell scripts in `scripts/`
- No formal test framework; uses `set -euo pipefail` for error handling
- Manual health checks via `bash scripts/cluster_healthcheck.sh`

**Terraform:**
- Framework: No automated testing detected (no terraform test files, no tftest.hcl)
- Validation: Manual `terraform validate`, `terraform plan`, visual inspection
- Integration: Terragrunt applies validate before execution

## Test File Organization

**Location:**
- Go tests: Co-located with source code: `<service>/files/internal/scraper/validate_test.go`
- Shell/Infrastructure: No test files (manual validation/health checks only)

**Naming:**
- Go: `*_test.go` suffix
- Script tests: `.sh` for check/validation scripts

**Structure:**
```
stacks/f1-stream/files/internal/scraper/
├── main.go
├── validate.go
└── validate_test.go           # Test file co-located
```

## Test Structure

**Go Table-Driven Tests:**

```golang
func TestContainsVideoMarkers(t *testing.T) {
	tests := []struct {
		name string
		body string
		want bool
	}{
		{
			name: "video tag",
			body: `<div><video src="stream.mp4"></video></div>`,
			want: true,
		},
		// ... more test cases
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := containsVideoMarkers(tt.body)
			if got != tt.want {
				t.Errorf("containsVideoMarkers(%q) = %v, want %v", truncate(tt.body, 60), got, tt.want)
			}
		})
	}
}
```

**Patterns:**
- Slice of anonymous structs with `name`, input fields, and `want` for expected result
- Loop with `t.Run(tt.name, ...)` for individual test case execution and reporting
- Descriptive test case names: `"video tag"`, `"HLS manifest reference"`, `"empty string"`
- Separate positive cases (upper) and negative cases (lower) with comments

**Bash Health Check Structure:**
```bash
check_nodes() {
    section 1 "Node Status"
    local nodes not_ready versions unique_versions detail=""

    nodes=$($KUBECTL get nodes --no-headers 2>&1) || { fail "Cannot reach cluster"; json_add "node_status" "FAIL" "Cannot reach cluster"; return 0; }
    # ... processing
    if [[ -n "$not_ready" ]]; then
        fail "NotReady nodes: $not_ready"
        json_add "node_status" "FAIL" "$detail"
    elif [[ "$unique_versions" -gt 1 ]]; then
        warn "Version mismatch..."
        json_add "node_status" "WARN" "$detail"
    else
        pass "All nodes Ready..."
        json_add "node_status" "PASS" "$detail"
    fi
}
```

**Patterns:**
- Each check function follows same structure: setup → validation → status reporting
- Status reported via `pass()`, `warn()`, `fail()` helper functions
- JSON output optional via `json_add()` for programmatic consumption
- Error handling inline with `||` fallback and graceful degradation

## Mocking

**Framework:**
- Go: No mocking framework detected (table-driven tests use real function calls)
- Bash: External commands mocked implicitly (KUBECONFIG override, kubectl invocation through `$KUBECTL` variable)

**Patterns (Go):**
- No mock objects or stubs
- Real function behavior tested directly
- Test data provided as input in struct fields

**Patterns (Bash):**
```bash
# Kubeconfig override allows testing against different clusters
KUBECTL="kubectl --kubeconfig $KUBECONFIG_PATH"
nodes=$($KUBECTL get nodes --no-headers 2>&1) || { fail "Cannot reach cluster"; return 0; }
```

**What NOT to Mock:**
- Core functionality being tested (test actual behavior)
- Standard library functions (test integration)

**What to Mock (Bash):**
- External kubectl calls via variable indirection: allows `KUBECONFIG` override
- Conditional output by flag: `--json`, `--quiet` flags change output, not behavior

## Fixtures and Factories

**Test Data (Go):**
- Inline strings in struct fields: HTML content, MIME types
- Examples from `validate_test.go`:
  ```golang
  {
      name: "HLS manifest reference",
      body: `var url = "https://cdn.example.com/live.m3u8";`,
      want: true,
  },
  ```

**Location:**
- Embedded directly in test file as struct field values
- No separate fixture files or factories

**Bash Fixtures:**
- Real cluster fixtures: tests run against actual Kubernetes cluster
- No data files; tests fetch live state via kubectl

## Coverage

**Requirements:** None enforced (no coverage thresholds, targets, or CI/CD gates detected)

**View Coverage (Go):**
```bash
go test -cover ./...              # Show coverage percentages
go test -coverprofile=coverage.out ./...
go tool cover -html=coverage.out  # Open HTML report
```

**Note:** Coverage tools not integrated into CI/CD pipeline; manual check only.

## Test Types

**Unit Tests (Go):**
- Scope: Single function validation
- Approach: Table-driven with parameterized inputs
- Example: `TestContainsVideoMarkers()` tests HTML content detection
- Example: `TestIsDirectVideoContentType()` tests MIME type classification
- In file: `stacks/f1-stream/files/internal/scraper/validate_test.go`

**Integration Tests:**
- Bash health checks (`scripts/cluster_healthcheck.sh`) serve as integration tests
- Tests 24 separate checks against live Kubernetes cluster:
  - Node status and readiness
  - Node resource utilization
  - Container metrics
  - Pod crash loops
  - Persistent volume health
  - DNS resolution
  - Networking
  - RBAC
  - Logs aggregation
- Can run with `--fix` flag for auto-remediation
- Can output JSON for CI integration

**E2E Tests:**
- Not formally implemented
- Manual validation via Terragrunt apply → cluster state verification

**Infrastructure Testing:**
- Terraform: `terraform validate` and `terraform plan` provide syntax/logic validation
- Application health: Manual checks via scripts and cluster_healthcheck.sh
- No automated test suite for infrastructure code

## Common Patterns

**Async Testing (Go):**
- Not applicable (synchronous function testing only)

**Error Testing (Go):**
```golang
{
    name: "empty string",
    body: "",
    want: false,
},
```
- Negative test cases included in same table
- Error/edge cases named descriptively: `"empty string"`, `"reddit link page"`
- Expected failure behavior verified: `want: false` for invalid inputs

**Error Reporting (Go):**
```golang
t.Errorf("containsVideoMarkers(%q) = %v, want %v", truncate(tt.body, 60), got, tt.want)
```
- Formatted message includes: function name, input (truncated), actual, expected
- Test name automatically prefixed by `t.Run(tt.name, ...)`

**Status Reporting (Bash):**
- Color-coded status: `${GREEN}[PASS]${NC}`, `${YELLOW}[WARN]${NC}`, `${RED}[FAIL]${NC}`
- Counter incremented per status
- Optional quiet mode (`--quiet`) suppresses PASS output
- Optional JSON output (`--json`) for CI integration
- Summary printed at end: `$PASS_COUNT/$WARN_COUNT/$FAIL_COUNT`

## Running Tests

**Go Tests:**
```bash
# From service directory containing *_test.go
go test -v ./...
```

**Bash Health Checks:**
```bash
# Comprehensive checks
bash scripts/cluster_healthcheck.sh

# Quiet mode (WARN/FAIL only)
bash scripts/cluster_healthcheck.sh --quiet

# Auto-fix mode
bash scripts/cluster_healthcheck.sh --fix

# JSON output
bash scripts/cluster_healthcheck.sh --json

# Custom kubeconfig
bash scripts/cluster_healthcheck.sh --kubeconfig /path/to/config
```

**Terraform Validation:**
```bash
# Format check
terraform fmt -recursive

# Syntax validation
terraform validate

# Plan without apply
terraform plan

# From stack directory
cd stacks/<service> && terragrunt plan
cd stacks/<service> && terragrunt apply --non-interactive
```

---

*Testing analysis: 2026-02-23*
