package main

// ~/.claude.json in the session store (docs/plans/2026-11-11-disposable-devvm.md).
//
// The file is Claude Code's own state, about 1 MB on a busy account and
// rewritten on every start: caches, tips, per-project cost and session stats,
// the signed-in account, and among them the few keys a rebuild must keep. The
// store gets a reduced copy holding only those:
//
//   - the flags that keep the first `claude` from showing the onboarding again
//     (hasCompletedOnboarding, lastOnboardingVersion, the hasSeen* notices,
//     the *MigrationComplete markers, installMethod, autoUpdates);
//   - user-scope MCP servers (mcpServers), redacted like a settings file;
//   - per project: folder trust, approved CLAUDE.md includes, allowed tools,
//     project MCP servers and their approvals.
//
// The reduced copy is always stored as redacted, so restore writes it through
// the settings path: under the real name when there is none, merged into one
// provisioning wrote first on a rebuild (mergeKept). The MCP secrets the
// redaction takes out come back from Vault (claude_sessions_mcp.go).

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
)

const claudeJSONRel = ".claude.json"

// claudeJSONTopKeys are the top-level keys the reduced copy keeps, beside
// the hasSeen*, hasCompleted*, hasAcknowledged* and *MigrationComplete flags.
var claudeJSONTopKeys = map[string]bool{
	"hasCompletedOnboarding":        true,
	"lastOnboardingVersion":         true,
	"lastReleaseNotesSeen":          true,
	"installMethod":                 true,
	"autoUpdates":                   true,
	"autoUpdatesProtectedForNative": true,
	"migrationVersion":              true,
	"theme":                         true,
	"editorMode":                    true,
	"bypassPermissionsModeAccepted": true,
	"mcpServers":                    true,
}

func keepClaudeJSONTop(k string) bool {
	if claudeJSONTopKeys[k] {
		return true
	}
	for _, p := range []string{"hasSeen", "hasCompleted", "hasAcknowledged"} {
		if strings.HasPrefix(k, p) {
			return true
		}
	}
	return strings.HasSuffix(k, "MigrationComplete")
}

// claudeJSONProjectKeys are the keys kept for each project.
var claudeJSONProjectKeys = map[string]bool{
	"hasTrustDialogAccepted":                  true,
	"hasClaudeMdExternalIncludesApproved":     true,
	"hasClaudeMdExternalIncludesWarningShown": true,
	"allowedTools":                            true,
	"mcpServers":                              true,
	"enabledMcpjsonServers":                   true,
	"disabledMcpjsonServers":                  true,
	"mcpContextUris":                          true,
}

// emptyValue is a value that says nothing a new box would not assume:
// false, null, "", [] or {}.
func emptyValue(v any) bool {
	switch t := v.(type) {
	case nil:
		return true
	case bool:
		return !t
	case string:
		return t == ""
	case []any:
		return len(t) == 0
	case map[string]any:
		return len(t) == 0
	}
	return false
}

// reduceClaudeJSON returns the reduced copy of a ~/.claude.json, keys sorted
// so the same state always gives the same bytes. ok is false when the file
// does not parse (Claude caught mid-write): nothing is sent then.
func reduceClaudeJSON(content []byte) ([]byte, bool) {
	var all map[string]any
	if err := json.Unmarshal(content, &all); err != nil || all == nil {
		return nil, false
	}
	out := map[string]any{}
	for k, v := range all {
		if keepClaudeJSONTop(k) {
			out[k] = v
		}
	}
	if projects, ok := all["projects"].(map[string]any); ok {
		kept := map[string]any{}
		for dir, pv := range projects {
			p, ok := pv.(map[string]any)
			if !ok {
				continue
			}
			keep := map[string]any{}
			for k, v := range p {
				if claudeJSONProjectKeys[k] && !emptyValue(v) {
					keep[k] = v
				}
			}
			if len(keep) > 0 {
				kept[dir] = keep
			}
		}
		if len(kept) > 0 {
			out["projects"] = kept
		}
	}
	b, err := encodeSettingsJSON(out)
	return b, err == nil
}

func contentSum(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
