package main

// The ingest half of `homelab claude-sessions`: ships every Claude Code
// transcript on the devvm into the claude-sessions ClickHouse
// (stacks/claude-sessions, ADR-0039).
//
// It runs as root from a oneshot systemd timer and is built to be cheap when
// nothing changed: it stats every transcript file, skips the ones whose
// (inode, size, mtime) match the state file, and reads only the bytes appended
// since the stored offset. It never parses a transcript beyond its timestamp;
// ClickHouse computes every other column from the raw line, so a change in
// Claude Code's record format is fixed in SQL rather than by re-ingesting.

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// fileState is what the ingester remembers about one file between runs.
type fileState struct {
	Inode   uint64 `json:"inode"`
	Size    int64  `json:"size"`
	MtimeNs int64  `json:"mtime_ns"`
	Offset  int64  `json:"offset"`
	TsHint  string `json:"ts_hint,omitempty"`
	// Gen names the version of an append-only home file (claude.home_lines);
	// it changes whenever the file is read again from the start.
	Gen string `json:"gen,omitempty"`
}

type ingestState struct {
	Files map[string]*fileState `json:"files"`
}

func loadState(path string) (*ingestState, error) {
	s := &ingestState{Files: map[string]*fileState{}}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, s); err != nil {
		return nil, fmt.Errorf("state file %s is corrupt: %w", path, err)
	}
	if s.Files == nil {
		s.Files = map[string]*fileState{}
	}
	return s, nil
}

