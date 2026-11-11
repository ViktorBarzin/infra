#!/bin/sh
# Test for files/fix-config.sh, the meshcentral init container. Runs it in the
# init container's own image against throwaway config files and checks the
# result is valid JSON with the expected settings.
#
#   sh stacks/meshcentral/files/fix-config_test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
image=$(sed -n 's/^ *image *= *"\(alpine:[^"]*\)".*/\1/p' "$here/../main.tf" | head -1)
[ -n "$image" ] || { echo "FAIL: init image not found in main.tf" >&2; exit 1; }
# Checked first: docker would create a missing bind-mount source as a directory.
[ -f "$here/fix-config.sh" ] || { echo "FAIL: $here/fix-config.sh missing" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
key=FakeTestSessionKey

fail() { echo "FAIL: $1" >&2; exit 1; }

# run <dir> <session key>: the script sees <dir> as its data volume.
run() {
  docker run --rm -e SESSION_KEY="$2" -e CONFIG=/data/config.json \
    -v "$1:/data" -v "$here/fix-config.sh:/fix-config.sh:ro" \
    "$image" /bin/sh /fix-config.sh
}

# field <file> <python expression on the parsed config d>
field() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"; }

# 1. The volume's real config shape: an old sessionKey, the image's defaults.
mkdir "$work/old"
cat > "$work/old/config.json" <<'EOF'
{
  "$schema": "http://info.meshcentral.com/downloads/meshcentral-config-schema.json",
  "settings": {
    "cert": "meshcentral.viktorbarzin.me",
    "sessionKey": "OldKeyFromTheImage0123456789abcd",
    "port": 443,
    "TLSOffload": false,
    "WebRTC": "true"
  },
  "domains": {
    "": {
      "NewAccounts": "true",
      "certUrl": "https://true:"
    }
  }
}
EOF
run "$work/old" "$key"
c="$work/old/config.json"
[ "$(field "$c" 'd["settings"]["sessionKey"]')" = "$key" ] || fail "old sessionKey not replaced"
[ "$(grep -c sessionKey "$c")" -eq 1 ] || fail "sessionKey appears more than once"
[ "$(field "$c" 'd["settings"]["TLSOffload"]')" = True ] || fail "TLSOffload not forced on"
[ "$(field "$c" 'd["settings"]["ignoreAgentHashCheck"]')" = True ] || fail "ignoreAgentHashCheck missing"
[ "$(field "$c" 'd["domains"][""]["NewAccounts"]')" = False ] || fail "NewAccounts not forced off"
[ "$(field "$c" '"certUrl" in d["domains"][""]')" = False ] || fail "certUrl not disabled"

# 2. A second start changes nothing.
cp "$c" "$work/first.json"
run "$work/old" "$key"
cmp -s "$c" "$work/first.json" || fail "second run changed the config"

# 3. A config with no sessionKey gets one.
mkdir "$work/nokey"
grep -v sessionKey "$work/old/config.json" > "$work/nokey/config.json"
run "$work/nokey" "$key"
[ "$(field "$work/nokey/config.json" 'd["settings"]["sessionKey"]')" = "$key" ] || fail "sessionKey not inserted"

# 4. A fresh volume gets the template, with the key.
mkdir "$work/fresh"
run "$work/fresh" "$key"
c="$work/fresh/config.json"
[ "$(field "$c" 'd["settings"]["sessionKey"]')" = "$key" ] || fail "fresh config lacks the sessionKey"
[ "$(field "$c" 'd["settings"]["TLSOffload"]')" = True ] || fail "fresh config lacks TLSOffload"
[ "$(field "$c" 'd["domains"][""]["NewAccounts"]')" = False ] || fail "fresh config allows sign-up"

# 5. A missing or unsafe key stops the pod before MeshCentral starts, and
# leaves the config alone.
cp "$work/first.json" "$work/before.json"
for bad in "" 'abc"def' 'a&b|c\d' 'has space'; do
  if run "$work/old" "$bad" 2>/dev/null; then fail "accepted session key [$bad]"; fi
  cmp -s "$work/old/config.json" "$work/before.json" || fail "bad key [$bad] changed the config"
done

echo "PASS"
