package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

// The `vault kv` verbs talk to HashiCorp Vault / OpenBao — the homelab INFRA
// secrets store (the `secret/…` KV-v2 mount at vault.viktorbarzin.me) — NOT
// Vaultwarden. They are a thin, TTY-aware wrapper over the `vault` CLI that adds
// the same conveniences as the Vaultwarden verbs: a self-defaulted VAULT_ADDR
// (so non-login agent shells work) and clipboard/refuse-on-TTY secret handling.
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
			Summary: "[hashicorp-vault] read an infra KV secret: vault kv get <path> [--field K]", Run: vaultKVGet},
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

  homelab vault kv get <path> [--field K]   read a secret
                                  --field K  → one value (TTY → clipboard; piped → stdout)
                                  no --field → all fields as JSON (piped only)
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

func vaultKVGet(args []string) error {
	hardenProcess()
	ensureVaultAddr() // own token, NOT the scoped one (see file header)
	var path, field string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--field" && i+1 < len(args):
			field = args[i+1]
			i++
		case strings.HasPrefix(a, "--field="):
			field = strings.TrimPrefix(a, "--field=")
		case !strings.HasPrefix(a, "-") && path == "":
			path = a
		}
	}
	if path == "" {
		return fmt.Errorf("usage: homelab vault kv get <path> [--field <key>]")
	}
	if field != "" {
		val, err := kvGetField(realRunner, path, field)
		if err != nil {
			return err
		}
		emitSecret(val) // TTY-aware: clipboard on a terminal, stdout when piped
		return nil
	}
	// No --field → the whole secret. All values, so refuse a bare TTY (like
	// `vault get --json`): pick a --field for the clipboard path, or pipe it.
	if !jsonToStdoutOK(stdoutIsTTY()) {
		return fmt.Errorf("refusing to print all KV fields as JSON to a terminal; use --field <key>, or pipe it (e.g. | jq)")
	}
	out, err := kvGetJSON(realRunner, path)
	if err != nil {
		return err
	}
	fmt.Println(out)
	return nil
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
