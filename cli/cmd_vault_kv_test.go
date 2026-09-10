package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// The fake secret used throughout. FAKE_* values are never real credentials —
// their only job is to be recognisable in output that must not contain them.
const (
	fakeSecretJSON = `{
  "request_id": "abc",
  "data": {
    "data": {
      "cloudflare_api_key": "FAKE_CF_VALUE_1",
      "k8s_users": "FAKE_K8S_VALUE_2",
      "technitium_password": "FAKE_TECH_VALUE_3"
    },
    "metadata": {
      "created_time": "2026-06-12T09:33:01.123456789Z",
      "version": 12
    }
  }
}`
)

// exactRunner keys canned output on the full "name argv..." string. The shared
// fakeRunner in cmd_vault_test.go prefix-matches, which cannot distinguish
// `get secret/platform` from `get secret/platform/cloudflare_api_key`.
type exactRunner struct {
	calls [][]string
	out   map[string]string
	err   map[string]error
}

func (r *exactRunner) run(name string, argv, envv []string) (string, error) {
	r.calls = append(r.calls, append([]string{name}, argv...))
	key := name + " " + strings.Join(argv, " ")
	if e, ok := r.err[key]; ok {
		return "", e
	}
	if v, ok := r.out[key]; ok {
		return v, nil
	}
	return "", errors.New("no value at that path")
}

func platformRunner() *exactRunner {
	return &exactRunner{out: map[string]string{
		"vault kv get -format=json secret/platform":                   fakeSecretJSON,
		"vault kv get -field=cloudflare_api_key secret/platform":      "FAKE_CF_VALUE_1",
		"vault kv get -format=json secret/workstation/claude-users/x": fakeSecretJSON,
	}}
}

// --- flag parsing ----------------------------------------------------------

func TestParseKVGetArgsFieldForms(t *testing.T) {
	// The single-dash forms are what the real `vault` CLI takes, so an operator
	// or agent reaching for muscle memory must get the field, not a dump.
	for _, args := range [][]string{
		{"secret/platform", "--field", "cloudflare_api_key"},
		{"secret/platform", "--field=cloudflare_api_key"},
		{"secret/platform", "-field", "cloudflare_api_key"},
		{"secret/platform", "-field=cloudflare_api_key"},
		{"-field=cloudflare_api_key", "secret/platform"},
	} {
		got, err := parseKVGetArgs(args)
		if err != nil {
			t.Fatalf("parseKVGetArgs(%v): %v", args, err)
		}
		if got.Path != "secret/platform" || got.Field != "cloudflare_api_key" {
			t.Fatalf("parseKVGetArgs(%v) = %+v", args, got)
		}
		if got.RevealAll {
			t.Fatalf("parseKVGetArgs(%v) set RevealAll", args)
		}
	}
}

// The incident: `-field=K` was not recognised, was not rejected either, and the
// field-less branch printed all 53 values of secret/platform.
func TestParseKVGetArgsRejectsUnknownFlag(t *testing.T) {
	for _, args := range [][]string{
		{"--feild=cloudflare_api_key", "secret/platform"},
		{"-json", "secret/platform"},
		{"secret/platform", "--format=json"},
		{"secret/platform", "-f", "cloudflare_api_key"},
	} {
		_, err := parseKVGetArgs(args)
		if err == nil {
			t.Fatalf("parseKVGetArgs(%v) accepted an unknown flag", args)
		}
		if !strings.Contains(err.Error(), "--field") {
			t.Errorf("parseKVGetArgs(%v) error should point at --field, got %q", args, err)
		}
	}
}

func TestParseKVGetArgsErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"no path", []string{}, "usage"},
		{"only a flag", []string{"--field=k"}, "usage"},
		{"field with no value", []string{"secret/platform", "--field"}, "needs a key name"},
		{"empty field value", []string{"secret/platform", "--field="}, "needs a key name"},
		{"second positional", []string{"secret/platform", "cloudflare_api_key"}, "--field cloudflare_api_key"},
		{"field plus reveal-all", []string{"secret/platform", "--field=k", "--reveal-all"}, "not both"},
	} {
		_, err := parseKVGetArgs(tc.args)
		if err == nil {
			t.Fatalf("%s: parseKVGetArgs(%v) returned no error", tc.name, tc.args)
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: error %q does not mention %q", tc.name, err, tc.want)
		}
	}
}

func TestParseKVGetArgsRevealAll(t *testing.T) {
	for _, args := range [][]string{
		{"secret/platform", "--reveal-all"},
		{"secret/platform", "-reveal-all"},
	} {
		got, err := parseKVGetArgs(args)
		if err != nil {
			t.Fatalf("parseKVGetArgs(%v): %v", args, err)
		}
		if !got.RevealAll || got.Path != "secret/platform" {
			t.Fatalf("parseKVGetArgs(%v) = %+v", args, got)
		}
	}
}

