#!/usr/bin/env bash
# Regression tests for the agent-api tailnet leg in playbooks/devvm.yml
# (section 15). Pure bash plus the pyyaml already on the box; no root, no
# Docker, and it never talks to Headscale, Vault or the live tailscaled.
#
# Three defects are pinned here, all found reviewing 3b4aaf55:
#   1. the Headscale pre-auth key was passed on the argv of `tailscale up`,
#      readable from /proc by every account on this shared box;
#   2. the "Wait for the node to reach Running" until-condition parsed stdout
#      as JSON with no rc guard, so an empty stdout aborted the play on the
#      first attempt instead of retrying;
#   3. /var/log/agent-api was world-readable, exposing verbatim prompts.
#
# The tests marked "behavioural" run ansible for real against a temp dir, so
# they measure what the construct does rather than re-reading the YAML they
# are meant to police. In particular test 2 drives the playbook's OWN until
# expression, extracted from the file at run time.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
PLAYBOOK="$HERE/playbooks/devvm.yml"

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Walks every play, block, rescue and always list, so a task nested in the
# registration block is found the same as a top-level one.
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

doc = yaml.safe_load(open(sys.argv[1]))
mode = sys.argv[2]

if mode == "task":
    want = sys.argv[3]
    hits = [n for n in walk(doc) if n.get("name") == want and "block" not in n]
    if len(hits) != 1:
        sys.exit("expected exactly 1 task named %r, found %d" % (want, len(hits)))
    print(json.dumps(hits[0]))
elif mode == "always-removes-key":
    # The key file must be removed by an `always`, not by a trailing task: a
    # trailing task does not run when registration fails, which is exactly
    # when a live key must not be left on disk. Checked by matching the path
    # against the dest the copy task wrote, so a rename of either one cannot
    # quietly decouple them.
    dests = set()
    for node in walk(doc):
        if node.get("name") == "Write the pre-auth key to a private file":
            c = node.get("ansible.builtin.copy") or node.get("copy") or {}
            if c.get("dest"):
                dests.add(c["dest"].strip())
    removed = set()
    for node in walk(doc):
        for task in node.get("always") or []:
            f = task.get("ansible.builtin.file") or task.get("file") or {}
            if f.get("state") == "absent" and f.get("path"):
                removed.add(f["path"].strip())
    print("yes" if dests and dests <= removed else "no")
PY

task_json() { python3 "$TMP/walk.py" "$PLAYBOOK" task "$1"; }
jqf() { printf '%s' "$1" | jq -r "$2"; }

# Everything from the section-15 banner to the handlers block, as text, for the
# assertions about what the section must never contain anywhere in it.
section15="$(awk '/^    # ---- 15\) the agent-api tailnet leg/,/^  handlers:/' "$PLAYBOOK")"
ok test -n "$section15"

n=0
run_play() { # run_play <playbook> -> $TMP/out.<n>; sets OUT and returns ansible's rc
  n=$((n+1)); OUT="$TMP/out.$n"
  ( cd "$TMP" && TMP_DIR="$TMP" timeout 180 ansible-playbook -i localhost, -c local "$1" ) \
    >"$OUT" 2>&1
}

echo "== finding 1: the pre-auth key must never reach argv =="

if REG="$(task_json 'Register with Headscale')"; then
  REG_CMD="$(jqf "$REG" '.["ansible.builtin.command"] // .command // ""')"

  # 1a. The registration command line must not interpolate the Vault secret.
  # `no_log` hides Ansible's copy of the line, not the kernel's
  # /proc/<pid>/cmdline, which is world-readable here (no hidepid).
  notok grep -q 'devvm_ts_preauth.stdout' <<<"$REG_CMD"

  # 1b. The supported indirection, from the installed tailscale's own help:
  #   --auth-key value  node authorization key; if it begins with "file:",
  #                     then it's a path to a file containing the authkey
  ok grep -qE -- '--auth-key[[:space:]]+file:' <<<"$REG_CMD"
else
  bad "cannot read the 'Register with Headscale' task"
fi

# No task anywhere in the section may put a bare template after --auth-key.
notok grep -qE -- '--auth-key[[:space:]]+\{\{' <<<"$section15"

if KEYFILE="$(task_json 'Write the pre-auth key to a private file')"; then
  ok test "$(jqf "$KEYFILE" '.["ansible.builtin.copy"].mode // ""')" = "0600"
  ok test -n "$(jqf "$KEYFILE" '.["ansible.builtin.copy"].owner // ""')"
  ok test "$(jqf "$KEYFILE" '.no_log // false')" = "true"
else
  bad "no task writes the pre-auth key to a private file"
fi

ok test "$(python3 "$TMP/walk.py" "$PLAYBOOK" always-removes-key)" = "yes"

