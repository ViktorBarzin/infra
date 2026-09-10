package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

// The `vault kv` verbs talk to HashiCorp Vault / OpenBao — the homelab INFRA
// secrets store (the `secret/…` KV-v2 mount at vault.viktorbarzin.me) — NOT
// Vaultwarden. They are a thin wrapper over the `vault` CLI that adds a
// self-defaulted VAULT_ADDR (so non-login agent shells work) and TTY-aware
// handling of a single secret value (clipboard on a terminal, stdout when
// piped). A field-less `kv get` returns key NAMES, never values — see
// runKVGet.
//
// CREDENTIALS DIFFER FROM THE VAULTWARDEN VERBS. Those use the per-user *scoped*
// token (bound only to secret/workstation/claude-users/<user>). A general kv read
// of e.g. secret/viktor must use the caller's OWN Vault token (the OIDC
// ~/.vault-token or an explicit $VAULT_TOKEN) — the scoped token has `deny`
// everywhere else and would 403. So the kv handlers call ensureVaultAddr() to
// guarantee VAULT_ADDR but deliberately do NOT call ensureVaultToken() (which
// injects the scoped token). Access is then whatever the caller's policy grants.
func vaultKVCommands() []Command {
	return []Command{
		{Path: []string{"vault", "kv", "get"}, Tier: TierRead,
			Summary: "[hashicorp-vault] list a secret's key names; --field K (or <path>/<key>) reads one value", Run: vaultKVGet},
		{Path: []string{"vault", "kv", "list"}, Tier: TierRead,
			Summary: "[hashicorp-vault] list infra KV sub-paths: vault kv list <path>", Run: vaultKVList},
		{Path: []string{"vault", "kv", "put"}, Tier: TierWrite,
			Summary: "[hashicorp-vault] write one KV key (value via stdin): vault kv put <path> <key>", Run: vaultKVPut},
		{Path: []string{"vault", "kv"}, Tier: TierRead,
			Summary: "[hashicorp-vault] infra secrets (run `homelab vault kv` for help)",
			Run:     func([]string) error { fmt.Print(vaultKVHelp()); return nil }},
	}
}

func vaultKVHelp() string {
	return `homelab vault kv — HashiCorp Vault / OpenBao (homelab INFRA secrets, the secret/… KV store)

  homelab vault kv get <path>     the secret's key names + version (NO values)
  homelab vault kv get <path> --field <key>   one value (TTY → clipboard; piped → stdout)
  homelab vault kv get <path>/<key>           the same one value, as a path
  homelab vault kv get <path> --reveal-all    every value — deliberate, and it
                                  lands in scrollback and agent transcripts
  homelab vault kv list <path>    list sub-paths under <path> (no values)
  homelab vault kv put <path> <key>   write one key; value read from stdin
                                  (piped, or no-echo prompt); merges — never clobbers siblings

Uses YOUR Vault token (vault login -method=oidc → ~/.vault-token); access is
whatever your policy grants. This is NOT Vaultwarden — for your personal logins
use 'homelab vault get' (see 'homelab vault').
`
}

// --- arg builders (pure; values never travel via argv) --------------------

func vaultKVGetFieldArgs(path, field string) []string {
	return []string{"kv", "get", "-field=" + field, path}
}
func vaultKVGetJSONArgs(path string) []string { return []string{"kv", "get", "-format=json", path} }
func vaultKVListArgs(path string) []string    { return []string{"kv", "list", "-format=json", path} }

// vaultKVPutArgs builds the write argv. merge=true → `kv patch -method=rw`
// (read-modify-write: merges, needs only read+update — not the `patch` capability
// — and preserves sibling keys); merge=false → `kv put` (creates the path on
// first write). The value is ALWAYS read from stdin via the `<key>=-` form, so it
// never appears in argv (visible via ps / /proc/<pid>/cmdline to same-UID procs).
func vaultKVPutArgs(merge bool, path, key string) []string {
	return append(kvWriteVerb(merge), path, key+"=-")
}

// --- pure parsers ----------------------------------------------------------

