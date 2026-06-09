# Runbook: bump the pinned t3 version (e.g. 0.0.24 → 0.0.25)

t3 on the devvm is **pinned** (`T3_PIN`, default `0.0.24`) and held there by the
`t3-autoupdate` enforcer. t3 is pre-1.0 and ships breaking changes between
builds, so a bump is a **deliberate, verified, reversible** step — never an
auto-update. This runbook makes it calm. Background: post-mortem
`2026-06-09-t3-nightly-autoupdate-auth-outage.md`.

## What a bump actually touches

1. **Pairing API** — t3 renamed `POST /api/auth/bootstrap` → `/api/auth/browser-session`
   in 0.0.25. `t3-dispatch` is now **version-agnostic** (tries `browser-session`,
   falls back to `bootstrap`; see `pairEndpoints` in `scripts/t3-dispatch/main.go`),
   so 0.0.24↔0.0.25 needs **no dispatch change**. If a *future* build renames it
   again, add the new path to `pairEndpoints`, rebuild, redeploy first.
2. **Schema** — 0.0.25+ migrate every `~/.t3/userdata/state.sqlite` **forward**
   (`auth_pairing_links`/`auth_sessions` `role`→`scopes`, `+proof_key_thumbprint`).
   This is a **one-way door**: a binary downgrade alone will NOT roll it back —
   you must restore the DB. Hence the mandatory pre-bump backup below.

## Pre-flight (no downtime)

```bash
# 1. Confirm the dispatch already speaks the new version's pairing API.
#    Install the candidate to an isolated prefix (does NOT touch the global pin):
npm install --prefix /tmp/t3-cand t3@<new>           # e.g. t3@0.0.25
BIN=/tmp/t3-cand/node_modules/.bin/t3; D=$(mktemp -d)
"$BIN" serve --host 127.0.0.1 --port 3796 --base-dir "$D" >/tmp/cand.log 2>&1 &
CRED=$("$BIN" auth pairing create --base-dir "$D" --ttl 5m --json | sed -n 's/.*"credential":"\([^"]*\)".*/\1/p')
#    Try the dispatch's endpoints; one must give 200 + Set-Cookie: t3_session.
for ep in /api/auth/browser-session /api/auth/bootstrap; do
  curl -s -i -X POST -H 'Content-Type: application/json' -d "{\"credential\":\"$CRED\"}" \
    "http://127.0.0.1:3796$ep" | grep -iE 'HTTP/|set-cookie: t3_session'; done
kill %1; rm -rf "$D" /tmp/t3-cand
# If NO endpoint yields a t3_session cookie -> the API changed again; update
# pairEndpoints in main.go + rebuild the dispatch BEFORE proceeding.

# 2. Dispatch unit tests still green:
( cd ~/code/infra/scripts/t3-dispatch && go test ./... )
```

## The bump

```bash
NEW=0.0.25
# 1. PRE-BUMP BACKUP — the rollback safety net. Per user, stop the serve (so the
#    copy is consistent + fast), copy state.sqlite, restart. Do the ACTIVE admin
#    instance last / from OUTSIDE its own t3 session (you can't restart the serve
#    you're running inside).
for u in $(awk -F= '!/^[[:space:]]*#/&&NF==2{gsub(/ /,"",$2);print $2}' /etc/ttyd-user-map | sort -u); do
  src=/home/$u/.t3/userdata/state.sqlite; [ -f "$src" ] || continue
  sudo systemctl stop t3-serve@$u
  sudo install -d -o "$u" -g "$u" -m700 /var/backups/t3-state/$u
  sudo cp -a "$src" /var/backups/t3-state/$u/state-prebump-$NEW-$(date +%Y%m%d-%H%M%S).sqlite
  sudo systemctl start t3-serve@$u
done
# (t3-backup-state also runs daily; this captures a guaranteed snapshot at T-0.)

# 2. Move the pin in BOTH places (keep them in sync):
sed -i "s/T3_PIN:-[0-9.]*/T3_PIN:-$NEW/" ~/code/infra/scripts/t3-autoupdate.sh \
                                          ~/code/infra/scripts/workstation/setup-devvm.sh
sudo install -m0755 ~/code/infra/scripts/t3-autoupdate.sh /usr/local/bin/t3-autoupdate

# 3. Run the enforcer. It installs t3@$NEW, then HEALTH-CHECKS the real pairing
#    handshake (mint -> browser-session/bootstrap -> t3_session). If pairing is
#    broken in $NEW, it AUTO-ROLLS-BACK to the previous version and exits non-zero.
sudo /usr/local/bin/t3-autoupdate    # restarts idle instances; defers active ones

# 4. Restart any instance the enforcer deferred (active agent), when it's idle.
#    The wizard/admin instance: restart from OUTSIDE its own session, or it picks
#    up $NEW on its next natural restart (the unit runs the global /usr/bin/t3).
```

## Verify

```bash
for u in vbarzin emil.barzin ancaelena98; do
  curl -sI -H "X-authentik-username: $u" http://10.0.10.10:3780/ | grep -iE 'HTTP/|set-cookie: t3_session'
done   # each must be 302 + t3_session
t3 --version    # == $NEW
```

## Rollback (if pairing breaks or $NEW misbehaves)

The enforcer auto-rolls-back the **binary** if its health-check fails. But if a
problem surfaces *after* serves migrated their DBs forward, the binary alone
won't fix it — restore the DBs:

```bash
sed -i "s/T3_PIN:-[0-9.]*/T3_PIN:-0.0.24/" ~/code/infra/scripts/t3-autoupdate.sh ~/code/infra/scripts/workstation/setup-devvm.sh
sudo install -m0755 ~/code/infra/scripts/t3-autoupdate.sh /usr/local/bin/t3-autoupdate
sudo npm i -g t3@0.0.24
for u in $(awk -F= '!/^[[:space:]]*#/&&NF==2{gsub(/ /,"",$2);print $2}' /etc/ttyd-user-map | sort -u); do
  bak=$(sudo ls -1t /var/backups/t3-state/$u/state-prebump-* 2>/dev/null | head -1)
  [ -n "$bak" ] || continue
  sudo systemctl stop t3-serve@$u
  sudo install -o "$u" -g "$u" -m600 "$bak" /home/$u/.t3/userdata/state.sqlite
  sudo rm -f /home/$u/.t3/userdata/state.sqlite-wal /home/$u/.t3/userdata/state.sqlite-shm
  sudo systemctl start t3-serve@$u
done
# verify 302 + t3_session as above
```

(The 2026-06-09 incident had no pre-bump backup, so rollback meant per-user
sqlite surgery. With the backup, it's a restore.)