// saveState writes atomically, so a crash mid-write cannot leave a state file
// that makes the next run re-send or skip data.
func saveState(path string, s *ingestState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// planFile decides what to do with a file given what the last run saw.
// skip: nothing changed. Otherwise read from offset, seeding the timestamp
// hint. A smaller size than the stored offset, or a different inode, means
// the file was truncated or replaced, so it is read again from the start.
func planFile(prev *fileState, inode uint64, size, mtimeNs int64) (skip bool, offset int64, hint string) {
	if prev == nil || prev.Inode != inode || size < prev.Offset {
		return false, 0, ""
	}
	if prev.Size == size && prev.MtimeNs == mtimeNs {
		return true, 0, ""
	}
	return false, prev.Offset, prev.TsHint
}

// readNewLines reads complete lines from r, which starts at byte offset start
// of the file. For each non-empty line it calls emit with the line's offset,
// the line without its newline, and the latest timestamp seen so far in the
// file. A final line with no newline yet is left for the next run. It returns
// the offset just past the last complete line and the latest timestamp.
func readNewLines(r io.Reader, start int64, hint string, emit func(offset int64, line []byte, hint string) error) (int64, string, error) {
	br := bufio.NewReaderSize(r, 1<<20)
	off := start
	for {
		line, err := br.ReadBytes('\n')
		if errors.Is(err, io.EOF) {
			return off, hint, nil // partial or empty tail: wait for the writer
		}
		if err != nil {
			return off, hint, err
		}
		lineOff := off
		off += int64(len(line))
		body := bytes.TrimRight(line, "\r\n")
		if len(bytes.TrimSpace(body)) == 0 {
			continue
		}
		var ts struct {
			Timestamp string `json:"timestamp"`
		}
		if json.Unmarshal(body, &ts) == nil && ts.Timestamp != "" {
			hint = ts.Timestamp
		}
		if err := emit(lineOff, body, hint); err != nil {
			return lineOff, hint, err
		}
	}
}

type fileKind int

const (
	kindTranscript fileKind = iota + 1
	kindSubagentMeta
	kindToolResult
)

func (k fileKind) String() string {
	switch k {
	case kindSubagentMeta:
		return "subagent-meta"
	case kindToolResult:
		return "tool-result"
	}
	return "transcript"
}

type pathInfo struct {
	Project string
	Session string
	Agent   string
	Kind    fileKind
}

// classifyTranscriptPath maps a path under a user's ~/.claude/projects to the
// session it belongs to. Layouts (Claude Code 2.1.3xx):
//
//	<slug>/<session>.jsonl                              main transcript
//	<slug>/<session>/subagents/<agent>.jsonl            subagent transcript
//	<slug>/<session>/subagents/<agent>.meta.json        subagent metadata
//	<slug>/<session>/tool-results/<id>.txt              a large tool output
//	<slug>/<session>/subagents/workflows/<run>/<agent>.jsonl      workflow subagent
//	<slug>/<session>/subagents/workflows/<run>/<agent>.meta.json  its metadata
func classifyTranscriptPath(projectsRoot, path string) (pathInfo, bool) {
	rel, err := filepath.Rel(projectsRoot, path)
	if err != nil {
		return pathInfo{}, false
	}
	p := strings.Split(filepath.ToSlash(rel), "/")
	switch {
	case len(p) == 2 && strings.HasSuffix(p[1], ".jsonl"):
		return pathInfo{Project: p[0], Session: strings.TrimSuffix(p[1], ".jsonl"), Kind: kindTranscript}, true
	case len(p) == 4 && p[2] == "subagents" && strings.HasSuffix(p[3], ".meta.json"):
		return pathInfo{Project: p[0], Session: p[1], Agent: strings.TrimSuffix(p[3], ".meta.json"), Kind: kindSubagentMeta}, true
	case len(p) == 4 && p[2] == "subagents" && strings.HasSuffix(p[3], ".jsonl"):
		return pathInfo{Project: p[0], Session: p[1], Agent: strings.TrimSuffix(p[3], ".jsonl"), Kind: kindTranscript}, true
	case len(p) == 4 && p[2] == "tool-results":
		return pathInfo{Project: p[0], Session: p[1], Kind: kindToolResult}, true
	case len(p) == 6 && p[2] == "subagents" && p[3] == "workflows" && strings.HasSuffix(p[5], ".meta.json"):
		return pathInfo{Project: p[0], Session: p[1], Agent: strings.TrimSuffix(p[5], ".meta.json"), Kind: kindSubagentMeta}, true
	case len(p) == 6 && p[2] == "subagents" && p[3] == "workflows" && strings.HasSuffix(p[5], ".jsonl"):
		return pathInfo{Project: p[0], Session: p[1], Agent: strings.TrimSuffix(p[5], ".jsonl"), Kind: kindTranscript}, true
	}
	return pathInfo{}, false
}

// batcher groups rows of ONE file into JSONEachRow bodies of at most budget
// bytes. Each batch's dedup token is "<file>:<first offset>", so a retried
// batch (a Traefik retry, or a re-run after a crash before the state was
// saved) is dropped by ClickHouse instead of counted twice.
type batcher struct {
	budget   int
	send     func(token string, body []byte) error
	onCommit func(file string, end int64, hint string)

	file     string
	first    int64
	buf      bytes.Buffer
	end      int64
	hint     string
	rows     int
	sentRows int
}

func newBatcher(budget int, send func(token string, body []byte) error) *batcher {
	return &batcher{budget: budget, send: send}
}

func (b *batcher) add(file string, offset int64, row []byte) error {
	if b.rows > 0 && (file != b.file || b.buf.Len()+len(row)+1 > b.budget) {
		if err := b.flush(); err != nil {
			return err
		}
	}
	if b.rows == 0 {
		b.file, b.first = file, offset
	}
	b.buf.Write(row)
	b.buf.WriteByte('\n')
	b.rows++
	return nil
}

// setCommitPoint records where the file should resume once the rows added so
// far are accepted.
func (b *batcher) setCommitPoint(end int64, hint string) {
	b.end, b.hint = end, hint
}

func (b *batcher) flush() error {
	if b.rows == 0 {
		return nil
	}
	if err := b.send(b.file+":"+strconv.FormatInt(b.first, 10), b.buf.Bytes()); err != nil {
		return err
	}
	b.sentRows += b.rows
	if b.onCommit != nil {
		b.onCommit(b.file, b.end, b.hint)
	}
	b.buf.Reset()
	b.rows = 0
	return nil
}

// dbConn is an HTTP connection to ClickHouse.
type dbConn struct {
	URL      string
	User     string
	Password string
}

func (c dbConn) do(query string, settings url.Values, body io.Reader, gzipped bool) ([]byte, error) {
	if settings == nil {
		settings = url.Values{}
	}
	settings.Set("query", query)
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(c.URL, "/")+"/?"+settings.Encode(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-ClickHouse-User", c.User)
	req.Header.Set("X-ClickHouse-Key", c.Password)
	if gzipped {
		req.Header.Set("Content-Encoding", "gzip")
	}
	resp, err := sessionsHTTPClient(req.URL.Hostname()).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("clickhouse %d: %s", resp.StatusCode, strings.TrimSpace(string(out)))
	}
	return out, nil
}

// sessionsHTTPClient dials the internal Traefik LB directly for
// *.viktorbarzin.me, like the other homelab verbs, so ingest does not depend
// on DNS (a new record can sit behind a cached NXDOMAIN on Technitium for a
// while). Unlike clientDialingIP it keeps certificate verification: the
// wildcard certificate covers the name, and these requests carry passwords.
func sessionsHTTPClient(host string) *http.Client {
	c := &http.Client{Timeout: 5 * time.Minute}
	if !strings.HasSuffix(host, ".viktorbarzin.me") || os.Getenv("CLAUDE_SESSIONS_USE_DNS") == "1" {
		return c
	}
	d := &net.Dialer{Timeout: 10 * time.Second}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if i := strings.LastIndex(addr, ":"); i >= 0 {
			addr = internalLBIP + addr[i:]
		}
		return d.DialContext(ctx, network, addr)
	}
	c.Transport = tr
	return c
}