// extractKVData returns the inner secret object from a `vault kv get -format=json`
// envelope (`{"data":{"data":{…},"metadata":{…}}}`), dropping the metadata/request
// wrapper so only the secret's own key→value data is emitted.
func extractKVData(jsonOut string) (string, error) {
	var env struct {
		Data struct {
			Data json.RawMessage `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		return "", fmt.Errorf("parse vault kv json: %w", err)
	}
	if len(env.Data.Data) == 0 {
		return "", fmt.Errorf("no secret data at that path")
	}
	return string(env.Data.Data), nil
}

// kvSecretSummary is a secret described WITHOUT its values: the key names it
// holds, plus the metadata worth knowing before reading one. This is what a
// field-less `kv get` returns, because "which keys are in here?" is the common
// question and answering it with every value is how ~20 production credentials
// reached an agent transcript (and Loki) on 2026-09-10.
type kvSecretSummary struct {
	Keys        []string
	Version     int
	CreatedTime string
}

// parseKVSummary reads the `vault kv get -format=json` envelope and keeps only
// the key names and metadata. KV-v2 has no names-only read, so the values do
// pass through this process's memory — they just never reach a writer.
func parseKVSummary(jsonOut string) (kvSecretSummary, error) {
	var env struct {
		Data struct {
			Data     map[string]json.RawMessage `json:"data"`
			Metadata struct {
				CreatedTime string `json:"created_time"`
				Version     int    `json:"version"`
			} `json:"metadata"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		return kvSecretSummary{}, fmt.Errorf("parse vault kv json: %w", err)
	}
	if len(env.Data.Data) == 0 {
		return kvSecretSummary{}, fmt.Errorf("no secret data at that path")
	}
	keys := make([]string, 0, len(env.Data.Data))
	for k := range env.Data.Data {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return kvSecretSummary{
		Keys:        keys,
		Version:     env.Data.Metadata.Version,
		CreatedTime: env.Data.Metadata.CreatedTime,
	}, nil
}

// formatKVKeys renders the key names, one per line, for stdout — so `| grep`
// and `| wc -l` work on a values-free listing.
func formatKVKeys(s kvSecretSummary) string {
	return strings.Join(s.Keys, "\n") + "\n"
}

// formatKVHint renders the header and the how-to-read-one-value guidance that
// goes to stderr. The listing has to teach the next caller the safe command:
// the reason the 2026-09-10 leak happened is that the helpful-looking
// invocation was the dangerous one.
func formatKVHint(path string, s kvSecretSummary) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s — %d keys", path, len(s.Keys))
	if s.Version > 0 {
		fmt.Fprintf(&b, ", version %d", s.Version)
	}
	if s.CreatedTime != "" {
		fmt.Fprintf(&b, ", created %s", s.CreatedTime)
	}
	fmt.Fprintf(&b, "\nno values printed. read one with:\n")
	fmt.Fprintf(&b, "  homelab vault kv get %s --field <key>\n", path)
	fmt.Fprintf(&b, "  homelab vault kv get %s/<key>\n", path)
	fmt.Fprintf(&b, "--reveal-all prints every value, into your scrollback and any agent transcript.\n")
	return b.String()
}

// splitKVFieldPath reads `secret/platform/cloudflare_api_key` as the secret
// `secret/platform` plus the key `cloudflare_api_key`. ok is false below three
// segments, since KV-v2 spends the first on the mount and the second on the
// secret, leaving nothing for a key.
func splitKVFieldPath(path string) (parent, field string, ok bool) {
	parts := strings.Split(path, "/")
	if len(parts) < 3 {
		return "", "", false
	}
	field = parts[len(parts)-1]
	if field == "" {
		return "", "", false
	}
	return strings.Join(parts[:len(parts)-1], "/"), field, true
}

// parseKVList parses the JSON array `vault kv list -format=json` prints.
func parseKVList(jsonOut string) ([]string, error) {
	var keys []string
	if err := json.Unmarshal([]byte(jsonOut), &keys); err != nil {
		return nil, fmt.Errorf("parse vault kv list json: %w", err)
	}
	return keys, nil
}

// --- testable cores (injected cmdRunner) -----------------------------------

func kvGetField(run cmdRunner, path, field string) (string, error) {
	return run("vault", vaultKVGetFieldArgs(path, field), nil)
}

func kvGetJSON(run cmdRunner, path string) (string, error) {
	out, err := run("vault", vaultKVGetJSONArgs(path), nil)
	if err != nil {
		return "", err
	}
	return extractKVData(out)
}

func kvGetSummary(run cmdRunner, path string) (kvSecretSummary, error) {
	out, err := run("vault", vaultKVGetJSONArgs(path), nil)
	if err != nil {
		return kvSecretSummary{}, err
	}
	return parseKVSummary(out)
}

func kvList(run cmdRunner, path string) ([]string, error) {
	out, err := run("vault", vaultKVListArgs(path), nil)
	if err != nil {
		return nil, err
	}
	return parseKVList(out)
}

// kvPathExists reports whether the KV path already holds data, to pick create
// (`kv put`) vs merge (`kv patch -method=rw`) — so a write never clobbers
// sibling keys on an existing path.
func kvPathExists(run cmdRunner, path string) bool {
	_, err := run("vault", vaultKVGetJSONArgs(path), nil)
	return err == nil
}

// kvPut writes one key, creating the path when absent and merging when present.
// The value travels on stdin only (never argv).
func kvPut(run cmdRunner, runStdin cmdRunnerStdin, path, key, value string) error {
	merge := kvPathExists(run, path)
	_, err := runStdin("vault", vaultKVPutArgs(merge, path, key), nil, value)
	return err
}

// --- handlers --------------------------------------------------------------

// kvGetOpts is a parsed `vault kv get` argv.
type kvGetOpts struct {
	Path      string
	Field     string
	RevealAll bool
}

// parseKVGetArgs parses the argv strictly: an argument that looks like a flag
// and is not one we know is an ERROR, never a silently-ignored token. The
// 2026-09-10 leak was exactly that fall-through — `-field=cloudflare_api_key`
// (the single-dash form the real `vault` CLI takes) matched no case, left Field
// empty, and the field-less branch dumped all 53 values of secret/platform.
// Both dash spellings are accepted for the same reason: muscle memory from the
// upstream CLI must land on the field, not on a dump.
func parseKVGetArgs(args []string) (kvGetOpts, error) {
	var o kvGetOpts
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			if o.Path == "" {
				o.Path = a
				continue
			}
			return o, fmt.Errorf("unexpected argument %q; to read one key write: homelab vault kv get %s --field %s", a, o.Path, a)
		}
		name, value, hasValue := flagToken(a)
		switch name {
		case "field":
			if !hasValue {
				if i+1 >= len(args) || strings.HasPrefix(args[i+1], "-") {
					return o, fmt.Errorf("--field needs a key name (see the key names with: homelab vault kv get <path>)")
				}
				i++
				value = args[i]
			}
			if value == "" {
				return o, fmt.Errorf("--field needs a key name (see the key names with: homelab vault kv get <path>)")
			}
			o.Field = value
		case "reveal-all":
			o.RevealAll = true
		default:
			return o, fmt.Errorf("unknown flag %q; `vault kv get` takes --field <key> or --reveal-all (a field-less read lists key names only)", a)
		}
	}
	if o.Path == "" {
		return o, fmt.Errorf("usage: homelab vault kv get <path> [--field <key>]   (no --field → key names only)")
	}
	if o.Field != "" && o.RevealAll {
		return o, fmt.Errorf("--field and --reveal-all ask for different things; pass one, not both")
	}
	return o, nil
}

