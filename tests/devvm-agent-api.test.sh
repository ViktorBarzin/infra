#!/usr/bin/env bash
# Regression tests for agent-api's section of playbooks/devvm.yml (section
# 15). Pure bash plus the pyyaml already on the box; no root, no Docker, and it
# never talks to Headscale, Vault or a live tailscaled.
#
# Two things are pinned here:
#   1. the retired tailnet leg stays retired (2026-10-02, design
#      docs/plans/2026-10-02-muse-homelab-integration-design.md): nothing
#      installs, starts or serves through the wizard userspace tailscaled, the
#      retirement tasks remove it without touching emo's separate daemon, and
#      agent-api keeps its loopback + 10.0.10.10 bind for terminal-api;
#   2. /var/log/agent-api is not world-readable, since the trace holds
#      verbatim prompts (found reviewing 3b4aaf55).
#
# The earlier version of this file (devvm-agent-tailnet.test.sh) also pinned
# the pre-auth key handling and the Running wait of the registration block.
# Those tasks are gone with the leg, so their tests went with them; git log
# has both if the leg ever comes back.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
PLAYBOOK="$HERE/playbooks/devvm.yml"

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Walks every play, block, rescue and always list, so a nested task is found
# the same as a top-level one. Each mode prints one answer for the shell side.
cat >"$TMP/walk.py" <<'PY'
import json, sys, yaml

def walk(node):
    if isinstance(node, list):
        for item in node:
            yield from walk(item)
    elif isinstance(node, dict):
        yield node
        for key in ("tasks", "block", "rescue", "always", "handlers",
                    "pre_tasks", "post_tasks"):
            if key in node:
                yield from walk(node[key])

def tasks(doc):
    # Handlers excluded: a task is something that runs on every apply.
    for play in doc:
        for key in ("pre_tasks", "tasks", "post_tasks"):
            yield from walk(play.get(key) or [])

def module(task, *names):
    for n in names:
        for k in (n, "ansible.builtin." + n):
            if k in task:
                return task[k]
    return None

doc = yaml.safe_load(open(sys.argv[1]))
mode = sys.argv[2]
UNIT = "tailscaled-agent.service"

if mode == "task":
    want = sys.argv[3]
    hits = [n for n in walk(doc) if n.get("name") == want and "block" not in n]
    if len(hits) != 1:
        sys.exit("expected exactly 1 task named %r, found %d" % (want, len(hits)))
    print(json.dumps(hits[0]))

elif mode == "starts-unit":
    # Anything that would bring the retired daemon back: its unit installed,
    # or a systemd task that starts, restarts or enables it.
    hits = []
    for t in tasks(doc):
        tpl = module(t, "template", "copy") or {}
        if isinstance(tpl, dict) and UNIT in str(tpl.get("dest", "")):
            hits.append(t.get("name"))
        sd = module(t, "systemd_service", "systemd", "service") or {}
        if isinstance(sd, dict) and UNIT in str(sd.get("name", "")):
            if sd.get("state") in ("started", "restarted", "reloaded") or sd.get("enabled") is True:
                hits.append(t.get("name"))
    print("\n".join(str(h) for h in hits))

elif mode == "stops-unit":
    # The retirement: a systemd task that leaves the unit stopped AND disabled.
    hits = [t.get("name") for t in tasks(doc)
            if isinstance(module(t, "systemd_service", "systemd"), dict)
            and UNIT in str(module(t, "systemd_service", "systemd").get("name", ""))
            and module(t, "systemd_service", "systemd").get("state") == "stopped"
            and module(t, "systemd_service", "systemd").get("enabled") is False]
    print("yes" if hits else "no")

elif mode == "absent-paths":
    # Every path a file task removes, one per line.
    for t in tasks(doc):
        f = module(t, "file") or {}
        if isinstance(f, dict) and f.get("state") == "absent" and f.get("path"):
            print(str(f["path"]).strip())

elif mode == "commands":
    # Every command/shell line a task runs, one per line.
    for t in tasks(doc):
        c = module(t, "command", "shell")
        if isinstance(c, dict):
            c = c.get("cmd") or c.get("argv")
        if c:
            print(" ".join(c) if isinstance(c, list) else str(c).replace("\n", " "))

elif mode == "dangling-notify":
    # A notify naming no handler fails the play at the moment the task
    # changes, which is the worst moment to find out.
    names = set()
    for play in doc:
        for h in play.get("handlers") or []:
            names.add(h.get("name"))
            listen = h.get("listen")
            if listen:
                names.update(listen if isinstance(listen, list) else [listen])
    missing = set()
    for t in tasks(doc):
        n = t.get("notify")
        for x in (n if isinstance(n, list) else [n] if n else []):
            if x not in names:
                missing.add(x)
    print("\n".join(sorted(missing)))
PY

walk() { python3 "$TMP/walk.py" "$PLAYBOOK" "$@"; }
task_json() { walk task "$1"; }
jqf() { printf '%s' "$1" | jq -r "$2"; }

