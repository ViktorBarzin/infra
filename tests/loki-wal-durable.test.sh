#!/usr/bin/env bash
# Static checks on the Loki Helm values: the ingester WAL must survive a pod
# replacement, and low-volume streams must not sit unflushed in memory for
# most of a day.
#
# Why: until 2026-10-02 the WAL lived on an emptyDir (medium: Memory) and
# max_chunk_age was 24h. A stream that writes a few lines a minute never goes
# idle for chunk_idle_period and never fills a chunk, so it is only flushed at
# max_chunk_age. When loki-0 was replaced at 11:19:40 that day, the WAL went
# with the pod and Loki lost ~9h of agent-api.service, agent-api-trace and
# tmux-api.service lines that the devvm journal still held.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VALUES="$HERE/stacks/monitoring/modules/monitoring/loki.yaml"

python3 - "$VALUES" <<'PY'
import re, sys, yaml

values = yaml.safe_load(open(sys.argv[1]))
loki = values["loki"]
sb = values["singleBinary"]  # pod-level settings: persistence, extra volumes
fails = []

def dur_seconds(s):
    total = 0
    for n, unit in re.findall(r"(\d+)([hms])", str(s)):
        total += int(n) * {"h": 3600, "m": 60, "s": 1}[unit]
    return total

wal_dir = loki["ingester"]["wal"]["dir"].rstrip("/")

# 1. The WAL dir sits on the persistent volume the chart mounts at /var/loki.
if not sb.get("persistence", {}).get("enabled"):
    fails.append("singleBinary.persistence.enabled is not true")
if not (wal_dir + "/").startswith("/var/loki/"):
    fails.append(f"ingester WAL dir {wal_dir} is not under the /var/loki PVC")

# 2. No extra volume shadows the WAL dir (an emptyDir mounted over it would
#    bring the original problem back while still passing check 1).
mounts = {m["mountPath"].rstrip("/"): m["name"] for m in sb.get("extraVolumeMounts", [])}
vols = {v["name"]: v for v in sb.get("extraVolumes", [])}
for path, name in mounts.items():
    if wal_dir == path or wal_dir.startswith(path + "/"):
        if "emptyDir" in vols.get(name, {}):
            fails.append(f"WAL dir {wal_dir} is shadowed by emptyDir volume '{name}' at {path}")

# 3. max_chunk_age bounds how long a never-idle, low-volume stream stays in
#    memory only. Upstream default is 2h.
age = dur_seconds(loki["ingester"].get("max_chunk_age", "2h"))
if age > 2 * 3600:
    fails.append(f"max_chunk_age is {age}s, above 2h")

# 4. Replaying a WAL must not push the pod past its memory limit.
ceiling = str(loki["ingester"]["wal"].get("replay_memory_ceiling", ""))
if not ceiling:
    fails.append("ingester.wal.replay_memory_ceiling is unset (default 4GB)")

for f in fails:
    print("FAIL:", f)
print(f"loki-wal-durable: {len(fails)} failed")
sys.exit(1 if fails else 0)
PY