// runKVGet is the get flow, with the runner, the secret sink and the writers
// injected so the no-values guarantee is testable. emit is emitSecret in
// production (clipboard on a terminal, stdout when piped).
//
// Order matters: a real nested secret path (secret/workstation/claude-users/x)
// must keep reading as a path, so the path is tried first and only a failed
// read falls back to reading the last segment as a key name.
//
// stdoutTTY is passed in and deliberately never branched on. Whether values are
// printed must not depend on where stdout points — that dependency IS the
// 2026-09-10 bug, in the direction nobody would choose (it refused on a
// terminal and dumped into a pipe, so it guarded humans and not agents).
// Taking it as a parameter lets the tests assert both states behave
// identically, which reading stdoutIsTTY() in here could not.
func runKVGet(run cmdRunner, o kvGetOpts, emit func(string), stdout, stderr io.Writer, stdoutTTY bool) error {
	if o.Field != "" {
		val, err := kvGetField(run, o.Path, o.Field)
		if err != nil {
			return err
		}
		emit(val)
		return nil
	}
	if o.RevealAll {
		sum, err := kvGetSummary(run, o.Path)
		if err != nil {
			return err
		}
		out, err := kvGetJSON(run, o.Path)
		if err != nil {
			return err
		}
		fmt.Fprintf(stderr, "WARNING: printing all %d values of %s. This lands in your scrollback, and in the transcript of any agent that ran it.\n",
			len(sum.Keys), o.Path)
		fmt.Fprintln(stdout, out)
		return nil
	}
	sum, pathErr := kvGetSummary(run, o.Path)
	if pathErr == nil {
		fmt.Fprint(stdout, formatKVKeys(sum))
		fmt.Fprint(stderr, formatKVHint(o.Path, sum))
		return nil
	}
	// Not a secret. If it could be <secret>/<key>, read that one value.
	parent, field, ok := splitKVFieldPath(o.Path)
	if !ok {
		return fmt.Errorf("reading %s: %w", o.Path, pathErr)
	}
	psum, parentErr := kvGetSummary(run, parent)
	if parentErr != nil {
		return fmt.Errorf("reading %s: %w", o.Path, pathErr)
	}
	if !contains(psum.Keys, field) {
		return fmt.Errorf("%s has no key %q (it has %d keys; list them with: homelab vault kv get %s)",
			parent, field, len(psum.Keys), parent)
	}
	val, err := kvGetField(run, parent, field)
	if err != nil {
		return err
	}
	emit(val)
	return nil
}