# 1c. Behavioural: the key file is gone even when registration FAILS.
cat >"$TMP/keyfile.yml" <<'YML'
- hosts: localhost
  gather_facts: false
  vars:
    keyfile: "{{ lookup('env', 'TMP_DIR') }}/preauth.key"
  tasks:
    - block:
        - name: Write the pre-auth key to a private file
          ansible.builtin.copy:
            dest: "{{ keyfile }}"
            content: "tskey-auth-PRETEND"
            mode: "0600"
        - name: Register with Headscale
          ansible.builtin.command: /bin/sh -c 'exit 7'
      always:
        - name: Remove the pre-auth key file
          ansible.builtin.file:
            path: "{{ keyfile }}"
            state: absent
      ignore_errors: true
YML
run_play keyfile.yml
notok test -e "$TMP/preauth.key"
ok grep -q 'non-zero return code' "$OUT"

echo "== finding 2: the Running wait must retry, not explode, on empty stdout =="

# A tailscaled that has just hit Restart=on-failure: `tailscale status --json`
# exits 1 with EMPTY stdout and the error on stderr (verified against 1.98.3).
# Fails that way FAIL_UNTIL times, then returns a Running document.
cat >"$TMP/probe.sh" <<'SH'
#!/bin/sh
c="$TMP_DIR/attempts"
n=$(cat "$c" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$c"
if [ "$n" -le "${FAIL_UNTIL:-2}" ]; then
  echo 'failed to connect to local tailscaled' >&2
  exit 1
fi
printf '{"BackendState":"Running"}'
SH
chmod 0755 "$TMP/probe.sh"

if WAIT="$(task_json 'Wait for the node to reach Running')"; then
  WAIT_UNTIL="$(jqf "$WAIT" '.until // ""')"
  ok test -n "$WAIT_UNTIL"
  # The guard the sibling "Parse the tailnet login state" task already carries.
  ok grep -q 'rc == 0' <<<"$WAIT_UNTIL"

  # Generate a play that uses the playbook's real until expression verbatim.
  python3 - "$WAIT_UNTIL" "$TMP/until.yml" <<'PY'
import sys, yaml
until, dest = sys.argv[1], sys.argv[2]
play = [{
    "hosts": "localhost",
    "gather_facts": False,
    "tasks": [
        {"name": "Wait for the node to reach Running",
         "ansible.builtin.command": "{{ lookup('env', 'TMP_DIR') }}/probe.sh",
         "register": "devvm_ts_wait",
         "until": until,
         "retries": 5,
         "delay": 0,
         "changed_when": False},
        {"ansible.builtin.debug": {
            "msg": "attempts={{ devvm_ts_wait.attempts | default(0) }}"}},
    ],
}]
yaml.safe_dump(play, open(dest, "w"), default_flow_style=False, sort_keys=False)
PY

  # Two transient failures, then Running: must retry and succeed.
  rm -f "$TMP/attempts"
  run_play until.yml; rc_until=$?
  ok test "$rc_until" -eq 0
  notok grep -q 'Expecting value: line 1 column 1' "$OUT"
  notok grep -q 'Unexpected failure during module execution' "$OUT"
  ok grep -q 'attempts=3' "$OUT"
  ok test "$(cat "$TMP/attempts" 2>/dev/null || echo 0)" -eq 3

  # A daemon that never returns must still fail the play: the retry budget is
  # a tolerance for a slow start, not a free pass. And it must burn all of it,
  # which is the part the unguarded expression skipped.
  rm -f "$TMP/attempts"
  FAIL_UNTIL=99 run_play until.yml; rc_never=$?
  notok test "$rc_never" -eq 0
  notok grep -q 'Expecting value: line 1 column 1' "$OUT"
  ok test "$(cat "$TMP/attempts" 2>/dev/null || echo 0)" -eq 6   # 1 try + 5 retries
else
  bad "cannot read the 'Wait for the node to reach Running' task"
fi

echo "== finding 3: the trace directory must not be world-readable =="

if LOGDIR="$(task_json 'Create the agent-api log directory')"; then
  LOGDIR_MODE="$(jqf "$LOGDIR" '.["ansible.builtin.file"].mode // ""')"
  ok test -n "$LOGDIR_MODE"
  bits=$(( 8#${LOGDIR_MODE#0} ))

  # 3a. No world bits at all. The trace holds Muse's verbatim request and a
  # full replay of the run, and ancamilea, emo and breakglass have shells here.
  ok test "$(( bits & 8#007 ))" -eq 0
  ok test "$(( bits & 8#020 ))" -eq 0   # no group write either

  # 3b. Behavioural: create the directory with the mode the playbook declares,
  # then confirm a 0644 file inside is unreachable to another account anyway.
  # The directory mode is what this commit controls; the trace file's own mode
  # is agent-api's to pick, so the directory has to be what closes it.
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