// insert sends a JSONEachRow body, gzip-compressed.
func (c dbConn) insert(query, token string, rows []byte) error {
	var zb bytes.Buffer
	zw := gzip.NewWriter(&zb)
	zw.Write(rows)
	zw.Close()
	s := url.Values{}
	s.Set("date_time_input_format", "best_effort")
	if token != "" {
		s.Set("insert_deduplication_token", token)
		s.Set("deduplicate_blocks_in_dependent_materialized_views", "1")
	}
	_, err := c.do(query, s, &zb, true)
	return err
}

const (
	insertLines = "INSERT INTO claude.lines (os_user, project, session_id, agent_id, file, byte_offset, ts_hint, raw) FORMAT JSONEachRow"
	insertFiles = "INSERT INTO claude.files (os_user, project, session_id, path, kind, mtime, content) FORMAT JSONEachRow"
	// A side file larger than this is recorded with its content cut, not
	// skipped, so its existence is still searchable.
	maxSideFileBytes = 32 << 20
)

type ingestConfig struct {
	HomesRoot string // /home
	StatePath string
	DB        dbConn
	Budget    int // bytes per INSERT body before compression
	OnlyUser  string
	// RequireRestore leaves a user alone until `restore --rebuild` has run
	// for them on this box, unless the state already lists their files
	// (claude_sessions_rebuild.go). The verb sets it; tests may not.
	RequireRestore bool
}

type ingestStats struct {
	Users        int
	FilesSeen    int
	FilesChanged int
	Lines        int
	Bytes        int64
	SideFiles    int
	HomeFiles    int // whole files sent to claude.home_files
	HomeLines    int // lines sent to claude.home_lines
	FileErrors   int
	UsersWaiting int // users skipped until restore --rebuild has run for them
}

type lineRow struct {
	OsUser     string  `json:"os_user"`
	Project    string  `json:"project"`
	SessionID  string  `json:"session_id"`
	AgentID    string  `json:"agent_id"`
	File       string  `json:"file"`
	ByteOffset int64   `json:"byte_offset"`
	TsHint     *string `json:"ts_hint,omitempty"`
	Raw        string  `json:"raw"`
}

type sideFileRow struct {
	OsUser    string `json:"os_user"`
	Project   string `json:"project"`
	SessionID string `json:"session_id"`
	Path      string `json:"path"`
	Kind      string `json:"kind"`
	Mtime     string `json:"mtime"`
	Content   string `json:"content"`
}

