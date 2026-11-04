#!/usr/bin/env bash
# Wake the London projector and get adb attached to it.
#
# Since 2026-10-31 its energy mode is "Increased", which keeps Wi-Fi up in
# standby: ping and adb answer with the lamp off, and KEYCODE_WAKEUP over adb
# turns the screen on. Before that, in the "Low" mode, standby looked exactly
# like a broken route: no ping and no tcp/5555 from here OR from the Flint 2
# router on its own LAN, while that router still held a DHCP lease and an ARP
# entry. The wake-on-LAN and layer-2 branches below still cover a set that was
# shut down or lost its radio. Every detail is in the tv repo's
# docs/design/device-facts.md.
#
# Usage: scripts/london-projector/wake-projector.sh [--status]
# Exit 0 once adb reports `device`. Exit 2 if it needs a human.
# --status wakes nothing and prints whether the set is free, in use or off.

set -euo pipefail

# Its address moves: 192.168.8.100, then 192.168.9.100 on 2026-09-13, then
# 192.168.8.100 again by 2026-11-04. Each move broke a default written in here,
# so look the name up. The Flint 2 (root@10.3.2.6) hands out the lease as
# projector-london, and Technitium resolves the name to whatever it holds.
NAME="${PROJECTOR_NAME:-projector-london.viktorbarzin.lan}"
if [ -n "${PROJECTOR_HOST:-}" ]; then
  HOST="$PROJECTOR_HOST"
else
  HOST="$(getent ahostsv4 "$NAME" 2>/dev/null | awk 'NR == 1 {print $1}')" || HOST=""
  if [ -z "$HOST" ]; then
    printf '%s does not resolve. Set PROJECTOR_HOST, or read the lease on the\n' "$NAME" >&2
    printf 'London router: ssh root@10.3.2.6 grep -i projector /tmp/dhcp.leases\n' >&2
    exit 2
  fi
fi
MAC="${PROJECTOR_MAC:-f49d8a260b18}"
# The Flint 2 is the one box on the projector's own segment, and it holds .1 on
# both London subnets (br-lan 192.168.8.1, br-guest 192.168.9.1). That address
# answering from here proves the tunnel and the router are up; the layer-2
# probe further down has to run on it.
NEIGHBOUR="${PROJECTOR_NEIGHBOUR:-${HOST%.*}.1}"
ROUTER="${PROJECTOR_ROUTER:-root@10.3.2.6}"
# iwinfo prints station MACs with colons: f4:9d:8a:26:0b:18.
MAC_COLONS="$(printf '%s' "$MAC" | sed 's/../&:/g; s/:$//')"

# The adb to drive, overridable so the attach branches below can be exercised
# without a projector. Nothing else about the script changes with it.
ADB="${ADB:-adb}"

say() { printf '%s\n' "$*" >&2; }

wake() {
  # Unicast to the host, NOT the subnet broadcast: a broadcast does not cross
  # the site-to-site tunnel, so it would look like WoL simply does not work.
  python3 - "$HOST" "$MAC" <<'PY'
import binascii, socket, sys
host, mac = sys.argv[1], sys.argv[2]
packet = b"\xff" * 6 + binascii.unhexlify(mac) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (9, 7):
    s.sendto(packet, (host, port))
PY
}

