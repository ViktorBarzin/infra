package main

// `homelab claude-sessions restore`: write a user's ~/.claude and ~/.codex
// back from the session store, so `claude --resume` (and `codex resume`) work
// on a rebuilt devvm (docs/plans/2026-11-11-disposable-devvm.md).
//
// It writes transcripts and subagent transcripts (claude.lines), their side
// files (claude.files), and the rest of the two directories (claude.home_files
// and claude.home_lines). Files that already exist are left alone unless
// --force. A settings file the ingest redacted is written under its real name
// without the redacted keys (provisioning fills the secrets back in from
// Vault). When the real file is already there, the stored copy goes beside it
// as <name>.from-store; --rebuild merges it in instead.
//
// It reads with the reader account, whose results are capped (100,000 rows,
// 200 MB, cut silently). Every query here is a keyset page well under the
// caps, and paging goes on until a page comes back empty, so a cut page only
// means one more query.

import (
	"archive/tar"
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"os/user"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type storedRef struct {
	Path       string `json:"path"`
	Session    string `json:"session_id"`
	Generation string `json:"generation"`
	MtimeMs    int64  `json:"mtime_ms"`
}

type storedLine struct {
	Offset uint64 `json:"byte_offset"`
	Raw    string `json:"raw"`
}

type storedFile struct {
	Path     string `json:"path"`
	MtimeMs  int64  `json:"mtime_ms"`
	Mode     uint32 `json:"mode"`
	Encoding string `json:"encoding"`
	Redacted bool   `json:"redacted"`
	Content  string `json:"content"`
}

// restoreSource is the store as restore sees it; sqlSource is the real one.
type restoreSource interface {
	transcriptFiles(user, session string) ([]storedRef, error)
	transcriptLines(user string, ref storedRef, from uint64, limit int) ([]storedLine, error)
	sideFiles(user, session, after string, limit int) ([]storedFile, error)
	homeFiles(user, session, after string, limit int) ([]storedFile, error)
	homeLineFiles(user, session string) ([]storedRef, error)
	homeLines(user string, ref storedRef, from uint64, limit int) ([]storedLine, error)
}

// restoreSink writes one file; it returns false when the file was left alone
// because it already exists.
type restoreSink interface {
	put(rel string, mode fs.FileMode, mtime time.Time, content []byte) (bool, error)
}

// settingsKeeper is a sink that takes a redacted settings file whose real
// name already exists itself (the rebuild merges it in), instead of restore
// writing it beside as <name>.from-store.
type settingsKeeper interface {
	keepSettings(rel string, mode fs.FileMode, content []byte)
}

type restoreStats struct {
	Written int
	Skipped int // already there
	Omitted int // over the ingest size cap, stored without content
	Refused int // a stored path outside .claude/ or .codex/
	Bytes   int64
	// Redacted names settings files written without their secret keys.
	Redacted []string
	// Beside names stored settings files written as <name>.from-store,
	// because the real file was there already: merge by hand.
	Beside []string
	// Gapped names line files with bytes missing between two stored lines:
	// they are written as stored, with the missing lines left out.
	Gapped []string
	// Files is every file handed to the sink, for the rebuild's ingest state.
	Files []restoredFile
}

// restoredFile is one file restore wrote, as the ingest state needs it.
type restoredFile struct {
	Rel   string
	Size  int64
	Mtime time.Time
	Gen   string // the stored generation of a claude.home_lines file
}

// safeRel accepts only a clean relative path inside .claude/ or .codex/.
func safeRel(rel string) bool {
	if rel == "" || path.IsAbs(rel) || path.Clean(rel) != rel {
		return false
	}
	for _, p := range strings.Split(rel, "/") {
		if p == ".." || p == "." || p == "" {
			return false
		}
	}
	for _, x := range homeExtraFiles {
		if rel == x {
			return true
		}
	}
	return strings.HasPrefix(rel, ".claude/") || strings.HasPrefix(rel, ".codex/")
}

// transcriptRel maps a stored absolute transcript path (/home/<user>/.claude/...)
// to its path relative to the home directory.
func transcriptRel(user, abs string) string {
	marker := "/" + user + "/.claude/"
	i := strings.Index(abs, marker)
	if i < 0 {
		return ""
	}
	rel := abs[i+len(user)+2:]
	if !safeRel(rel) {
		return ""
	}
	return rel
}

func msTime(ms int64) time.Time {
	if ms <= 0 {
		return time.Now()
	}
	return time.UnixMilli(ms)
}

func (st *restoreStats) put(sink restoreSink, rel string, mode fs.FileMode, mtime time.Time, content []byte) error {
	return st.putGen(sink, rel, "", mode, mtime, content)
}

// putSettings writes a redacted settings file under its real name with the
// redacted keys left out. If the real file is there already, a
// settingsKeeper sink takes it; any other sink gets it as <name>.from-store.
func (st *restoreStats) putSettings(sink restoreSink, f storedFile, content []byte) error {
	clean := withoutRedacted(path.Base(f.Path), content)
	before := st.Written
	if err := st.put(sink, f.Path, fileMode(f.Mode), msTime(f.MtimeMs), clean); err != nil {
		return err
	}
	if st.Written > before || !safeRel(f.Path) {
		st.Redacted = append(st.Redacted, f.Path)
		return nil
	}
	if k, ok := sink.(settingsKeeper); ok {
		k.keepSettings(f.Path, fileMode(f.Mode), clean)
		return nil
	}
	if d, ok := sink.(*dirSink); ok {
		if b, err := os.ReadFile(filepath.Join(d.root, filepath.FromSlash(f.Path))); err == nil && bytes.Equal(b, clean) {
			return nil // restored by an earlier run
		}
	}
	beside := f.Path + ".from-store"
	st.Beside = append(st.Beside, beside)
	return st.put(sink, beside, fileMode(f.Mode), msTime(f.MtimeMs), clean)
}

func (st *restoreStats) putGen(sink restoreSink, rel, gen string, mode fs.FileMode, mtime time.Time, content []byte) error {
	if !safeRel(rel) {
		st.Refused++
		return nil
	}
	ok, err := sink.put(rel, mode, mtime, content)
	if err != nil {
		return fmt.Errorf("%s: %w", rel, err)
	}
	if ok {
		st.Written++
		st.Bytes += int64(len(content))
		st.Files = append(st.Files, restoredFile{Rel: rel, Size: int64(len(content)), Mtime: mtime, Gen: gen})
	} else {
		st.Skipped++
	}
	return nil
}

// collectLines pages through one line file and joins it back together. It
// also returns how many bytes are missing: each stored line should start
// where the one before it ended, and the ingest never skips a line that is
// not blank, so a jump means lines the store does not hold.
func collectLines(page func(from uint64) ([]storedLine, error)) ([]byte, int64, error) {
	var buf bytes.Buffer
	var from, next uint64
	var missing int64
	for {
		rows, err := page(from)
		if err != nil {
			return nil, 0, err
		}
		if len(rows) == 0 {
			return buf.Bytes(), missing, nil
		}
		for _, r := range rows {
			if r.Offset > next {
				missing += int64(r.Offset - next)
			}
			buf.WriteString(r.Raw)
			buf.WriteByte('\n')
			from = r.Offset + 1
			next = r.Offset + uint64(len(r.Raw)) + 1
		}
	}
}

func (st *restoreStats) noteGap(rel string, missing int64) {
	if missing > 0 {
		st.Gapped = append(st.Gapped, fmt.Sprintf("%s (%d bytes missing)", rel, missing))
	}
}

func decodeStored(f storedFile) ([]byte, bool) {
	switch f.Encoding {
	case "base64":
		b, err := base64.StdEncoding.DecodeString(f.Content)
		return b, err == nil
	case "omitted":
		return nil, false
	}
	return []byte(f.Content), true
}

func fileMode(m uint32) fs.FileMode {
	if m == 0 {
		return 0o600
	}
	return fs.FileMode(m) & fs.ModePerm
}

// runRestore writes everything the store holds for user (or for one session)
// into sink. pageRows bounds each query.
func runRestore(src restoreSource, user, session string, sink restoreSink, pageRows int) (restoreStats, error) {
	var st restoreStats
	if pageRows <= 0 {
		pageRows = 500
	}
	// Paths home_files holds, so a binary tool result's base64 copy there
	// wins over its lossy text copy in claude.files.
	inHomeFiles := map[string]bool{}
	// Whole home files: plans, tasks, file-history, settings, ...
	for after := ""; ; {
		rows, err := src.homeFiles(user, session, after, pageRows)
		if err != nil {
			return st, err
		}
		if len(rows) == 0 {
			break
		}
		for _, f := range rows {
			after = f.Path
			inHomeFiles[f.Path] = true
			content, ok := decodeStored(f)
			if !ok {
				st.Omitted++
				continue
			}
			if f.Redacted {
				if err := st.putSettings(sink, f, content); err != nil {
					return st, err
				}
				continue
			}
			if err := st.put(sink, f.Path, fileMode(f.Mode), msTime(f.MtimeMs), content); err != nil {
				return st, err
			}
		}
	}
	// Append-only home files: history.jsonl, Codex rollouts.
	refs, err := src.homeLineFiles(user, session)
	if err != nil {
		return st, err
	}
	for _, ref := range refs {
		content, missing, err := collectLines(func(from uint64) ([]storedLine, error) { return src.homeLines(user, ref, from, pageRows) })
		if err != nil {
			return st, err
		}
		st.noteGap(ref.Path, missing)
		if err := st.putGen(sink, ref.Path, ref.Generation, 0o600, msTime(ref.MtimeMs), content); err != nil {
			return st, err
		}
	}
	// Side files: tool results and subagent metadata.
	for after := ""; ; {
		rows, err := src.sideFiles(user, session, after, pageRows)
		if err != nil {
			return st, err
		}
		if len(rows) == 0 {
			break
		}
		for _, f := range rows {
			after = f.Path
			rel := transcriptRel(user, f.Path)
			if rel == "" {
				st.Refused++
				continue
			}
			if inHomeFiles[rel] {
				continue
			}
			if err := st.put(sink, rel, 0o600, msTime(f.MtimeMs), []byte(f.Content)); err != nil {
				return st, err
			}
		}
	}
	// Transcripts, main and subagent.
	files, err := src.transcriptFiles(user, session)
	if err != nil {
		return st, err
	}
	for _, ref := range files {
		rel := transcriptRel(user, ref.Path)
		if rel == "" {
			st.Refused++
			continue
		}
		content, missing, err := collectLines(func(from uint64) ([]storedLine, error) { return src.transcriptLines(user, ref, from, pageRows) })
		if err != nil {
			return st, err
		}
		st.noteGap(rel, missing)
		if err := st.put(sink, rel, 0o600, msTime(ref.MtimeMs), content); err != nil {
			return st, err
		}
	}
	return st, nil
}

// pathsSource restores only the named home files (--path): no transcripts,
// no side files. The SQL source filters in the query too (sqlSource.paths),
// so a one-file restore does not page through a whole home.
type pathsSource struct {
	restoreSource
	paths map[string]bool
}

func onlyPaths(src restoreSource, paths []string) restoreSource {
	m := map[string]bool{}
	for _, p := range paths {
		m[p] = true
	}
	if s, ok := src.(sqlSource); ok {
		s.paths = paths
		src = s
	}
	return pathsSource{restoreSource: src, paths: m}
}

func (p pathsSource) transcriptFiles(string, string) ([]storedRef, error) { return nil, nil }
func (p pathsSource) sideFiles(string, string, string, int) ([]storedFile, error) {
	return nil, nil
}

func (p pathsSource) homeFiles(user, session, after string, limit int) ([]storedFile, error) {
	for {
		rows, err := p.restoreSource.homeFiles(user, session, after, limit)
		if err != nil || len(rows) == 0 {
			return nil, err
		}
		var out []storedFile
		for _, r := range rows {
			if p.paths[r.Path] {
				out = append(out, r)
			}
		}
		if len(out) > 0 {
			return out, nil
		}
		after = rows[len(rows)-1].Path
	}
}

func (p pathsSource) homeLineFiles(user, session string) ([]storedRef, error) {
	refs, err := p.restoreSource.homeLineFiles(user, session)
	var out []storedRef
	for _, r := range refs {
		if p.paths[r.Path] {
			out = append(out, r)
		}
	}
	return out, err
}

// ---- sinks -----------------------------------------------------------------

// dirSink writes into a home directory as the user running the command.
type dirSink struct {
	root  string
	force bool
}

func (d *dirSink) put(rel string, mode fs.FileMode, mtime time.Time, content []byte) (bool, error) {
	p := filepath.Join(d.root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return false, err
	}
	flags := os.O_WRONLY | os.O_CREATE | syscall.O_NOFOLLOW
	if d.force {
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_EXCL
	}
	f, err := os.OpenFile(p, flags, mode)
	if errors.Is(err, fs.ErrExist) && !d.force {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := f.Write(content); err != nil {
		f.Close()
		return false, err
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return false, err
	}
	if err := f.Close(); err != nil {
		return false, err
	}
	return true, os.Chtimes(p, mtime, mtime)
}

// tarSink writes a tar stream, for restoring into another user's home:
// extracting it as that user (runuser ... tar -x) keeps root's hands off a
// directory the user controls.
type tarSink struct {
	tw   *tar.Writer
	dirs map[string]bool
}

func newTarSink(w io.Writer) *tarSink { return &tarSink{tw: tar.NewWriter(w), dirs: map[string]bool{}} }

func (t *tarSink) put(rel string, mode fs.FileMode, mtime time.Time, content []byte) (bool, error) {
	var parents []string
	for d := path.Dir(rel); d != "." && !t.dirs[d]; d = path.Dir(d) {
		parents = append(parents, d)
	}
	for i := len(parents) - 1; i >= 0; i-- {
		t.dirs[parents[i]] = true
		if err := t.tw.WriteHeader(&tar.Header{Name: parents[i] + "/", Typeflag: tar.TypeDir, Mode: 0o700, ModTime: mtime, Format: tar.FormatPAX}); err != nil {
			return false, err
		}
	}
	h := &tar.Header{Name: rel, Typeflag: tar.TypeReg, Mode: int64(mode), Size: int64(len(content)), ModTime: mtime, Format: tar.FormatPAX}
	if err := t.tw.WriteHeader(h); err != nil {
		return false, err
	}
	_, err := t.tw.Write(content)
	return err == nil, err
}

func (t *tarSink) Close() error { return t.tw.Close() }

// ---- the ClickHouse source -------------------------------------------------

type sqlSource struct {
	db    dbConn
	paths []string // only these home files (--path); empty means all
}

// pathFilter is the SQL condition and parameter for sqlSource.paths.
func (s sqlSource) pathFilter(params map[string]string) string {
	if len(s.paths) == 0 {
		return ""
	}
	q := make([]string, len(s.paths))
	for i, p := range s.paths {
		q[i] = "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(p) + "'"
	}
	params["only"] = "[" + strings.Join(q, ",") + "]"
	return " AND has({only:Array(String)}, path)"
}

func (s sqlSource) query(q string, params map[string]string, each func(line []byte) error) error {
	v := url.Values{}
	v.Set("output_format_json_quote_64bit_integers", "0")
	for k, p := range params {
		v.Set("param_"+k, p)
	}
	out, err := s.db.do(q+" FORMAT JSONEachRow", v, nil, false)
	if err != nil {
		return err
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 1<<20), len(out)+1)
	for sc.Scan() {
		if len(bytes.TrimSpace(sc.Bytes())) == 0 {
			continue
		}
		if err := each(sc.Bytes()); err != nil {
			return err
		}
	}
	return sc.Err()
}

func queryRows[T any](s sqlSource, q string, params map[string]string) ([]T, error) {
	var out []T
	err := s.query(q, params, func(line []byte) error {
		var r T
		if err := json.Unmarshal(line, &r); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}

func (s sqlSource) transcriptFiles(user, session string) ([]storedRef, error) {
	return queryRows[storedRef](s, `SELECT lines.file AS path, session_id, toUnixTimestamp64Milli(max(ts)) AS mtime_ms
		FROM claude.lines WHERE os_user = {u:String} AND ({s:String} = '' OR session_id = {s:String})
		GROUP BY path, session_id ORDER BY path`, map[string]string{"u": user, "s": session})
}

func (s sqlSource) transcriptLines(user string, ref storedRef, from uint64, limit int) ([]storedLine, error) {
	return queryRows[storedLine](s, `SELECT byte_offset, raw FROM claude.lines
		WHERE os_user = {u:String} AND session_id = {s:String} AND lines.file = {f:String} AND byte_offset >= `+strconv.FormatUint(from, 10)+`
		ORDER BY byte_offset, ingested_at DESC LIMIT 1 BY byte_offset LIMIT `+strconv.Itoa(limit),
		map[string]string{"u": user, "s": ref.Session, "f": ref.Path})
}

func (s sqlSource) sideFiles(user, session, after string, limit int) ([]storedFile, error) {
	return queryRows[storedFile](s, `SELECT path, toUnixTimestamp64Milli(mtime) AS mtime_ms, content FROM claude.files FINAL
		WHERE os_user = {u:String} AND ({s:String} = '' OR session_id = {s:String}) AND path > {a:String}
		ORDER BY path LIMIT `+strconv.Itoa(limit), map[string]string{"u": user, "s": session, "a": after})
}

func (s sqlSource) homeFiles(user, session, after string, limit int) ([]storedFile, error) {
	params := map[string]string{"u": user, "s": session, "a": after}
	return queryRows[storedFile](s, `SELECT path, toUnixTimestamp64Milli(mtime) AS mtime_ms, mode, encoding, redacted, content
		FROM claude.home_files FINAL
		WHERE os_user = {u:String} AND path > {a:String} AND ({s:String} = '' OR position(path, concat('/', {s:String}, '/')) > 0)`+s.pathFilter(params)+`
		ORDER BY path LIMIT `+strconv.Itoa(limit), params)
}

func (s sqlSource) homeLineFiles(user, session string) ([]storedRef, error) {
	params := map[string]string{"u": user, "s": session}
	return queryRows[storedRef](s, `SELECT path, argMax(generation, ingested_at) AS generation,
		toUnixTimestamp64Milli(argMax(mtime, ingested_at)) AS mtime_ms
		FROM claude.home_lines WHERE os_user = {u:String} AND ({s:String} = '' OR position(path, {s:String}) > 0)`+s.pathFilter(params)+`
		GROUP BY path ORDER BY path`, params)
}

func (s sqlSource) homeLines(user string, ref storedRef, from uint64, limit int) ([]storedLine, error) {
	return queryRows[storedLine](s, `SELECT byte_offset, raw FROM claude.home_lines FINAL
		WHERE os_user = {u:String} AND path = {p:String} AND generation = {g:String} AND byte_offset >= `+strconv.FormatUint(from, 10)+`
		ORDER BY byte_offset LIMIT `+strconv.Itoa(limit), map[string]string{"u": user, "p": ref.Path, "g": ref.Generation})
}

// ---- the verb --------------------------------------------------------------

// A Linux user name (emo is three letters) and a session id.
var (
	restoreUserRe    = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
	restoreSessionRe = regexp.MustCompile(`^[A-Za-z0-9_-]{4,80}$`)
)

const restoreUsage = `usage: homelab claude-sessions restore --user <name> (--to <home-dir> | --tar <file|-> | --rebuild) [--session <id>] [--path <rel>]... [--force]
  --to DIR     write into DIR/.claude and DIR/.codex as yourself; existing files are kept unless --force
  --tar FILE   write a tar stream instead ("-" for stdout); restore into another user's home with
               homelab claude-sessions restore --user emo --tar - | sudo runuser -u emo -- tar -x --skip-old-files -C /home/emo
  --rebuild    root, run by t3-provision-users on every pass: on a rebuilt devvm, put the user's
               whole state back into their home once, record it in the ingest state as already
               sent, and let the ingest start on that user; a no-op for a user this box already ingests.
               --home DIR and --state FILE replace the user's home and the ingest state, for a drill
  --session    only that session: its transcript, subagents, tool results, workflows and file-history
  --path P     only the stored home file P (repeatable), such as .claude.json or .codex/config.toml`

func claudeSessionsRestore(args []string) error {
	var who, to, tarOut, session, rbHome, rbState string
	var paths []string
	force, rebuild := false, false
	for i := 0; i < len(args); i++ {
		need := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value\n%s", args[i], restoreUsage)
			}
			i++
			return args[i], nil
		}
		var err error
		switch args[i] {
		case "--user":
			who, err = need()
		case "--to":
			to, err = need()
		case "--tar":
			tarOut, err = need()
		case "--session":
			session, err = need()
		case "--path":
			var p string
			if p, err = need(); err == nil {
				if !safeRel(p) {
					return fmt.Errorf("--path takes a stored path relative to the home, such as .claude.json or .codex/config.toml")
				}
				paths = append(paths, p)
			}
		case "--force":
			force = true
		case "--rebuild":
			rebuild = true
		case "--home":
			rbHome, err = need()
		case "--state":
			rbState, err = need()
		case "-h", "--help":
			fmt.Println(restoreUsage)
			return nil
		default:
			return fmt.Errorf("unknown argument %q\n%s", args[i], restoreUsage)
		}
		if err != nil {
			return err
		}
	}
	if who == "" {
		if u, err := user.Current(); err == nil {
			who = u.Username
		}
	}
	if !restoreUserRe.MatchString(who) || (session != "" && !restoreSessionRe.MatchString(session)) {
		return fmt.Errorf("--user and --session take a plain name or id\n%s", restoreUsage)
	}
	if rebuild {
		if to != "" || tarOut != "" || session != "" || force || len(paths) > 0 {
			return fmt.Errorf("--rebuild takes only --user, --home and --state\n%s", restoreUsage)
		}
		return claudeSessionsRebuild(who, rbHome, rbState)
	}
	if rbHome != "" || rbState != "" {
		return fmt.Errorf("--home and --state go with --rebuild\n%s", restoreUsage)
	}
	if (to == "") == (tarOut == "") {
		return fmt.Errorf("give exactly one of --to and --tar\n%s", restoreUsage)
	}
	if force && tarOut != "" {
		return fmt.Errorf("--force applies to --to; with --tar, tar's own flags decide")
	}

	var sink restoreSink
	var closeSink func() error
	if to != "" {
		fi, err := os.Lstat(to)
		if err != nil || !fi.IsDir() {
			return fmt.Errorf("--to %s: not a directory", to)
		}
		// Root writing into a directory someone else controls could be led
		// through a symlink anywhere; that case goes through --tar and runuser.
		if os.Geteuid() == 0 && fi.Sys().(*syscall.Stat_t).Uid != 0 {
			return fmt.Errorf("as root, restore into another user's directory with --tar - | runuser -u <user> -- tar -x --skip-old-files -C %s", to)
		}
		sink = &dirSink{root: to, force: force}
	} else {
		w := io.Writer(os.Stdout)
		if tarOut != "-" {
			f, err := os.OpenFile(tarOut, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
			if err != nil {
				return err
			}
			defer f.Close()
			w = f
		}
		ts := newTarSink(w)
		sink, closeSink = ts, ts.Close
	}

	c, err := sessionsConn("reader")
	if err != nil {
		return err
	}
	var src restoreSource = sqlSource{db: c}
	if len(paths) > 0 {
		src = onlyPaths(src, paths)
	}
	st, err := runRestore(src, who, session, sink, 500)
	if closeSink != nil {
		if cerr := closeSink(); err == nil {
			err = cerr
		}
	}
	fmt.Fprintf(os.Stderr, "claude-sessions restore user=%s session=%s written=%d kept_existing=%d omitted=%d refused=%d gapped=%d bytes=%d\n",
		who, session, st.Written, st.Skipped, st.Omitted, st.Refused, len(st.Gapped), st.Bytes)
	printRestoreNotes(st)
	return err
}

func printRestoreNotes(st restoreStats) {
	for _, r := range st.Redacted {
		fmt.Fprintf(os.Stderr, "  settings written without their secret keys, provisioning fills them from Vault: %s\n", r)
	}
	for _, r := range st.Beside {
		fmt.Fprintf(os.Stderr, "  the real file was there, stored copy written beside it, merge by hand: %s\n", r)
	}
	for _, g := range st.Gapped {
		fmt.Fprintf(os.Stderr, "  WARN lines missing from the store, written without them: %s\n", g)
	}
}