// runIngest does one pass over every user's ~/.claude and ~/.codex. A database error
// stops the run (the state keeps every batch that was accepted); a problem
// with one file is counted and the run moves on.
func runIngest(cfg ingestConfig) (ingestStats, error) {
	var st ingestStats
	unlock, err := lockIngestState(cfg.StatePath)
	if err != nil {
		return st, err
	}
	defer unlock()
	state, err := loadState(cfg.StatePath)
	if err != nil {
		return st, err
	}
	if cfg.Budget <= 0 {
		cfg.Budget = 8 << 20
	}
	homes, err := os.ReadDir(cfg.HomesRoot)
	if err != nil {
		return st, err
	}
	seen := map[string]bool{}
	for _, h := range homes {
		if !h.IsDir() || (cfg.OnlyUser != "" && h.Name() != cfg.OnlyUser) {
			continue
		}
		home := filepath.Join(cfg.HomesRoot, h.Name())
		hfi, err := os.Lstat(home)
		if err != nil || !hfi.IsDir() {
			continue
		}
		owner := hfi.Sys().(*syscall.Stat_t).Uid
		user := h.Name()
		if cfg.RequireRestore && !rebuildMarked(cfg.StatePath, user) {
			if !stateTracksHome(state, home) {
				if hasAgentDirs(home) {
					st.UsersWaiting++
				}
				continue
			}
			// The live box: this user has been ingested all along.
			if err := writeRebuildMarker(cfg.StatePath, user, "already ingesting"); err != nil {
				return st, err
			}
		}
		batch := &homeFileBatch{db: cfg.DB, budget: cfg.Budget, state: state}
		found, err := walkHome(home, func(abs, rel string, d fs.DirEntry) error {
			class, info := classifyHomeFile(home, abs, rel)
			if class == homeSkip {
				return nil
			}
			seen[abs] = true
			st.FilesSeen++
			switch class {
			case homeTranscript:
				return ingestOne(cfg, state, &st, user, owner, abs, info)
			case homeAppend:
				return ingestHomeAppend(cfg, state, &st, user, owner, abs, rel)
			}
			if unchangedSinceLastRun(state.Files[abs], d) {
				return nil
			}
			return ingestHomeWhole(cfg, state, &st, batch, user, owner, abs, rel)
		})
		if err == nil {
			err = batch.flush()
		}
		if found {
			st.Users++
		}
		if err != nil {
			saveState(cfg.StatePath, state)
			var dbe errDB
			if errors.As(err, &dbe) {
				return st, dbe.error
			}
			return st, err
		}
	}
	// Forget files that no longer exist, so the state does not grow forever
	// once local transcripts are trimmed. Their rows stay in the database.
	if cfg.OnlyUser == "" {
		for p := range state.Files {
			if !seen[p] {
				delete(state.Files, p)
			}
		}
	}
	return st, saveState(cfg.StatePath, state)
}

// hasAgentDirs reports whether home has a ~/.claude or ~/.codex with
// anything in it, the users worth counting as waiting.
func hasAgentDirs(home string) bool {
	for _, r := range homeRoots {
		if d, err := os.Open(filepath.Join(home, r)); err == nil {
			names, _ := d.Readdirnames(1)
			d.Close()
			if len(names) > 0 {
				return true
			}
		}
	}
	return false
}

// errDB marks a database failure, which stops the whole run.
type errDB struct{ error }

