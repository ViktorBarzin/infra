#!/usr/bin/env bash
# Consistent online backup of each t3 user's ~/.t3 state.sqlite (chat/session
# history AND auth tables). ~/.t3 lives on the devvm local disk — NOT a K8s PVC and
# NOT in the 3-2-1 pipeline — so without this it is the only copy and a rebuild
# loses it. It also makes a t3 version bump REVERSIBLE: 0.0.25+ migrate the schema
# FORWARD (a one-way door), so a clean pre-bump backup turns rollback into a restore
# instead of per-user sqlite surgery (see runbooks/t3-version-bump.md). Runs as root
# via t3-backup-state.timer; the per-user .backup runs AS the owning user so the live
# WAL/-shm files keep their owner and the running t3-serve is never perturbed.
set -uo pipefail
DEST="${T3_BACKUP_DEST:-/var/backups/t3-state}"
# 6 (was 14): wizard's state.sqlite grew to ~1.1GB, and the gated nightly tracker
# adds a pre-bump snapshot per bump on top of this daily one — 14 x ~1.1GB would
# fill the devvm root fs. 6 is ample (rollback only ever needs the most recent
# pre-bump backup). Bump per user via T3_BACKUP_KEEP if a DB is small.
KEEP="${T3_BACKUP_KEEP:-6}"
MAP=/etc/ttyd-user-map
LOG() { logger -t t3-backup-state "$*"; echo "t3-backup-state: $*"; }

ts=$(date +%Y%m%d-%H%M%S)
# RHS of each non-comment "authentik=os_user" line = an OS user owning a ~/.t3.
mapfile -t users < <(awk -F= '!/^[[:space:]]*#/ && NF==2 { gsub(/[[:space:]]/,"",$2); print $2 }' "$MAP" 2>/dev/null | sort -u)
[[ ${#users[@]} -gt 0 ]] || { LOG "no users in $MAP; nothing to back up"; exit 0; }

rc=0
for u in "${users[@]}"; do
  src="/home/$u/.t3/userdata/state.sqlite"
  if [[ ! -f "$src" ]]; then LOG "skip $u (no state.sqlite)"; continue; fi
  out="$DEST/$u"; dst="$out/state-$ts.sqlite"
  install -d -o "$u" -g "$u" -m 0700 "$out"
  # VACUUM INTO takes a consistent read-snapshot copy — unlike .backup it does NOT
  # restart when the source is written mid-copy, so it finishes in a single pass even
  # for the actively-used instance (the admin's own live session, which .backup would
  # loop on forever). Run as the owning user so WAL access keeps the live serve happy.
  # timeout caps a pathologically-slow copy (huge DB + concurrent writes on a contended
  # disk) so the daily run can never wedge — it just logs + retries next cycle. The
  # daily 03:30 slot normally finds instances idle, where even a large DB copies fast.
  if runuser -u "$u" -- timeout "${T3_BACKUP_TIMEOUT:-900}" sqlite3 "$src" "VACUUM INTO '$dst'" 2>/dev/null && [[ -s "$dst" ]]; then
    LOG "backed up $u -> $dst ($(stat -c%s "$dst" 2>/dev/null) bytes)"
  else
    LOG "WARN: backup FAILED for $u ($src)"; rc=1; rm -f "$dst"
  fi
  # retention: keep newest $KEEP per user
  ls -1t "$out"/state-*.sqlite 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
done
LOG "done (rc=$rc)"
exit $rc
