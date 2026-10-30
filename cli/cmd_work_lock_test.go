package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Lands of one repo on this machine take turns for the final
// merge-verify-push. In the 2026-10-30 drill re-runs, with eight agents
// landing on f1-stream, four lands lost three push races in a row (each retry
// re-verifies for about six minutes) and stopped with "master kept moving".
func TestLandLockMakesLandsTakeTurns(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOMELAB_LAND_LOCK_DIR", dir)
	key := landLockKey("git@git.viktorbarzin.me:viktor/f1-stream.git")
	if other := landLockKey("https://forgejo.viktorbarzin.me/viktor/f1-stream.git"); other != key {
		t.Fatalf("ssh and https remotes of one repo must share a lock: %q vs %q", key, other)
	}
	if landLockKey("https://forgejo.viktorbarzin.me/viktor/infra.git") == key {
		t.Fatal("different repos must not share a lock")
	}

	release, err := acquireLandLock(key, "first", time.Second, 10*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, "homelab-land-"+key+".lock"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o666 {
		t.Fatalf("lock file mode %v: every user on the box must be able to open it", info.Mode().Perm())
	}

	if _, err := acquireLandLock(key, "second", 100*time.Millisecond, 10*time.Millisecond); err == nil {
		t.Fatal("a second land must wait while the first holds the lock")
	}

	got := make(chan error, 1)
	go func() {
		rel, err := acquireLandLock(key, "third", 2*time.Second, 10*time.Millisecond)
		if err == nil {
			rel()
		}
		got <- err
	}()
	time.Sleep(100 * time.Millisecond)
	release()
	if err := <-got; err != nil {
		t.Fatalf("the waiting land should get the lock once it is released: %v", err)
	}
}

func TestLandLockIsANoOpWithoutALockDir(t *testing.T) {
	t.Setenv("HOMELAB_LAND_LOCK_DIR", filepath.Join(t.TempDir(), "missing"))
	release, err := acquireLandLock("k", "me", time.Second, 10*time.Millisecond)
	if err != nil {
		t.Fatalf("no lock dir (a laptop) means no lock, not an error: %v", err)
	}
	release()
}