func ingestOne(cfg ingestConfig, state *ingestState, st *ingestStats, user string, owner uint32, path string, info pathInfo) error {
	// O_NOFOLLOW plus the owner check: this runs as root over other users'
	// homes, so a symlink or a file the user does not own must never be read.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		st.FileErrors++
		return nil
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		st.FileErrors++
		return nil
	}
	sys := fi.Sys().(*syscall.Stat_t)
	if sys.Uid != owner {
		st.FileErrors++
		return nil
	}
	size, mtime := fi.Size(), fi.ModTime().UnixNano()
	skip, offset, hint := planFile(state.Files[path], sys.Ino, size, mtime)
	if skip {
		return nil
	}
	st.FilesChanged++

	if info.Kind != kindTranscript {
		content, err := io.ReadAll(io.LimitReader(f, maxSideFileBytes))
		if err != nil {
			st.FileErrors++
			return nil
		}
		row, _ := json.Marshal(sideFileRow{OsUser: user, Project: info.Project, SessionID: info.Session,
			Path: path, Kind: info.Kind.String(), Mtime: fi.ModTime().UTC().Format(time.RFC3339Nano), Content: string(content)})
		if err := cfg.DB.insert(insertFiles, "", append(row, '\n')); err != nil {
			return errDB{err}
		}
		// claude.files holds text, and JSON turns bytes that are not UTF-8
		// into U+FFFD, so a binary tool result (a fetched PDF) also goes to
		// claude.home_files as base64, which restore prefers.
		if rel := transcriptRel(user, path); rel != "" && !utf8.Valid(content) && fi.Size() <= maxSideFileBytes {
			hrow, _ := json.Marshal(homeFileRow{OsUser: user, Path: rel, Kind: homeKind(rel), Mtime: fi.ModTime().UTC().Format(time.RFC3339Nano),
				Mode: uint32(fi.Mode().Perm()), Size: size, Encoding: "base64", Content: base64.StdEncoding.EncodeToString(content)})
			if err := cfg.DB.insert(insertHomeFiles, "", append(hrow, '\n')); err != nil {
				return errDB{err}
			}
			st.HomeFiles++
		}
		st.SideFiles++
		state.Files[path] = &fileState{Inode: sys.Ino, Size: size, MtimeNs: mtime, Offset: size}
		return nil
	}

	return appendLines(cfg, state, st, path, f, sys.Ino, size, mtime, offset, hint, "", insertLines,
		func(off int64, line []byte, h string) ([]byte, error) {
			row := lineRow{OsUser: user, Project: info.Project, SessionID: info.Session, AgentID: info.Agent,
				File: path, ByteOffset: off, Raw: string(line)}
			if h != "" {
				hv := h
				row.TsHint = &hv
			}
			st.Lines++
			return json.Marshal(row)
		})
}

// appendLines sends the complete lines of f from offset on, in batches, with
// query. mkRow turns one line into its JSONEachRow row. The state is saved
// after every accepted batch.
func appendLines(cfg ingestConfig, state *ingestState, st *ingestStats, path string, f *os.File, inode uint64, size, mtime, offset int64, hint, gen, query string,
	mkRow func(off int64, line []byte, hint string) ([]byte, error)) error {
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		st.FileErrors++
		return nil
	}
	// The token names the file version: a transcript Claude Code rewrote
	// (a new inode) is read again from 0, and a token equal to the old
	// file's would make ClickHouse drop that batch, new lines included.
	tokenKey := path + "@" + strconv.FormatUint(inode, 10)
	if gen != "" {
		tokenKey = path + "#" + gen
	}
	bt := newBatcher(cfg.Budget, func(token string, body []byte) error {
		if err := cfg.DB.insert(query, token, body); err != nil {
			return errDB{err}
		}
		return nil
	})
	bt.onCommit = func(_ string, end int64, h string) {
		// Saved after every accepted batch, so a crash re-sends at most the
		// batch in flight, which the dedup token then drops.
		// Size -1 marks the file as part-done: if the run dies here, the next
		// one must not mistake an unchanged size and mtime for "all sent".
		state.Files[path] = &fileState{Inode: inode, Size: -1, MtimeNs: mtime, Offset: end, TsHint: h, Gen: gen}
		saveState(cfg.StatePath, state)
	}
	end, lastHint, err := readNewLines(io.LimitReader(f, size-offset), offset, hint, func(off int64, line []byte, h string) error {
		b, err := mkRow(off, line, h)
		if err != nil {
			return err
		}
		if err := bt.add(tokenKey, off, b); err != nil {
			return err
		}
		bt.setCommitPoint(off+int64(len(line))+1, h)
		st.Bytes += int64(len(line)) + 1
		return nil
	})
	if err == nil {
		err = bt.flush()
	}
	if err != nil {
		var dbe errDB
		if errors.As(err, &dbe) {
			return dbe.error
		}
		st.FileErrors++
		return nil
	}
	state.Files[path] = &fileState{Inode: inode, Size: size, MtimeNs: mtime, Offset: end, TsHint: lastHint, Gen: gen}
	return nil
}

// parseEnvFile reads KEY=VALUE lines (the systemd EnvironmentFile shape).
func parseEnvFile(s string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		out[strings.TrimSpace(k)] = v
	}
	return out
}
