package main

// `homelab claude-sessions restore --rebuild`: the session store's half of a
// devvm rebuild (docs/plans/2026-11-11-disposable-devvm.md).
//
// t3-provision-users runs it as root for every account with a home under
// /home (the roster users, breakglass) on every pass.
// Once per user and box it writes the user's stored ~/.claude and ~/.codex
// into their home (as the user, through runuser and tar --skip-old-files),
// then records every file it wrote in the ingest state as already sent, and
// leaves a marker in /var/lib/claude-sessions-ingest/restored/<user>.
//
// The ingest leaves a user alone until that marker exists (or its state
// already lists the user's files, which is the live box). Without the wait, a
// rebuilt box's first, nearly empty history.jsonl or settings file would be
// ingested before the restore and become the newest copy in the store, and
// restore would then hand back that copy. Without the seeded state, the first
// ingest after the restore would read every restored file again from the
// start: whole-file rows sent twice, line files sent again under a new
// generation, transcripts inserted a second time.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type rebuildConfig struct {
	User      string
	Home      string // the user's home directory
	StatePath string // the ingest state file
	Src       restoreSource
	// Extract unpacks the tar stream into Home as the user, keeping files
	// that are already there.
	Extract func(io.Reader) error
	// Overwrite unpacks a tar stream into Home as the user, replacing files
	// that are there: the merged settings files.
	Overwrite func(io.Reader) error
	// Remove deletes files (relative to Home) as the user: what a failed
	// attempt wrote, so the retry does not keep a cut copy.
	Remove   func(rels []string) error
	PageRows int
}

type rebuildResult struct {
	Outcome       string // "restored", "already restored" or "already ingesting"
	Stats         restoreStats
	Seeded        int      // restored files recorded in the ingest state
	KeptLineFiles []string // .jsonl files that were there first and were kept
	Merged        []string // settings files that were there first, stored keys merged in
	Beside        []string // settings files that were there first and could not be merged: <name>.from-store
}

// rebuildSink hands the tar stream only the files that are not in the home
// yet, remembers which ones it handed over (to remove them if the attempt
// fails), and keeps redacted settings files that are already there for the
// merge.
type rebuildSink struct {
	tar       *tarSink
	home      string
	attempted []string
	keptLines []string
	kept      []keptSettings
}

type keptSettings struct {
	rel     string
	mode    fs.FileMode
	content []byte
}

func (r *rebuildSink) put(rel string, mode fs.FileMode, mtime time.Time, content []byte) (bool, error) {
	if _, err := os.Lstat(filepath.Join(r.home, filepath.FromSlash(rel))); err == nil {
		if strings.HasSuffix(rel, ".jsonl") {
			r.keptLines = append(r.keptLines, rel)
		}
		return false, nil
	}
	r.attempted = append(r.attempted, rel)
	return r.tar.put(rel, mode, mtime, content)
}

func (r *rebuildSink) keepSettings(rel string, mode fs.FileMode, content []byte) {
	r.kept = append(r.kept, keptSettings{rel: rel, mode: mode, content: content})
}

// mergeIfAbsent adds what stored has and have lacks: objects key by key,
// arrays element by element (permission rules, hook entries), and never
// changes a value have already holds.
func mergeIfAbsent(have, stored any) any {
	switch h := have.(type) {
	case map[string]any:
		s, ok := stored.(map[string]any)
		if !ok {
			return have
		}
		for k, sv := range s {
			if hv, ok := h[k]; ok {
				h[k] = mergeIfAbsent(hv, sv)
			} else {
				h[k] = sv
			}
		}
		return h
	case []any:
		s, ok := stored.([]any)
		if !ok {
			return have
		}
		seen := map[string]bool{}
		for _, e := range h {
			b, _ := json.Marshal(e)
			seen[string(b)] = true
		}
		for _, e := range s {
			if b, _ := json.Marshal(e); !seen[string(b)] {
				h = append(h, e)
			}
		}
		return h
	}
	return have
}

