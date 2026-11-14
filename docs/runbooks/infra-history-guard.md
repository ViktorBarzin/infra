# Runbook: the infra history guard on Forgejo

**Repo:** Forgejo `viktor/infra`, push-mirrored to GitHub `ViktorBarzin/infra` (both public)
**Hook:** `/data/git/repositories/viktor/infra.git/hooks/pre-receive.d/zz-history-guard` in the Forgejo pod
**Commit map:** `~wizard/.local/share/infra-history-rewrite-2026-11-14/commit-map` on the devvm (old SHA, new SHA)

## What it is

On 2026-11-14 the history of this repo was rewritten to remove personal data
and two device passwords that had been committed to
`docs/runbooks/cameras-nvr-intercom.md`, plus personal details in some commit
messages. Every commit after 2026-09-03 got a new SHA. The file tree of master
did not change.

A clone made before the rewrite still holds the old history. If it pushes, the
old history comes back to Forgejo and the push mirror copies it to GitHub. The
guard hook refuses that push. Forgejo runs every executable in
`pre-receive.d/`, so the hook sits beside Forgejo's own `gitea` hook. It is
not in Terraform: it lives on the Forgejo data volume.

Two marker files in the bare repo switch it:

| File | Effect |
|---|---|
| `REWRITE_GUARD` | refuse any push whose new commit descends from `1af35deb23b9d3ae1d3d1c2d3a40fc134ae43aa7`, the first rewritten commit in the old history |
| `REWRITE_FREEZE` | refuse every push except the `<ref> <sha>` lines in `REWRITE_ALLOW` (used only during a rewrite) |

`REWRITE_GUARD` is on. The hook source is the heredoc below.

## A push is refused with "carries the history from before 2026-11-14"

The clone is on the old history. Move it, do not force anything:

1. `git fetch --prune` from Forgejo.
2. For each local branch, look up its SHA in the commit map and point the
   branch at the new SHA with `git update-ref refs/heads/<b> <new> <old>`.
   A commit that is not in the map is local work: replay it onto the mapped
   parent with `git cherry-pick`.
3. `git reflog expire --expire=now --all` and `git gc --prune=now`, so the old
   objects leave the clone too.

## After a Forgejo restore or rebuild

Backups made before 2026-11-14 (PVC snapshots, NFS copies, the offsite copy)
hold the old history. After restoring `viktor/infra` from one of them:

1. Run the rewrite again on a `git clone --mirror` of the restored repo, with
   the same filter (`git filter-repo --file-info-callback`, replacing every
   version of the Vermont runbook with the current one, plus the commit-message
   map). The result must match the commit map above.
2. Reinstall the hook and `touch REWRITE_GUARD`, as the `git` user:

```sh
P=$(kubectl -n forgejo get pods -o name | grep 'pod/forgejo-' | head -1 | cut -d/ -f2)
kubectl -n forgejo cp zz-history-guard $P:/tmp/zz-history-guard -c forgejo
kubectl -n forgejo exec $P -c forgejo -- su git -s /bin/sh -c \
  'R=/data/git/repositories/viktor/infra.git; install -m 755 /tmp/zz-history-guard $R/hooks/pre-receive.d/; touch $R/REWRITE_GUARD'
```

## What the rewrite did not reach

- GitHub keeps the old commits readable by SHA until its own garbage collection
  removes them; no purge was requested.
- Clones and forks made before the rewrite, and the Forgejo activity feed,
  Woodpecker pipeline pages and Slack notices that quote old commit messages.
- 21 closed PRs whose refs reached the old history lost their refs, so their
  "Files changed" pages are empty.

## Hook source

```bash
#!/usr/bin/env bash
R="${GIT_DIR:-.}"
OLD=1af35deb23b9d3ae1d3d1c2d3a40fc134ae43aa7
Z=0000000000000000000000000000000000000000
while read -r old new ref; do
  if [ -f "$R/REWRITE_FREEZE" ] && ! grep -qxF "$ref $new" "$R/REWRITE_ALLOW" 2>/dev/null; then
    echo "infra: the repo history is being rewritten; this push is refused. Retry in an hour." >&2
    exit 1
  fi
  if [ -f "$R/REWRITE_GUARD" ] && [ "$new" != "$Z" ] && git merge-base --is-ancestor "$OLD" "$new" 2>/dev/null; then
    echo "infra: this push carries the history from before 2026-11-14, which was rewritten. See docs/runbooks/infra-history-guard.md." >&2
    exit 1
  fi
done
exit 0
```
