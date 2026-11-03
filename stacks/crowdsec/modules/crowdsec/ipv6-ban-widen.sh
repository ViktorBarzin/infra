#!/bin/sh
# Copies each local IPv6 ban to a ban on its /64, for the time the original
# has left. Runs inside a CrowdSec agent pod (busybox sh + awk + cscli), fed on
# stdin by the crowdsec-ipv6-ban-widen CronJob. ORIGIN selects whose bans are
# widened (default crowdsec: the local scenarios, not CAPI or the lists).
# DRY=1 prints what it would add.
set -u
ORIGIN="${ORIGIN:-crowdsec}"
DRY="${DRY:-0}"

p64() {
  awk -v ip="$1" 'BEGIN {
    if (index(ip, "::")) {
      split(ip, a, "::")
      nl = (a[1] == "") ? 0 : split(a[1], L, ":")
      nr = (a[2] == "") ? 0 : split(a[2], R, ":")
      k = 0
      for (i = 1; i <= nl; i++) G[++k] = L[i]
      for (i = 1; i <= 8 - nl - nr; i++) G[++k] = "0"
      for (i = 1; i <= nr; i++) G[++k] = R[i]
    } else {
      split(ip, G, ":")
    }
    out = ""
    for (i = 1; i <= 4; i++) {
      h = tolower(G[i]); sub(/^0+/, "", h); if (h == "") h = "0"
      out = out (i > 1 ? ":" : "") h
    }
    print out "::/64"
  }'
}

# Existing range bans, so a /64 is added once rather than every run.
ranges=$(cscli decisions list --scope range --type ban --limit 0 -o raw 2>/dev/null | awk -F, 'NR > 1 {print $3}')

added=0; skipped=0; seen=0
cscli decisions list --origin "$ORIGIN" --scope ip --type ban --limit 0 -o raw 2>/dev/null \
  | awk -F, 'NR > 1 && $3 ~ /^Ip:/ {ip = substr($3, 4); if (index(ip, ":") && !index(ip, ".")) print ip, $9, $4}' \
  | {
    while read -r ip dur scenario; do
      seen=$((seen + 1))
      prefix=$(p64 "$ip")
      case "$prefix" in
        # Never our own space: the routed /48, the VLAN 10 and tunnel /64s, ULA, link-local.
        2001:470:5a7f:*|2001:470:6f:43d:*|2001:470:6e:43d:*|fc*|fd*|fe80:*) skipped=$((skipped + 1)); continue ;;
      esac
      case "$dur" in -*|"") skipped=$((skipped + 1)); continue ;; esac
      if printf '%s\n' "$ranges" | grep -qxF "Range:$prefix"; then
        skipped=$((skipped + 1)); continue
      fi
      if [ "$DRY" = 1 ]; then
        echo "would ban $prefix for $dur ($ip, $scenario)"
      elif cscli decisions add --range "$prefix" --duration "$dur" --type ban \
          --reason "ipv6-64 of $ip ($scenario)" >/dev/null 2>&1; then
        echo "banned $prefix for $dur ($ip, $scenario)"
        ranges=$(printf '%s\nRange:%s' "$ranges" "$prefix")
        added=$((added + 1))
      else
        echo "FAILED to ban $prefix ($ip)"
      fi
    done
    echo "ipv6-ban-widen: origin=$ORIGIN ipv6_bans=$seen added=$added skipped=$skipped"
  }