// mergeKept writes the stored keys into each settings file that was there
// first, such as the skeleton the memory hooks wiring makes on a pass whose
// restore failed. A file that is not JSON, or that will not parse, gets the
// stored copy beside it instead.
func mergeKept(cfg rebuildConfig, kept []keptSettings, res *rebuildResult) error {
	if len(kept) == 0 {
		return nil
	}
	var buf bytes.Buffer
	ts := newTarSink(&buf)
	now := time.Now()
	for _, k := range kept {
		abs := filepath.Join(cfg.Home, filepath.FromSlash(k.rel))
		var have, stored any
		b, err := readRegular(abs)
		if err == nil && strings.Contains(path.Base(k.rel), ".json") && json.Unmarshal(b, &have) == nil && json.Unmarshal(k.content, &stored) == nil {
			if _, isObj := have.(map[string]any); isObj {
				out, err := encodeSettingsJSON(mergeIfAbsent(have, stored))
				if err != nil {
					return err
				}
				if !bytes.Equal(out, b) {
					mode := k.mode
					if fi, err := os.Lstat(abs); err == nil {
						mode = fi.Mode().Perm()
					}
					if _, err := ts.put(k.rel, mode, now, out); err != nil {
						return err
					}
				}
				res.Merged = append(res.Merged, k.rel)
				continue
			}
		}
		if _, err := ts.put(k.rel+".from-store", k.mode, now, k.content); err != nil {
			return err
		}
		res.Beside = append(res.Beside, k.rel+".from-store")
	}
	if err := ts.Close(); err != nil {
		return err
	}
	return cfg.Overwrite(&buf)
}

// readRegular reads a file that is a regular file itself, not a link.
func readRegular(p string) ([]byte, error) {
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: not a regular file", p)
	}
	return io.ReadAll(io.LimitReader(f, maxHomeFileBytes))
}

// rebuildMarker is the file that says restore is done for user on this box.
func rebuildMarker(statePath, user string) string {
	return filepath.Join(filepath.Dir(statePath), "restored", user)
}

func writeRebuildMarker(statePath, user, why string) error {
	p := rebuildMarker(statePath, user)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(why+" "+time.Now().UTC().Format(time.RFC3339)+"\n"), 0o600)
}

func rebuildMarked(statePath, user string) bool {
	_, err := os.Lstat(rebuildMarker(statePath, user))
	return err == nil
}

// stateTracksHome reports whether the ingest state lists any file in home.
func stateTracksHome(s *ingestState, home string) bool {
	prefix := strings.TrimRight(home, "/") + "/"
	for p := range s.Files {
		if strings.HasPrefix(p, prefix) {
			return true
		}
	}
	return false
}

