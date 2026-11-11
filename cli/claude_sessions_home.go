package main

// The rest of ~/.claude and ~/.codex in the session store, beside the
// transcripts (ADR-0039; extended for docs/plans/2026-11-11-disposable-devvm.md):
// prompt history, plans, tasks, teams, todos, file-history, remote/, Codex
// sessions and the settings files, so `homelab claude-sessions restore` can
// write a user's agent state back after the devvm is rebuilt.
//
// Two tables, by how a file changes:
//
//	claude.home_lines  .jsonl files (history.jsonl, Codex rollouts), sent line
//	                   by line like transcripts: an append costs one line.
//	claude.home_files  everything else, sent whole each time it changes.
//
// Never sent: credentials (.credentials.json, auth.json, key files, anything
// named token, secret or credential), caches, runtime state and downloadable
// binaries. Settings files go with their secret values replaced, and restore
// writes those beside the real name, never over it.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// homeRoots are the directories under each home that the store keeps.
var homeRoots = []string{".claude", ".codex"}

type homeClass int

const (
	homeSkip       homeClass = iota
	homeTranscript           // ~/.claude/projects files the transcript ingest handles
	homeWhole                // claude.home_files
	homeAppend               // claude.home_lines
)

// homeSkipDirs are never walked, relative to the home directory: caches,
// runtime state (live session registries, sockets, daemon keys), backups of
// ~/.claude.json (which holds MCP secrets) and downloadable binaries.
var homeSkipDirs = map[string]bool{
	".claude/cache":                true,
	".claude/paste-cache":          true,
	".claude/image-cache":          true,
	".claude/shell-snapshots":      true,
	".claude/session-env":          true,
	".claude/statsig":              true,
	".claude/debug":                true,
	".claude/downloads":            true,
	".claude/telemetry":            true,
	".claude/tmp":                  true,
	".claude/backups":              true,
	".claude/sessions":             true,
	".claude/daemon":               true,
	".claude/ide":                  true,
	".claude/local":                true,
	".claude/plugins/cache":        true,
	".claude/plugins/marketplaces": true,
	".claude/plugins/repos":        true,
	".claude/remote/ccd-cli":       true, // Claude Code binaries, 250 MB each
	".claude/remote/srv":           true, // remote-server binaries
	".codex/cache":                 true,
	".codex/.tmp":                  true,
	".codex/tmp":                   true,
	".codex/log":                   true,
	".codex/packages":              true, // Codex binaries
	".codex/plugins/cache":         true,
	".codex/shell_snapshots":       true,
	".codex/app-server-control":    true,
	".codex/app-server-daemon":     true,
	".codex/mcp-oauth-locks":       true,
	".codex/thread-writer-locks":   true,
}

// skipHomeDir reports whether a directory (relative to the home) is pruned.
func skipHomeDir(rel string) bool {
	if homeSkipDirs[rel] {
		return true
	}
	switch path.Base(rel) {
	case "node_modules", "__pycache__", ".git":
		return true
	}
	return false
}

// homeFileExcluded reports whether a file (relative to the home) must never
// be sent: a credential, a cache or a runtime file.
func homeFileExcluded(rel string) bool {
	base := path.Base(rel)
	lb := strings.ToLower(base)
	for _, s := range []string{"token", "credential", "secret", "oauth"} {
		if strings.Contains(lb, s) {
			return true
		}
	}
	for _, p := range []string{".credentials", "auth.json", "policy-limits.json", "remote-settings.json"} {
		if strings.HasPrefix(lb, p) {
			return true
		}
	}
	for _, s := range []string{".key", ".pem", ".p12", ".lock", ".sock", ".pid", "-shm", ".swp", ".tmp"} {
		if strings.HasSuffix(lb, s) {
			return true
		}
	}
	if strings.Contains(lb, ".tmp.") || (strings.HasPrefix(lb, "logs_") && strings.Contains(lb, ".sqlite")) {
		return true
	}
	switch base {
	case "models_cache.json", "plugin-catalog-cache.json", "mcp-needs-auth-cache.json", "stats-cache.json":
		return true
	}
	return rel == ".claude/remote/server" // remote-server binary
}

