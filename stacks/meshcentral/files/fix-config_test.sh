#!/bin/sh
# Test for files/fix-config.sh, the meshcentral init container. Runs it in the
# init container's own image against throwaway config and database files and
# checks the result: valid JSON with the expected settings, and the database
# keys dropped once per DB_KEY_GENERATION.
#
#   sh stacks/meshcentral/files/fix-config_test.sh
#
# No CI pipeline runs it (the infra repo has no shell-test job). Run it by
# hand before changing fix-config.sh, and pass it to
# `homelab work land --verify-cmd`.
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

# run <dir> <session key> [db key generation]: the script sees <dir> as its
# data volume.
run() {
  docker run --rm -e SESSION_KEY="$2" -e DB_KEY_GENERATION="${3-}" \
    -e CONFIG=/data/config.json \
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

# 6. A new DB_KEY_GENERATION drops the three keys MeshCentral generates
# again on start (login cookie, invitation link, AMT event secret) and leaves
# every other record as it was. The shape is NeDB's: one JSON document a line.
mkdir "$work/db"
cp "$work/first.json" "$work/db/config.json"
db="$work/db/meshcentral.db"
cat > "$db" <<'EOF'
{"_id":"user//admin","name":"admin","siteadmin":4294967295}
{"_id":"InvitationLinkEncryptionKey","key":"aaaa1111","time":1723929280020}
{"_id":"LoginCookieEncryptionKey","key":"bbbb2222","time":1723929280015}
{"_id":"dbconfig","version":1,"amtWsEventSecret":"cccc3333"}
{"_id":"mesh//xyz","name":"Family","invite":{"codes":["abc"]}}
{"$$indexCreated":{"fieldName":"type"}}
EOF
cp "$db" "$work/db.orig"
run "$work/db" "$key" gen-1
grep -q 'EncryptionKey' "$db" && fail "an encryption key record survived the rotation"
grep -q 'amtWsEventSecret' "$db" && fail "amtWsEventSecret survived the rotation"
[ "$(grep -c '"_id":"dbconfig","version":1}' "$db")" -eq 1 ] || fail "dbconfig record lost or mangled"
grep -v -e EncryptionKey -e dbconfig "$work/db.orig" > "$work/others.want"
grep -v dbconfig "$db" > "$work/others.got"
cmp -s "$work/others.want" "$work/others.got" || fail "rotation changed other records"
[ "$(cat "$work/db/db-key-generation")" = gen-1 ] || fail "generation marker not written"
[ "$(field "$work/db/config.json" 'd["settings"]["sessionKey"]')" = "$key" ] || fail "rotation run lost the sessionKey"

# 7. The same generation again leaves the new keys MeshCentral wrote alone.
echo '{"_id":"LoginCookieEncryptionKey","key":"dddd4444","time":1}' >> "$db"
cp "$db" "$work/db.after"
run "$work/db" "$key" gen-1
cmp -s "$db" "$work/db.after" || fail "same generation rotated the keys again"

# 8. No generation set: the database is not touched.
run "$work/db" "$key"
cmp -s "$db" "$work/db.after" || fail "unset generation changed the database"

# 9. An unsafe generation stops the pod with the database untouched.
for bad in 'has space' 'a;b' 'x$y'; do
  if run "$work/db" "$key" "$bad" 2>/dev/null; then fail "accepted generation [$bad]"; fi
  cmp -s "$db" "$work/db.after" || fail "bad generation [$bad] changed the database"
done

# 10. A fresh volume with a generation: no database is created, the marker is.
mkdir "$work/freshdb"
run "$work/freshdb" "$key" gen-1
[ ! -e "$work/freshdb/meshcentral.db" ] || fail "rotation created a database"
[ "$(cat "$work/freshdb/db-key-generation")" = gen-1 ] || fail "fresh volume lacks the marker"

echo "PASS"