// --- path/field splitting --------------------------------------------------

func TestSplitKVFieldPath(t *testing.T) {
	for _, tc := range []struct {
		in          string
		parent, fld string
		ok          bool
	}{
		{"secret/platform/cloudflare_api_key", "secret/platform", "cloudflare_api_key", true},
		{"secret/workstation/claude-users/emo/x", "secret/workstation/claude-users/emo", "x", true},
		// Two segments is mount + secret: there is no field to split off.
		{"secret/viktor", "", "", false},
		{"secret", "", "", false},
		{"secret/platform/", "", "", false},
	} {
		parent, fld, ok := splitKVFieldPath(tc.in)
		if ok != tc.ok || parent != tc.parent || fld != tc.fld {
			t.Errorf("splitKVFieldPath(%q) = (%q,%q,%v), want (%q,%q,%v)",
				tc.in, parent, fld, ok, tc.parent, tc.fld, tc.ok)
		}
	}
}

// --- summary parsing -------------------------------------------------------

func TestParseKVSummaryNamesOnly(t *testing.T) {
	s, err := parseKVSummary(fakeSecretJSON)
	if err != nil {
		t.Fatalf("parseKVSummary: %v", err)
	}
	want := []string{"cloudflare_api_key", "k8s_users", "technitium_password"}
	if strings.Join(s.Keys, ",") != strings.Join(want, ",") {
		t.Fatalf("keys = %v, want %v (sorted)", s.Keys, want)
	}
	if s.Version != 12 {
		t.Errorf("version = %d, want 12", s.Version)
	}
	if !strings.HasPrefix(s.CreatedTime, "2026-06-12T09:33:01") {
		t.Errorf("created = %q", s.CreatedTime)
	}
	if _, err := parseKVSummary("not json"); err == nil {
		t.Error("malformed envelope must error")
	}
	if _, err := parseKVSummary(`{"data":{"data":{}}}`); err == nil {
		t.Error("empty secret must error")
	}
}

func TestFormatKVSummaryCarriesNoValues(t *testing.T) {
	s, err := parseKVSummary(fakeSecretJSON)
	if err != nil {
		t.Fatalf("parseKVSummary: %v", err)
	}
	names, hint := formatKVKeys(s), formatKVHint("secret/platform", s)
	both := names + hint
	for _, v := range []string{"FAKE_CF_VALUE_1", "FAKE_K8S_VALUE_2", "FAKE_TECH_VALUE_3"} {
		if strings.Contains(both, v) {
			t.Fatalf("value %q leaked into the listing:\n%s", v, both)
		}
	}
	for _, k := range s.Keys {
		if !strings.Contains(names, k) {
			t.Errorf("key %q missing from the names output", k)
		}
	}
	// The listing has to teach the next caller how to read one value, since the
	// helpful-looking command is the one that leaked.
	for _, want := range []string{"3 keys", "version 12", "--field <key>", "secret/platform/<key>"} {
		if !strings.Contains(hint, want) {
			t.Errorf("hint missing %q:\n%s", want, hint)
		}
	}
}

// --- end-to-end get flow ---------------------------------------------------

// The bug that leaked: no --field, stdout a pipe (every agent invocation), and
// the whole secret went to stdout. Now it must be names only, on both a pipe
// and a terminal — the old guard had it backwards, refusing only on a TTY.
func TestKVGetNoFieldPrintsNamesOnly(t *testing.T) {
	for _, tty := range []bool{true, false} {
		r := platformRunner()
		var out, errb bytes.Buffer
		emitted := ""
		err := runKVGet(r.run, kvGetOpts{Path: "secret/platform"},
			func(v string) { emitted = v }, &out, &errb, tty)
		if err != nil {
			t.Fatalf("stdoutTTY=%v: runKVGet: %v", tty, err)
		}
		combined := out.String() + errb.String() + emitted
		for _, v := range []string{"FAKE_CF_VALUE_1", "FAKE_K8S_VALUE_2", "FAKE_TECH_VALUE_3"} {
			if strings.Contains(combined, v) {
				t.Fatalf("stdoutTTY=%v: value %q printed:\n%s", tty, v, combined)
			}
		}
		if !strings.Contains(out.String(), "cloudflare_api_key") {
			t.Errorf("stdoutTTY=%v: key names must go to stdout, got %q", tty, out.String())
		}
		if !strings.Contains(errb.String(), "--field") {
			t.Errorf("stdoutTTY=%v: guidance must go to stderr, got %q", tty, errb.String())
		}
	}
}