// classifyHomeFile decides where a regular file under a home goes. rel is
// relative to the home directory, abs is its full path.
func classifyHomeFile(home, abs, rel string) (homeClass, pathInfo) {
	if strings.HasPrefix(rel, ".claude/projects/") {
		if info, ok := classifyTranscriptPath(filepath.Join(home, ".claude", "projects"), abs); ok {
			return homeTranscript, info
		}
	}
	if homeFileExcluded(rel) {
		return homeSkip, pathInfo{}
	}
	if strings.HasSuffix(rel, ".jsonl") {
		return homeAppend, pathInfo{}
	}
	return homeWhole, pathInfo{}
}

// homeKind labels a row by its tool and top-level entry, e.g. claude:plans,
// codex:sessions, claude:history.jsonl.
func homeKind(rel string) string {
	p := strings.SplitN(rel, "/", 3)
	if len(p) < 2 {
		return strings.TrimPrefix(rel, ".")
	}
	return strings.TrimPrefix(p[0], ".") + ":" + p[1]
}

// walkHome visits every regular file under home/<root> for each homeRoots
// entry, pruning skipped directories and never following symlinks.
func walkHome(home string, visit func(abs, rel string, d fs.DirEntry) error) (bool, error) {
	found := false
	for _, r := range homeRoots {
		root := filepath.Join(home, r)
		if fi, err := os.Lstat(root); err != nil || !fi.IsDir() {
			continue
		}
		found = true
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				if d != nil && d.IsDir() && p != root {
					return fs.SkipDir
				}
				return nil
			}
			rel, rerr := filepath.Rel(home, p)
			if rerr != nil {
				return nil
			}
			rel = filepath.ToSlash(rel)
			if d.IsDir() {
				if p != root && skipHomeDir(rel) {
					return fs.SkipDir
				}
				return nil
			}
			if !d.Type().IsRegular() {
				return nil // symlinks, sockets, fifos
			}
			return visit(p, rel, d)
		})
		if err != nil {
			return found, err
		}
	}
	return found, nil
}

// ---- settings redaction --------------------------------------------------

func isSettingsFile(base string) bool {
	return (strings.HasPrefix(base, "settings") && strings.Contains(base, ".json")) ||
		strings.HasSuffix(base, ".toml") || base == "hooks.json" || strings.HasSuffix(base, "mcp.json")
}

const redactedValue = "<redacted>"

var (
	secretKeyRe = regexp.MustCompile(`(?i)(token|secret|passw|api[_-]?key|apikey|auth|credential|private[_-]?key|cookie|session[_-]?key|(^|_)pat($|_))`)
	// KEY=value inside a string, e.g. a permission rule "Bash(HIK_PASSWORD=x curl ...)".
	envAssignRe = regexp.MustCompile(`(?i)\b([A-Z0-9_]*(?:PASSWORD|PASSWD|TOKEN|SECRET|API_?KEY|_PAT|AUTH)[A-Z0-9_]*=)("[^"]*"|'[^']*'|[^\s"'\\)]+)`)
	bearerRe    = regexp.MustCompile(`(?i)\b(bearer|basic|token)(\s+)[A-Za-z0-9._~+/=-]{8,}`)
	urlCredRe   = regexp.MustCompile(`(://[^/\s:@"']+:)[^@\s/"']+@`)
	randomRunRe = regexp.MustCompile(`[A-Za-z0-9_+=-]{20,}`)
	tomlQuoted  = regexp.MustCompile(`("(?:[^"\\]|\\.)*"|'[^']*')`)
)

// secretTables are objects (JSON) or tables (TOML) whose every value is
// treated as a secret: environment variables and HTTP headers.
func isSecretTable(k string) bool {
	switch strings.ToLower(strings.Trim(k, `"' `)) {
	case "env", "headers", "http_headers", "env_http_headers":
		return true
	}
	return false
}

func redactInline(s string) string {
	s = envAssignRe.ReplaceAllString(s, "${1}"+redactedValue)
	s = bearerRe.ReplaceAllString(s, "${1}${2}"+redactedValue)
	s = urlCredRe.ReplaceAllString(s, "${1}"+redactedValue+"@")
	// A long run that mixes upper case, lower case and digits is a key, even
	// with no key name beside it: an MCP URL like /api/mcp/private_284F0n...
	return randomRunRe.ReplaceAllStringFunc(s, func(m string) string {
		if strings.ContainsAny(m, "0123456789") && strings.ToLower(m) != m && strings.ToUpper(m) != m {
			return redactedValue
		}
		return m
	})
}