// lockIngestState takes the lock the ingest holds for a whole run, so the
// state is never written by both at once.
func lockIngestState(statePath string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(statePath), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(filepath.Dir(statePath), "state.lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

func runRebuildRestore(cfg rebuildConfig) (rebuildResult, error) {
	var res rebuildResult
	if rebuildMarked(cfg.StatePath, cfg.User) {
		res.Outcome = "already restored"
		return res, nil
	}
	unlock, err := lockIngestState(cfg.StatePath)
	if err != nil {
		return res, err
	}
	state, err := loadState(cfg.StatePath)
	if err == nil && stateTracksHome(state, cfg.Home) {
		err = writeRebuildMarker(cfg.StatePath, cfg.User, "already ingesting")
		res.Outcome = "already ingesting"
	}
	unlock()
	if err != nil || res.Outcome != "" {
		return res, err
	}

	// Stream the restore into the extractor. The lock is not held here: a
	// full restore takes long, and the ingest skips this user meanwhile.
	pr, pw := io.Pipe()
	extracted := make(chan error, 1)
	go func() {
		err := cfg.Extract(pr)
		pr.CloseWithError(errors.Join(err, errors.New("extract stopped")))
		extracted <- err
	}()
	sink := &rebuildSink{tar: newTarSink(pw), home: cfg.Home}
	st, rerr := runRestore(cfg.Src, cfg.User, "", sink, cfg.PageRows)
	if rerr == nil {
		rerr = sink.tar.Close()
	}
	pw.CloseWithError(rerr)
	xerr := <-extracted
	res.Stats = st
	res.KeptLineFiles = sink.keptLines
	// On a failure, take back what this attempt wrote: a file cut off
	// mid-stream would otherwise be kept by the retry's --skip-old-files and
	// then sent by the ingest as the newest copy.
	fail := func(err error) (rebuildResult, error) {
		if cfg.Remove == nil {
			return res, err
		}
		if rmErr := cfg.Remove(sink.attempted); rmErr != nil {
			err = errors.Join(err, fmt.Errorf("removing this attempt's files: %w", rmErr))
		}
		return res, err
	}
	if xerr != nil { // first: a failed extract also fails the writes into the pipe
		return fail(fmt.Errorf("extract: %w", xerr))
	}
	if rerr != nil {
		return fail(rerr)
	}
	if err := mergeKept(cfg, sink.kept, &res); err != nil {
		return fail(fmt.Errorf("merging settings: %w", err))
	}

	unlock, err = lockIngestState(cfg.StatePath)
	if err != nil {
		return res, err
	}
	defer unlock()
	state, err = loadState(cfg.StatePath)
	if err != nil {
		return res, err
	}
	for _, f := range st.Files {
		abs := filepath.Join(cfg.Home, filepath.FromSlash(f.Rel))
		fi, err := os.Lstat(abs)
		if err == nil && fi.Mode().IsRegular() && fi.Size() == f.Size && fi.ModTime().UnixMilli() == f.Mtime.UnixMilli() {
			fst := &fileState{Inode: fi.Sys().(*syscall.Stat_t).Ino, Size: fi.Size(),
				MtimeNs: fi.ModTime().UnixNano(), Offset: fi.Size(), Gen: f.Gen}
			if isSettingsFile(path.Base(f.Rel)) {
				fst.Rv = redactVersion
			}
			state.Files[abs] = fst
			res.Seeded++
		}
	}
	if err := saveState(cfg.StatePath, state); err != nil {
		return res, err
	}
	res.Outcome = "restored"
	return res, writeRebuildMarker(cfg.StatePath, cfg.User, "restored")
}

// runAsUser runs a command as user through runuser, with stdin from r.
func runAsUser(user string, r io.Reader, name string, args ...string) error {
	cmd := exec.Command("runuser", append([]string{"-u", user, "--", name}, args...)...)
	cmd.Stdin = r
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func claudeSessionsRebuild(who, home, statePath string) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("--rebuild runs as root (t3-provision-users); restore into your own home with --to")
	}
	u, err := user.Lookup(who)
	if err != nil {
		return err
	}
	if home == "" {
		home = u.HomeDir
	}
	home = filepath.Clean(home)
	if statePath == "" {
		statePath = claudeSessionsState
	}
	if fi, err := os.Lstat(home); err != nil || !fi.IsDir() {
		return fmt.Errorf("%s: home %s is not a directory", who, home)
	}
	cfg := rebuildConfig{User: who, Home: home, StatePath: statePath, PageRows: 500,
		Extract: func(r io.Reader) error {
			// As the user, so root never writes into a directory the user
			// controls; --skip-old-files keeps whatever is there already.
			return runAsUser(who, r, "tar", "-x", "--skip-old-files", "-C", home)
		},
		Overwrite: func(r io.Reader) error {
			return runAsUser(who, r, "tar", "-x", "--no-overwrite-dir", "-C", home)
		},
		Remove: func(rels []string) error {
			if len(rels) == 0 {
				return nil
			}
			var list bytes.Buffer
			for _, rel := range rels {
				list.WriteString(filepath.Join(home, filepath.FromSlash(rel)))
				list.WriteByte(0)
			}
			return runAsUser(who, &list, "xargs", "-0", "-r", "rm", "-f", "--")
		}}
	if rebuildMarked(cfg.StatePath, who) {
		fmt.Fprintf(os.Stderr, "claude-sessions restore --rebuild user=%s: already restored\n", who)
		return nil
	}
	c, err := sessionsConn("reader")
	if err != nil {
		return err
	}
	cfg.Src = sqlSource{db: c}
	start := time.Now()
	res, err := runRebuildRestore(cfg)
	if err != nil {
		res.Outcome = "failed"
	}
	st := res.Stats
	fmt.Fprintf(os.Stderr, "claude-sessions restore --rebuild user=%s outcome=%s written=%d seeded=%d kept_existing_jsonl=%d merged_settings=%d omitted=%d refused=%d gapped=%d bytes=%d duration_s=%d\n",
		who, res.Outcome, st.Written, res.Seeded, len(res.KeptLineFiles), len(res.Merged), st.Omitted, st.Refused, len(st.Gapped), st.Bytes, int(time.Since(start).Seconds()))
	printRestoreNotes(st)
	for _, m := range res.Merged {
		fmt.Fprintf(os.Stderr, "  the file was there first, stored keys merged in: %s\n", m)
	}
	for _, b := range res.Beside {
		fmt.Fprintf(os.Stderr, "  the file was there first, stored copy written beside it, merge by hand: %s\n", b)
	}
	for _, k := range res.KeptLineFiles {
		fmt.Fprintf(os.Stderr, "  WARN kept the file already there, the stored copy was not written: %s\n", k)
	}
	if err != nil {
		return fmt.Errorf("restore for %s: %w", who, err)
	}
	return nil
}
