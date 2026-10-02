#!/usr/bin/env bash
# Checks which namespaces can reach the devvm Lobby ports through the
# AdminNetworkPolicies in stacks/terminal/devvm_lobby_anp.tf.
#
# That file holds only locals, so `terraform console` evaluates it without
# providers, state or credentials. A small model of ANP evaluation (lowest
# priority number first, first matching rule wins, no match falls through to
# allow) then answers "can namespace N reach 10.0.10.10:P" for every Lobby port
# and compares it with the runbook (docs/runbooks/terminal-api.md):
#   traefik    reaches every port (it is the proxy);
#   monitoring reaches only 7684 (Prometheus scrapes tmux-api);
#   headscale  reaches only 7681 (the subnet-router probe checks ttyd);
#   any other namespace reaches none.
# Found 2026-10-02: one policy covered monitoring and headscale together, so
# each reached both 7681 and 7684, and a monitoring pod got a ttyd token.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/stacks/terminal/devvm_lobby_anp.tf"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$SRC" "$TMP/" || { echo "FAIL: cannot copy $SRC"; exit 1; }
if ! (cd "$TMP" && echo 'jsonencode(local.devvm_lobby_anps)' | terraform console >"$TMP/out" 2>"$TMP/err"); then
  echo "FAIL: terraform console could not evaluate $SRC (it must hold only locals)"; cat "$TMP/err"; exit 1
fi

python3 - "$TMP/out" <<'PY'
import json, sys

anps = json.loads(json.loads(open(sys.argv[1]).read()))
DEVVM = "10.0.10.10/32"
PORTS = [7681, 7683, 7684, 7685, 7686, 7687, 7688, 8710]
EXPECT = {
    "traefik": set(PORTS),
    "monitoring": {7684},
    "headscale": {7681},
    "default": set(),
    "woodpecker": set(),
    "kube-system": set(),
}
failures = []

def subject_matches(subject, ns):
    exprs = subject["namespaces"]["matchExpressions"]
    for e in exprs:
        if e["key"] != "kubernetes.io/metadata.name":
            raise ValueError(f"unsupported key {e['key']}")
        if e["operator"] == "In" and ns not in e["values"]:
            return False
        if e["operator"] == "NotIn" and ns in e["values"]:
            return False
        if e["operator"] not in ("In", "NotIn"):
            raise ValueError(f"unsupported operator {e['operator']}")
    return True

def port_matches(ports, port):
    for p in ports:
        if "portNumber" in p and p["portNumber"]["port"] == port:
            return True
        if "portRange" in p and p["portRange"]["start"] <= port <= p["portRange"]["end"]:
            return True
    return False

def reachable(ns, port):
    for name, spec in sorted(anps.items(), key=lambda kv: kv[1]["priority"]):
        if not subject_matches(spec["subject"], ns):
            continue
        for rule in spec.get("egress", []):
            nets = [n for peer in rule["to"] for n in peer.get("networks", [])]
            if DEVVM in nets and port_matches(rule["ports"], port):
                if rule["action"] == "Allow":
                    return True
                if rule["action"] == "Deny":
                    return False
                if rule["action"] == "Pass":
                    return True  # no namespace NetworkPolicy targets 10.0.10.10
    return True

# Two policies at one priority are undefined behaviour in the ANP API.
prios = [s["priority"] for s in anps.values()]
if len(prios) != len(set(prios)):
    failures.append(f"duplicate ANP priorities {sorted(prios)}")

for ns, want in EXPECT.items():
    got = {p for p in PORTS if reachable(ns, p)}
    if got != want:
        failures.append(f"{ns}: reaches {sorted(got)}, want {sorted(want)}")

for f in failures:
    print("FAIL:", f)
print(f"{len(EXPECT) + 1 - len(failures)} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
PY