// redactSettings returns the file with secret values replaced, and whether
// anything was replaced. JSON is parsed; anything else (TOML) is redacted
// line by line.
func redactSettings(base string, content []byte) ([]byte, bool) {
	var v any
	if strings.Contains(base, ".json") && json.Unmarshal(content, &v) == nil {
		changed := false
		v = redactJSON(v, false, &changed)
		if !changed {
			return content, false
		}
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", "  ")
		if enc.Encode(v) != nil {
			return nil, true
		}
		return buf.Bytes(), true
	}
	return redactTOML(content)
}

func redactJSON(v any, all bool, changed *bool) any {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			if s, ok := val.(string); ok && (all || secretKeyRe.MatchString(k)) {
				if s != "" {
					t[k] = redactedValue
					*changed = true
				}
				continue
			}
			t[k] = redactJSON(val, all || isSecretTable(k), changed)
		}
		return t
	case []any:
		for i := range t {
			t[i] = redactJSON(t[i], all, changed)
		}
		return t
	case string:
		if all && t != "" {
			*changed = true
			return redactedValue
		}
		if r := redactInline(t); r != t {
			*changed = true
			return r
		}
	}
	return v
}

func redactTOML(content []byte) ([]byte, bool) {
	lines := strings.Split(string(content), "\n")
	inSecret, changed := false, false
	for i, l := range lines {
		trim := strings.TrimSpace(l)
		if strings.HasPrefix(trim, "[") {
			name := strings.Trim(trim, "[] ")
			parts := strings.Split(name, ".")
			inSecret = isSecretTable(parts[len(parts)-1])
			continue
		}
		out := l
		if k, rest, ok := strings.Cut(l, "="); ok && !strings.HasPrefix(trim, "#") {
			key := strings.TrimSpace(k)
			if inSecret || secretKeyRe.MatchString(key) || isSecretTable(key) {
				out = k + "=" + tomlQuoted.ReplaceAllString(rest, `"`+redactedValue+`"`)
			}
		}
		out = redactInline(out)
		if out != l {
			lines[i] = out
			changed = true
		}
	}
	return []byte(strings.Join(lines, "\n")), changed
}

// ---- ingest ----------------------------------------------------------------

const (
	insertHomeFiles = "INSERT INTO claude.home_files (os_user, path, kind, mtime, mode, size, encoding, redacted, content) FORMAT JSONEachRow"
	insertHomeLines = "INSERT INTO claude.home_lines (os_user, path, generation, byte_offset, mtime, raw) FORMAT JSONEachRow"
	// A home file larger than this is recorded with no content: restore
	// reports it instead of writing a cut copy.
	maxHomeFileBytes = 32 << 20
)

type homeFileRow struct {
	OsUser   string `json:"os_user"`
	Path     string `json:"path"`
	Kind     string `json:"kind"`
	Mtime    string `json:"mtime"`
	Mode     uint32 `json:"mode"`
	Size     int64  `json:"size"`
	Encoding string `json:"encoding"` // text | base64 | omitted
	Redacted bool   `json:"redacted"`
	Content  string `json:"content"`
}

type homeLineRow struct {
	OsUser     string `json:"os_user"`
	Path       string `json:"path"`
	Generation string `json:"generation"`
	ByteOffset int64  `json:"byte_offset"`
	Mtime      string `json:"mtime"`
	Raw        string `json:"raw"`
}

// homeFileBatch packs whole-file rows from many files into one INSERT, so a
// first run over a thousand small files makes a handful of parts, not a
// thousand. The state of each file is committed only after its batch is
// accepted.
type homeFileBatch struct {
	db      dbConn
	budget  int
	state   *ingestState
	buf     bytes.Buffer
	pending map[string]*fileState
}

func (b *homeFileBatch) add(row []byte, abs string, fst *fileState) error {
	if b.buf.Len() > 0 && b.buf.Len()+len(row)+1 > b.budget {
		if err := b.flush(); err != nil {
			return err
		}
	}
	b.buf.Write(row)
	b.buf.WriteByte('\n')
	if b.pending == nil {
		b.pending = map[string]*fileState{}
	}
	b.pending[abs] = fst
	return nil
}

func (b *homeFileBatch) flush() error {
	if b.buf.Len() == 0 {
		return nil
	}
	if err := b.db.insert(insertHomeFiles, "", b.buf.Bytes()); err != nil {
		return errDB{err}
	}
	for p, s := range b.pending {
		b.state.Files[p] = s
	}
	b.buf.Reset()
	b.pending = nil
	return nil
}

