package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Lands of one repo on this machine take turns for their final
// merge-verify-push, so a land never loses a push race to another land on
// the same box. Without it, eight agents landing on f1-stream at once
// (2026-10-30 drill re-runs) made four lands lose three races in a row,
// each retry re-verifying for about six minutes, and stop with "master kept
// moving". The lock is a flock on a file every user can open; a machine with
// no lock directory (a laptop) runs without it and keeps the push retry.

// landLockDir is /run/lock unless HOMELAB_LAND_LOCK_DIR says otherwise.
func landLockDir() string {
	if d := os.Getenv("HOMELAB_LAND_LOCK_DIR"); d != "" {
		return d
	}
	return "/run/lock"
}

// landLockKey names a repo by its last two path parts, so an ssh and an https
// remote of the same Forgejo repo share one lock.
func landLockKey(remoteURL string) string {
	u := strings.TrimSuffix(strings.TrimSpace(remoteURL), "/")
	u = strings.TrimSuffix(u, ".git")
	u = strings.ReplaceAll(u, ":", "/")
	parts := strings.Split(u, "/")
	if len(parts) > 2 {
		parts = parts[len(parts)-2:]
	}
	sum := sha256.Sum256([]byte(strings.ToLower(strings.Join(parts, "/"))))
	return hex.EncodeToString(sum[:])[:16]
}

// openShared opens path for writing, creating it world-writable if it does not
// exist. It never passes O_CREAT for a file that exists: with
// fs.protected_regular=2 that fails in a sticky directory when another user
// owns the file.
func openShared(path string) (*os.File, error) {
	for i := 0; i < 3; i++ {
		f, err := os.OpenFile(path, os.O_RDWR, 0)
		if err == nil {
			return f, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		f, err = os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o666)
		if err == nil {
			_ = f.Chmod(0o666) // the umask took some bits away
			return f, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
	}
	return nil, fmt.Errorf("could not open %s", path)
}

// acquireLandLock waits up to wait for the repo's land lock, printing who holds
// it, and returns the function that releases it.
func acquireLandLock(key, who string, wait, poll time.Duration) (func(), error) {
	dir := landLockDir()
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return func() {}, nil
	}
	path := filepath.Join(dir, "homelab-land-"+key+".lock")
	f, err := openShared(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "homelab: note: no land lock (%v); landing without taking turns\n", err)
		return func() {}, nil
	}
	deadline := time.Now().Add(wait)
	announced := false
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			f.Close()
			fmt.Fprintf(os.Stderr, "homelab: note: land lock failed (%v); landing without taking turns\n", err)
			return func() {}, nil
		}
		if !announced {
			holder, _ := os.ReadFile(path)
			fmt.Fprintf(os.Stderr, "homelab: another land of this repo is pushing (%s); waiting for its turn to finish\n",
				strings.TrimSpace(string(holder)))
			announced = true
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, fmt.Errorf("waited %s for another land of this repo to finish; run `homelab work land` again", wait)
		}
		time.Sleep(poll)
	}
	_ = f.Truncate(0)
	_, _ = f.WriteAt([]byte(fmt.Sprintf("%s since %s\n", who, time.Now().UTC().Format("15:04:05Z"))), 0)
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}