func vaultKVGet(args []string) error {
	hardenProcess()
	ensureVaultAddr() // own token, NOT the scoped one (see file header)
	o, err := parseKVGetArgs(args)
	if err != nil {
		return err
	}
	return runKVGet(realRunner, o, emitSecret, os.Stdout, os.Stderr, stdoutIsTTY())
}

func vaultKVList(args []string) error {
	ensureVaultAddr()
	var path string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			path = a
			break
		}
	}
	if path == "" {
		return fmt.Errorf("usage: homelab vault kv list <path>")
	}
	keys, err := kvList(realRunner, path)
	if err != nil {
		return err
	}
	for _, k := range keys {
		fmt.Println(k)
	}
	return nil
}

func vaultKVPut(args []string) error {
	hardenProcess()
	ensureVaultAddr()
	var path, key string
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		switch {
		case path == "":
			path = a
		case key == "":
			key = a
		}
	}
	if path == "" || key == "" {
		return fmt.Errorf("usage: homelab vault kv put <path> <key>   (value read from stdin)")
	}
	value, err := readSecretValue("Value for " + key + ": ")
	if err != nil {
		return err
	}
	if value == "" {
		return fmt.Errorf("empty value; aborting (nothing written)")
	}
	if err := kvPut(realRunner, realRunnerStdin, path, key, value); err != nil {
		return fmt.Errorf("writing %q to %s failed (does your token have write access? path correct?): %w", key, path, err)
	}
	fmt.Fprintln(os.Stderr, "wrote "+key+" to "+path)
	return nil
}

// readSecretValue obtains a secret value WITHOUT putting it in argv: piped stdin
// is read verbatim (trailing newline trimmed, internal newlines preserved so
// multi-line values like PEM keys survive); an interactive TTY is prompted
// without echo.
func readSecretValue(prompt string) (string, error) {
	fi, err := os.Stdin.Stat()
	if err == nil && fi.Mode()&os.ModeCharDevice == 0 {
		b, rerr := io.ReadAll(os.Stdin)
		if rerr != nil {
			return "", rerr
		}
		return strings.TrimRight(string(b), "\r\n"), nil
	}
	return promptNoEcho(prompt)
}