// unchangedSinceLastRun checks the state from an lstat, so an unchanged file
// is never opened.
func unchangedSinceLastRun(prev *fileState, d fs.DirEntry) bool {
	if prev == nil || prev.Size < 0 {
		return false
	}
	fi, err := d.Info()
	if err != nil {
		return false
	}
	sys, ok := fi.Sys().(*syscall.Stat_t)
	return ok && sys.Ino == prev.Inode && fi.Size() == prev.Size && fi.ModTime().UnixNano() == prev.MtimeNs
}

// openOwned opens a file for reading the way the transcript ingest does:
// O_NOFOLLOW, a regular file, owned by the home directory's owner.
func openOwned(p string, owner uint32) (*os.File, os.FileInfo, *syscall.Stat_t, bool) {
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, nil, nil, false
	}
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		f.Close()
		return nil, nil, nil, false
	}
	sys := fi.Sys().(*syscall.Stat_t)
	if sys.Uid != owner {
		f.Close()
		return nil, nil, nil, false
	}
	return f, fi, sys, true
}

func ingestHomeWhole(cfg ingestConfig, state *ingestState, st *ingestStats, batch *homeFileBatch, user string, owner uint32, abs, rel string) error {
	f, fi, sys, ok := openOwned(abs, owner)
	if !ok {
		st.FileErrors++
		return nil
	}
	defer f.Close()
	size, mtime := fi.Size(), fi.ModTime().UnixNano()
	if skip, _, _ := planFile(state.Files[abs], sys.Ino, size, mtime); skip {
		return nil
	}
	st.FilesChanged++
	row := homeFileRow{OsUser: user, Path: rel, Kind: homeKind(rel), Mtime: fi.ModTime().UTC().Format(time.RFC3339Nano),
		Mode: uint32(fi.Mode().Perm()), Size: size}
	content, err := io.ReadAll(io.LimitReader(f, maxHomeFileBytes+1))
	if err != nil {
		st.FileErrors++
		return nil
	}
	switch {
	case len(content) > maxHomeFileBytes:
		row.Encoding = "omitted"
	default:
		if isSettingsFile(path.Base(rel)) {
			content, row.Redacted = redactSettings(path.Base(rel), content)
		}
		if utf8.Valid(content) {
			row.Encoding, row.Content = "text", string(content)
		} else {
			row.Encoding, row.Content = "base64", base64.StdEncoding.EncodeToString(content)
		}
	}
	b, err := json.Marshal(row)
	if err != nil {
		return err
	}
	st.HomeFiles++
	st.Bytes += int64(len(content))
	return batch.add(b, abs, &fileState{Inode: sys.Ino, Size: size, MtimeNs: mtime, Offset: size})
}

// ingestHomeAppend sends the lines appended to a .jsonl file since the last
// run. When the file is read from the start (new, truncated or replaced) it
// gets a new generation, so restore never mixes lines of two versions.
func ingestHomeAppend(cfg ingestConfig, state *ingestState, st *ingestStats, user string, owner uint32, abs, rel string) error {
	f, fi, sys, ok := openOwned(abs, owner)
	if !ok {
		st.FileErrors++
		return nil
	}
	defer f.Close()
	size, mtime := fi.Size(), fi.ModTime().UnixNano()
	prev := state.Files[abs]
	skip, offset, hint := planFile(prev, sys.Ino, size, mtime)
	if skip {
		return nil
	}
	st.FilesChanged++
	gen := ""
	if offset > 0 && prev != nil {
		gen = prev.Gen
	}
	if gen == "" {
		offset, hint = 0, ""
		gen = homeGeneration(sys.Ino, mtime)
	}
	mt := fi.ModTime().UTC().Format(time.RFC3339Nano)
	return appendLines(cfg, state, st, abs, f, sys.Ino, size, mtime, offset, hint, gen, insertHomeLines,
		func(off int64, line []byte, _ string) ([]byte, error) {
			st.HomeLines++
			return json.Marshal(homeLineRow{OsUser: user, Path: rel, Generation: gen, ByteOffset: off, Mtime: mt, Raw: string(line)})
		})
}

func homeGeneration(inode uint64, mtimeNs int64) string {
	return strconv.FormatUint(inode, 10) + "-" + strconv.FormatInt(mtimeNs, 10)
}