func TestKVGetFieldEmitsOneValue(t *testing.T) {
	r := platformRunner()
	var out, errb bytes.Buffer
	emitted := ""
	err := runKVGet(r.run, kvGetOpts{Path: "secret/platform", Field: "cloudflare_api_key"},
		func(v string) { emitted = v }, &out, &errb, false)
	if err != nil {
		t.Fatalf("runKVGet: %v", err)
	}
	if emitted != "FAKE_CF_VALUE_1" {
		t.Fatalf("emitted = %q", emitted)
	}
	if out.Len() != 0 {
		t.Errorf("field read must go through emitSecret, not stdout: %q", out.String())
	}
}

// "unless you pass in the full path" — secret/platform/cloudflare_api_key reads
// that one value, and a real nested secret path still reads as a path.
func TestKVGetFullValuePathFallsBackToField(t *testing.T) {
	r := platformRunner()
	var out, errb bytes.Buffer
	emitted := ""
	err := runKVGet(r.run, kvGetOpts{Path: "secret/platform/cloudflare_api_key"},
		func(v string) { emitted = v }, &out, &errb, false)
	if err != nil {
		t.Fatalf("runKVGet: %v", err)
	}
	if emitted != "FAKE_CF_VALUE_1" {
		t.Fatalf("emitted = %q (calls=%v)", emitted, r.calls)
	}
}

func TestKVGetNestedSecretPathStaysAPath(t *testing.T) {
	r := platformRunner()
	var out, errb bytes.Buffer
	err := runKVGet(r.run, kvGetOpts{Path: "secret/workstation/claude-users/x"},
		func(string) { t.Fatal("must not emit a value") }, &out, &errb, false)
	if err != nil {
		t.Fatalf("runKVGet: %v", err)
	}
	if !strings.Contains(out.String(), "cloudflare_api_key") {
		t.Fatalf("nested path must list its keys, got %q", out.String())
	}
}

func TestKVGetMissingPathErrorsWithoutFallbackNoise(t *testing.T) {
	r := platformRunner()
	var out, errb bytes.Buffer
	err := runKVGet(r.run, kvGetOpts{Path: "secret/typo/nope"},
		func(string) { t.Fatal("must not emit a value") }, &out, &errb, false)
	if err == nil {
		t.Fatal("missing path must error")
	}
	if !strings.Contains(err.Error(), "secret/typo/nope") {
		t.Errorf("error should name the path asked for, got %q", err)
	}
}

func TestKVGetMissingFieldOnRealPathErrors(t *testing.T) {
	r := platformRunner()
	var out, errb bytes.Buffer
	err := runKVGet(r.run, kvGetOpts{Path: "secret/platform/not_a_key"},
		func(string) { t.Fatal("must not emit a value") }, &out, &errb, false)
	if err == nil {
		t.Fatal("a path whose last segment is not a key must error")
	}
	if !strings.Contains(err.Error(), "not_a_key") || !strings.Contains(err.Error(), "secret/platform") {
		t.Errorf("error should name both the key and the secret, got %q", err)
	}
	if strings.Contains(err.Error(), "FAKE_") {
		t.Errorf("error leaked a value: %q", err)
	}
}

// The escape hatch: explicit, and loud on stderr even when piped.
func TestKVGetRevealAllPrintsValuesWithWarning(t *testing.T) {
	for _, tty := range []bool{true, false} {
		r := platformRunner()
		var out, errb bytes.Buffer
		err := runKVGet(r.run, kvGetOpts{Path: "secret/platform", RevealAll: true},
			func(string) { t.Fatal("reveal-all writes stdout directly") }, &out, &errb, tty)
		if err != nil {
			t.Fatalf("stdoutTTY=%v: runKVGet: %v", tty, err)
		}
		if !strings.Contains(out.String(), "FAKE_CF_VALUE_1") {
			t.Errorf("stdoutTTY=%v: --reveal-all must print values, got %q", tty, out.String())
		}
		w := errb.String()
		if !strings.Contains(w, "WARNING") || !strings.Contains(w, "secret/platform") {
			t.Errorf("stdoutTTY=%v: warning missing: %q", tty, w)
		}
		if strings.Contains(w, "FAKE_") {
			t.Errorf("stdoutTTY=%v: warning leaked a value: %q", tty, w)
		}
	}
}

func TestVaultKVHelpDocumentsNamesOnlyDefault(t *testing.T) {
	h := vaultKVHelp()
	for _, want := range []string{"--field", "--reveal-all", "key names", "<path>/<key>"} {
		if !strings.Contains(h, want) {
			t.Errorf("vault kv help missing %q:\n%s", want, h)
		}
	}
	if strings.Contains(h, "all fields as JSON (piped only)") {
		t.Error("help still promises the old field-less JSON dump")
	}
}
