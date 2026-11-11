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
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
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
	Extract  func(io.Reader) error
	PageRows int
}

type rebuildResult struct {
	Outcome       string // "restored", "already restored" or "already ingesting"
	Stats         restoreStats
	Seeded        int      // restored files recorded in the ingest state
	KeptLineFiles []string // .jsonl files that were there first and were kept
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
	sink := newTarSink(pw)
	st, rerr := runRestore(cfg.Src, cfg.User, "", sink, cfg.PageRows)
	if rerr == nil {
		rerr = sink.Close()
	}
	pw.CloseWithError(rerr)
	xerr := <-extracted
	res.Stats = st
	if xerr != nil { // first: a failed extract also fails the writes into the pipe
		return res, fmt.Errorf("extract: %w", xerr)
	}
	if rerr != nil {
		return res, rerr
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
			state.Files[abs] = &fileState{Inode: fi.Sys().(*syscall.Stat_t).Ino, Size: fi.Size(),
				MtimeNs: fi.ModTime().UnixNano(), Offset: fi.Size(), Gen: f.Gen}
			res.Seeded++
		} else if strings.HasSuffix(f.Rel, ".jsonl") {
			res.KeptLineFiles = append(res.KeptLineFiles, f.Rel)
		}
	}
	if err := saveState(cfg.StatePath, state); err != nil {
		return res, err
	}
	res.Outcome = "restored"
	return res, writeRebuildMarker(cfg.StatePath, cfg.User, "restored")
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
			cmd := exec.Command("runuser", "-u", who, "--", "tar", "-x", "--skip-old-files", "-C", home)
			cmd.Stdin = r
			var stderr strings.Builder
			cmd.Stderr = &stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
			}
			return nil
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
	fmt.Fprintf(os.Stderr, "claude-sessions restore --rebuild user=%s outcome=%s written=%d seeded=%d kept_existing_jsonl=%d omitted=%d refused=%d gapped=%d bytes=%d duration_s=%d\n",
		who, res.Outcome, st.Written, res.Seeded, len(res.KeptLineFiles), st.Omitted, st.Refused, len(st.Gapped), st.Bytes, int(time.Since(start).Seconds()))
	printRestoreNotes(st)
	for _, k := range res.KeptLineFiles {
		fmt.Fprintf(os.Stderr, "  WARN kept the file already there, the stored copy was not written: %s\n", k)
	}
	if err != nil {
		return fmt.Errorf("restore for %s: %w", who, err)
	}
	return nil
}