# --status: one line on stdout saying whether the set is free to test on, and
# nothing changed on it: no wake-on-LAN, no key presses. Run it in the same turn
# as any claim that the projector is or is not available. On 2026-10-31 an agent
# repeated a twelve-hour-old "off the network" while someone was watching it.
#   exit 0  free (asleep, or on the launcher) or in use (anything else on screen)
#   exit 2  off the network
#   exit 3  on the network but adb will not attach
status() {
  local stamp verdict
  stamp="measured $(date -u +%Y-%m-%dT%H:%MZ)"
  if ! ping -c 2 -W 3 "$HOST" >/dev/null 2>&1; then
    if ! ping -c 2 -W 3 "$NEIGHBOUR" >/dev/null 2>&1; then
      echo "unknown: $NEIGHBOUR does not answer either, so the tunnel into London is down ($stamp)"
      exit 2
    fi
    local l2 assoc lease
    l2="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$ROUTER" "
          if iwinfo 2>/dev/null | awk '/ESSID/ {print \$1}' |
               while read -r i; do iwinfo \"\$i\" assoclist 2>/dev/null; done |
               grep -qi '$MAC_COLONS'; then echo 'assoc yes'; else echo 'assoc no'; fi
          if grep -qi '$MAC_COLONS' /tmp/dhcp.leases; then echo 'lease yes'; else echo 'lease no'; fi
          " 2>/dev/null)" || l2=""
    assoc="$(printf '%s\n' "$l2" | sed -n 's/^assoc //p')"
    lease="$(printf '%s\n' "$l2" | sed -n 's/^lease //p')"
    case "$assoc" in
      yes) verdict="no ping, but its Wi-Fi is associated" ;;
      no) verdict="no ping, Wi-Fi not associated" ;;
      *) verdict="no ping, and the router at $ROUTER could not be asked" ;;
    esac
    case "$lease" in
      yes) verdict="$verdict, DHCP lease held" ;;
      no) verdict="$verdict, no DHCP lease" ;;
    esac
    echo "off the network: $verdict ($stamp)"
    exit 2
  fi

  "$ADB" connect "$HOST:5555" >/dev/null 2>&1 || true
  local state
  state="$("$ADB" devices | awk -v h="$HOST:5555" '$1 == h {print $2}')"
  if [ "$state" = "offline" ]; then
    "$ADB" disconnect "$HOST:5555" >/dev/null 2>&1 || true
    "$ADB" connect "$HOST:5555" >/dev/null 2>&1 || true
    state="$("$ADB" devices | awk -v h="$HOST:5555" '$1 == h {print $2}')"
  fi
  if [ "$state" != "device" ]; then
    echo "on the network, adb ${state:-not attached}: it answers ping, so it is not off ($stamp)"
    exit 3
  fi

  local awake top home
  awake="$("$ADB" -s "$HOST:5555" shell dumpsys power 2>/dev/null |
    sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)"
  if [ "$awake" != "Awake" ]; then
    echo "free: asleep (${awake:-unknown}), adb attached ($stamp)"
    exit 0
  fi
  top="$("$ADB" -s "$HOST:5555" shell dumpsys activity activities 2>/dev/null |
    sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* [^ ]* \([^ ]*\).*/\1/p' | head -1)"
  home="$("$ADB" -s "$HOST:5555" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -1 | tr -d '\r')"
  if [ -n "$top" ] && [ "$top" = "$home" ]; then
    echo "free: on, showing the launcher ($stamp)"
  else
    echo "in use: ${top:-unknown} is on screen, so someone is watching ($stamp)"
  fi
  exit 0
}

if [ "${1:-}" = "--status" ]; then
  status
fi

if ping -c 1 -W 3 "$HOST" >/dev/null 2>&1; then
  say "projector answers already"
else
  # Distinguish asleep from unreachable before blaming the device: a neighbour
  # on the same LAN answering means the path is fine.
  if ! ping -c 2 -W 3 "$NEIGHBOUR" >/dev/null 2>&1; then
    say "cannot reach $NEIGHBOUR either, so this is the route into the London"
    say "LAN and not the projector. Check the site-to-site tunnel."
    exit 2
  fi
  say "asleep (the path is fine, $NEIGHBOUR answers). sending wake-on-LAN"
  for attempt in 1 2 3; do
    wake
    for _ in $(seq 8); do
      sleep 1
      if ping -c 1 -W 2 "$HOST" >/dev/null 2>&1; then
        say "awake after attempt $attempt"
        break 2
      fi
    done
    say "still asleep after attempt $attempt"
  done
fi

