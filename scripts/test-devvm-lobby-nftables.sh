#!/usr/bin/env bash
# Checks for the devvm's nftables table (playbooks/devvm.yml, task "Filter ttyd
# down to the proxy"), run against a copy of the real ruleset inside throwaway
# network namespaces. Nothing on the box itself is touched.
#
# Run: sudo bash scripts/test-devvm-lobby-nftables.sh
#
# The namespaces stand in for the devvm and its neighbours:
#   host  the devvm: a LAN interface, docker0 and one compose-style br- bridge,
#         with a docker-style DNAT for one published port per bridge
#   lan   a machine on the LAN that is not a Traefik node (10.99.0.2)
#   ctr   a container on docker0, listening on 7681 like the tl-live probe
#   ctr2  a container on a br- bridge, listening on 5432
#
# What it pins down: a port published with `docker run -p` must not be
# reachable from off the box, while containers keep their egress and the box
# keeps reaching its own containers. On 2026-10-02 a leftover container
# published an unauthenticated ttyd on 0.0.0.0:18099 and every pod in the
# cluster could open it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="$DIR/../playbooks/devvm.yml"

if [[ $EUID -ne 0 ]]; then
  echo "needs root for network namespaces: sudo bash $0" >&2
  exit 2
fi

pass=0 fail=0
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

S="rvnft$$"
H="$S-host" L="$S-lan" C="$S-ctr" C2="$S-ctr2"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  for n in "$H" "$L" "$C" "$C2"; do ip netns del "$n" 2>/dev/null; done
  rm -f "${RULES:-}"
}
trap cleanup EXIT

RULES="$(mktemp)"
python3 - "$PLAYBOOK" >"$RULES" <<'EOF' || { echo "could not extract the ruleset" >&2; exit 2; }
import sys, yaml
def walk(tasks):
    for t in tasks or []:
        if t.get("name") == "Filter ttyd down to the proxy":
            return t
        for k in ("block", "rescue", "always"):
            r = walk(t.get(k))
            if r:
                return r
for play in yaml.safe_load(open(sys.argv[1])):
    for k in ("pre_tasks", "tasks", "post_tasks"):
        t = walk(play.get(k))
        if t:
            sys.stdout.write(t["ansible.builtin.copy"]["content"])
            sys.exit(0)
sys.exit(1)
EOF

nsx() { local ns=$1; shift; ip netns exec "$ns" "$@"; }
listen() {  # ns port: accept forever, answer each connection with one line
  ip netns exec "$1" python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(16)
while True:
    c, _ = s.accept(); c.sendall(b"hi\n"); c.close()
' "$2" &
  pids+=($!)
}
reach() { nsx "$1" nc -z -w 2 "$2" "$3" 2>/dev/null; }

for n in "$H" "$L" "$C" "$C2"; do ip netns add "$n"; nsx "$n" ip link set lo up; done

# host <-> lan
ip link add lan0 netns "$H" type veth peer name eth0 netns "$L"
nsx "$H" ip addr add 10.99.0.1/24 dev lan0; nsx "$H" ip link set lan0 up
nsx "$L" ip addr add 10.99.0.2/24 dev eth0; nsx "$L" ip link set eth0 up

# host docker0 <-> ctr, host br-rvtest <-> ctr2
mkbridge() {  # bridge subnet-prefix ctr-ns
  nsx "$H" ip link add "$1" type bridge; nsx "$H" ip addr add "$2.1/24" dev "$1"
  nsx "$H" ip link set "$1" up
  ip link add "v$4" netns "$H" type veth peer name eth0 netns "$3"
  nsx "$H" ip link set "v$4" master "$1" up
  nsx "$3" ip addr add "$2.2/24" dev eth0; nsx "$3" ip link set eth0 up
  nsx "$3" ip route add default via "$2.1"
}
mkbridge docker0 172.31.99 "$C" c1
mkbridge br-rvtest 172.31.98 "$C2" c2
nsx "$H" sysctl -qw net.ipv4.ip_forward=1

# What dockerd installs for `-p 18099:7681` and `-p 55432:5432`: DNAT for
# anything not arriving from the bridge, masquerade for container egress.
nsx "$H" nft -f - <<'EOF'
table ip dockernat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname != "docker0" tcp dport 18099 dnat to 172.31.99.2:7681
    iifname != "br-rvtest" tcp dport 55432 dnat to 172.31.98.2:5432
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 172.31.99.0/24 oifname != "docker0" masquerade
    ip saddr 172.31.98.0/24 oifname != "br-rvtest" masquerade
  }
}
EOF
nsx "$H" nft -f "$RULES" || { echo "FAIL: ruleset does not load"; exit 1; }

listen "$C" 7681
listen "$C2" 5432
listen "$L" 9000
listen "$H" 7681   # ttyd itself
listen "$H" 2022   # any other host port
sleep 0.5  # listeners binding; the reach() checks below retry nothing

# Published container ports stay on the box.
no "lan reaches a docker0 container through its published port" reach "$L" 10.99.0.1 18099
no "lan reaches a br- container through its published port" reach "$L" 10.99.0.1 55432

# What must keep working.
ok "the box reaches its docker0 container directly" reach "$H" 172.31.99.2 7681
ok "the box reaches its br- container directly" reach "$H" 172.31.98.2 5432
ok "a docker0 container reaches the LAN" reach "$C" 10.99.0.2 9000
ok "a br- container reaches the LAN" reach "$C2" 10.99.0.2 9000
ok "lan reaches a host port the table does not name" reach "$L" 10.99.0.1 2022

# The rules that were there before.
no "lan (not a Traefik node) reaches ttyd" reach "$L" 10.99.0.1 7681

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
