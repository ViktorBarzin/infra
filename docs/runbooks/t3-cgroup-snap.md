# t3-cgroup-snap — diagnostic snapshotter for t3-serve cgroups

**What:** `t3-cgroup-snap.service` on the devvm samples every process in every
`t3-serve@<user>` cgroup every 5 s and appends one JSONL line per (snapshot,
pid) to `/var/log/t3-cgroup-snap.jsonl` (rotated at 50 MiB × 3 = 150 MiB max).
Diagnostic only, deployed 2026-07-09 to identify the recurring 5-7 GiB
`Comm='2.1.205'` OOM victim in `t3-serve@wizard`. **Removed in the same PR
that lands the eventual mitigation** — this is not permanent infrastructure.
Design: `../plans/2026-07-09-t3-cgroup-snap-design.md`.

## Look up the last OOM's identity

```bash
# 1. When + who did the kernel kill?
sudo journalctl -k --since -24h --no-pager | grep -B1 "Killed process"
# -> ... "Killed process 2544629 (2.1.205)..." at 22:26:44

# 2. What was that PID actually running (last snapshot before the kill)?
jq -c 'select(.pid==2544629)' /var/log/t3-cgroup-snap.jsonl* | tail -1
# -> full argv; identifies the tool.

# 3. Who launched it? (if the target's argv is unhelpful, e.g. a python subprocess)
PPID=$(jq -r 'select(.pid==2544629) | .ppid' /var/log/t3-cgroup-snap.jsonl* | tail -1)
jq -c "select(.pid==$PPID)" /var/log/t3-cgroup-snap.jsonl* | tail -1

# 4. Top-N heaviest processes in wizard's cgroup at the moment of the kill:
jq -c 'select(.user=="wizard" and .ts>="2026-07-09T22:26:35Z" and .ts<="2026-07-09T22:26:45Z")' \
   /var/log/t3-cgroup-snap.jsonl* \
  | jq -sr 'sort_by(.rss_kb)|reverse|.[:10][]|"\(.rss_kb) \(.comm) \(.argv[:80])"'
```

## Health

Silent = suspicious. Baseline: one line per active PID per 5 s. A single
`t3-serve@wizard` with 5 running processes ≈ 60 lines/min.

```bash
systemctl status t3-cgroup-snap.service --no-pager       # active (running)
tail -3 /var/log/t3-cgroup-snap.jsonl | jq .              # freshest lines parseable
du -shc /var/log/t3-cgroup-snap.jsonl*                    # ≤ 150 MiB total
```

If the service dies: `Restart=on-failure` brings it back within 15 s. If it
loops-restarting: `journalctl -u t3-cgroup-snap -n 50` shows the bash error.

## Retire (when the mitigation lands)

Same commit that adds the mitigation should:

```bash
sudo systemctl disable --now t3-cgroup-snap.service
sudo rm -f /var/log/t3-cgroup-snap.jsonl*
sudo rm -f /etc/systemd/system/t3-cgroup-snap.service /usr/local/bin/t3-cgroup-snap
sudo systemctl daemon-reload
```

… and the corresponding source removal from the infra repo:
`scripts/t3-cgroup-snap.*`, `tests/t3-cgroup-snap.test.sh`, unwire from
`scripts/workstation/setup-devvm.sh` §9a and §9d, this runbook, and the
post-mortem addendum pointer.