if ! ping -c 1 -W 3 "$HOST" >/dev/null 2>&1; then
  # Settle whether it is asleep before telling anyone to go and look. A sleeping
  # projector keeps its NIC associated and answers ARP; a radio that is off or a
  # set with no power answers nothing at layer 2. The probe has to run on a box
  # on the projector's own segment, because ARP does not cross the tunnel. The
  # router is on both London subnets, so it can ask wherever the set is.
  say "asking the London router ($ROUTER) whether it answers at layer 2..."
  l2="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$ROUTER" "
        ping -c 3 -W 2 $HOST >/dev/null 2>&1
        echo \"neigh \$(ip -4 neigh show $HOST)\"
        if iwinfo 2>/dev/null | awk '/ESSID/ {print \$1}' |
             while read -r i; do iwinfo \"\$i\" assoclist 2>/dev/null; done |
             grep -qi '$MAC_COLONS'; then echo 'assoc yes'; else echo 'assoc no'; fi
        " 2>/dev/null)" || l2=""
  neigh="$(printf '%s\n' "$l2" | sed -n 's/^neigh //p' | sed 's/ *$//')"
  assoc="$(printf '%s\n' "$l2" | sed -n 's/^assoc //p')"
  if [ -z "$assoc" ]; then
    say "  could not ask the router at $ROUTER, so layer 2 is unknown. Check"
    say "  'ssh $ROUTER' works from here before reading anything into this."
  else
    # ip prints the MAC before the state word ("... lladdr f4:9d:... STALE"). An
    # entry that holds a MAC has answered ARP; FAILED and INCOMPLETE hold none.
    case "$neigh" in
      *lladdr*REACHABLE*|*lladdr*DELAY*|*lladdr*STALE*|*lladdr*PROBE*|*lladdr*PERMANENT*)
        say "  it DOES answer ARP (${neigh})." ;;
      *)
        say "  it does NOT answer ARP (${neigh:-no entry})." ;;
    esac
    if [ "$assoc" = "yes" ]; then
      say "  Its Wi-Fi is associated with the router, so the radio is up and the"
      say "  set is not taking the magic packet. It may be in a deeper sleep."
    else
      say "  Its Wi-Fi is not associated with the router, so no amount of"
      say "  wake-on-LAN will reach it."
    fi
  fi

  say "it did not wake after three attempts, and sleep answers the first packet"
  say "in under eight seconds. Retrying from here will not help, and someone in"
  say "the room needs to press the remote."
  if [ "$assoc" != "yes" ]; then
    say ""
    say "This does NOT tell you which of two things happened, and the difference"
    say "matters to whoever walks into the room:"
    say ""
    say "  1. It is switched off, so with no standby power nothing is listening."
    say "  2. Its Wi-Fi is off while the set is wide awake. A magic packet cannot"
    say "     reach a radio that is down either, so this looks identical from here."
    say ""
    say "Case 2 is the one we caused ourselves on 2026-09-13: a test ran"
    say "'svc wifi disable' and died before re-enabling it, and that setting"
    say "survives a reboot. Power-cycling does not fix case 2. Check the set's"
    say "network settings before concluding the projector is dead."
  fi
  exit 2
fi

# Dial, then wait for the entry to settle: `adb connect` returns before the
# device has finished answering, so reading `adb devices` straight after it can
# catch an entry that is about to become `device`.
attach() {
  "$ADB" connect "$HOST:5555" >/dev/null 2>&1 || true
  for _ in $(seq 8); do
    state="$("$ADB" devices | awk -v h="$HOST:5555" '$1 == h {print $2}')"
    [ "$state" = "device" ] && return 0
    sleep 1
  done
  return 0
}

attach

# A connection that was open when the projector fell asleep is STILL LISTED
# afterwards, as `offline`, and `adb connect` answers "already connected" and
# changes nothing. So the wake works, the device is reachable, and the script
# used to blame network debugging for a socket that just needed hanging up.
# Measured 2026-09-13: this exact state, and one `adb disconnect` cleared it.
if [ "$state" = "offline" ]; then
  say "adb entry is stale (offline) from the last sleep. hanging up and redialling"
  "$ADB" disconnect "$HOST:5555" >/dev/null 2>&1 || true
  sleep 1
  attach
fi

wakefulness() {
  "$ADB" -s "$HOST:5555" shell dumpsys power 2>/dev/null |
    sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1
}

case "$state" in
  device)
    say "adb attached to $HOST:5555"
    # In the "Increased" energy mode (set 2026-10-31) the projector stays on
    # Wi-Fi in standby, so ping and adb answer while the lamp is off. Being
    # reachable says nothing about the screen; ask the power manager.
    now="$(wakefulness)"
    if [ "$now" != "Awake" ]; then
      say "in standby (${now:-unknown}). pressing wake over adb"
      "$ADB" -s "$HOST:5555" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
      for _ in $(seq 8); do
        sleep 1
        now="$(wakefulness)"
        [ "$now" = "Awake" ] && break
      done
      if [ "$now" != "Awake" ]; then
        say "screen still ${now:-unknown} after KEYCODE_WAKEUP"
        exit 2
      fi
    fi
    say "screen is on"
    ;;
  unauthorized)
    say "adb says unauthorized. The projector is showing its Allow-debugging"
    say "dialog: accept it ON THE SCREEN and tick 'always allow from this"
    say "computer', or it comes back after every sleep. Our key is wizard@devvm."
    exit 2
    ;;
  *)
    say "adb did not attach (state: ${state:-none}). tcp/5555 may be closed"
    say "because network debugging was switched off on the device."
    exit 2
    ;;
esac