n=0
run_play() { # run_play <playbook> -> $TMP/out.<n>; sets OUT and returns ansible's rc
  n=$((n+1)); OUT="$TMP/out.$n"
  ( cd "$TMP" && TMP_DIR="$TMP" timeout 180 ansible-playbook -i localhost, -c local "$1" ) \
    >"$OUT" 2>&1
}

echo "== retirement: the wizard tailnet leg stays gone =="

# Nothing installs, enables or (re)starts tailscaled-agent any more.
starts="$(walk starts-unit)"
ok test -z "$starts"
[ -n "$starts" ] && echo "  still starting it: $starts"

# And something takes it down on the live box, which has it running.
ok test "$(walk stops-unit)" = "yes"

absent="$(walk absent-paths)"
# The unit file goes, so systemd forgets it after the reload.
ok grep -qx '/etc/systemd/system/tailscaled-agent.service' <<<"$absent"
# The node's state (node key, serve config) goes, under the ADMIN account.
ok grep -qE '^/home/(\{\{ *devvm_admin_user *\}\}|wizard)/\.tailscale-us$' <<<"$absent"
# emo's userspace tailscaled lives in /home/emo/.tailscale-us and is not this
# playbook's to remove; no removed path may name emo or a templated user that
# could resolve to anyone else.
notok grep -qE 'emo|devvm_users|item' <<<"$(grep 'tailscale' <<<"$absent")"

cmds="$(walk commands)"
# No `tailscale serve` (the :8710 forward) and no registration left behind.
notok grep -qE 'tailscale .*serve' <<<"$cmds"
notok grep -qE 'tailscale .* up( |$)' <<<"$cmds"
# Nothing reads the node's tailnet address any more; TL_AGENT_BIND never used
# it, so a stale read would only fail the play on a box with no node.
notok grep -q 'devvm_tailscale_ip' "$PLAYBOOK"
notok grep -qE 'tailscale .* ip -4' <<<"$cmds"

# The package stays: emo's daemon runs /usr/sbin/tailscaled from it.
if PKG="$(task_json 'Install tailscale')"; then
  ok test "$(jqf "$PKG" '.["ansible.builtin.apt"].name // ""')" = "tailscale"
  ok test "$(jqf "$PKG" '.["ansible.builtin.apt"].state // ""')" = "present"
else
  bad "the tailscale package task is gone; emo's userspace daemon needs the binary"
fi

# The handler for the retired unit is gone, and no notify dangles.
notok grep -q 'restart tailscaled-agent' "$PLAYBOOK"
ok test -z "$(walk dangling-notify)"

echo "== agent-api still binds loopback + the LAN address for terminal-api =="
if CONF="$(task_json 'Make the lobby services demand the proxy secret')"; then
  CONTENT="$(jqf "$CONF" '.["ansible.builtin.copy"].content // ""')"
  ok grep -qx 'TL_AGENT_BIND=10.0.10.10' <<<"$CONTENT"
  ok grep -q '^TL_BEARER_TOKENS=' <<<"$CONTENT"
else
  bad "cannot read the lobby local.conf task"
fi

echo "== the trace directory must not be world-readable =="

if LOGDIR="$(task_json 'Create the agent-api log directory')"; then
  LOGDIR_MODE="$(jqf "$LOGDIR" '.["ansible.builtin.file"].mode // ""')"
  ok test -n "$LOGDIR_MODE"
  bits=$(( 8#${LOGDIR_MODE#0} ))

  # No world bits at all. The trace holds Muse's verbatim request and a full
  # replay of the run, and ancamilea, emo and breakglass have shells here.
  ok test "$(( bits & 8#007 ))" -eq 0
  ok test "$(( bits & 8#020 ))" -eq 0   # no group write either

  # Behavioural: create the directory with the mode the playbook declares,
  # then confirm a 0644 file inside is unreachable to another account anyway.
  # The directory mode is what the playbook controls; the trace file's own
  # mode is agent-api's to pick, so the directory has to be what closes it.
  cat >"$TMP/logdir.yml" <<YML
- hosts: localhost
  gather_facts: false
  tasks:
    - name: Create the agent-api log directory
      ansible.builtin.file:
        path: "$TMP/agent-api"
        state: directory
        mode: "$LOGDIR_MODE"
YML
  run_play logdir.yml
  ok test -d "$TMP/agent-api"
  actual="$(stat -c '%a' "$TMP/agent-api" 2>/dev/null || echo 777)"
  ok test "$(( 8#$actual & 8#007 ))" -eq 0
  : >"$TMP/agent-api/trace.jsonl"; chmod 0644 "$TMP/agent-api/trace.jsonl"
  # No execute bit for other means the 0644 trace cannot be reached by path.
  ok test "$(( 8#$actual & 8#001 ))" -eq 0
else
  bad "cannot read the 'Create the agent-api log directory' task"
fi

echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
