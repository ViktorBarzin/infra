#!/bin/sh
# Test for files/fix-config.sh, the meshcentral init container. Runs it in the
# init container's own image against throwaway config and database files and
# checks the result: valid JSON with the expected settings, the autobackup zip
# password set, and the database keys dropped once per DB_KEY_GENERATION.
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
zip=FakeTestZipPassword

fail() { echo "FAIL: $1" >&2; exit 1; }

# run <dir> <session key> [db key generation] [zip password]: the script sees
# <dir> as its data volume. The zip password defaults to $zip.
run() {
  docker run --rm -e SESSION_KEY="$2" -e DB_KEY_GENERATION="${3-}" \
    -e BACKUP_ZIP_PASSWORD="${4-$zip}" \
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
[ "$(field "$c" 'd["settings"]["AutoBackup"]["zippassword"]')" = "$zip" ] || fail "no AutoBackup block with the zip password added"
[ "$(field "$c" 'd["settings"]["AutoBackup"]["backupPath"]')" = /opt/meshcentral/meshcentral-backups ] || fail "added AutoBackup block lacks backupPath"

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
[ "$(field "$c" 'd["settings"]["AutoBackup"]["zippassword"]')" = "$zip" ] || fail "fresh config lacks the zip password"
[ "$(grep -ci zippassword "$c")" -eq 1 ] || fail "fresh config has the zip password more than once"

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

# 11. The live volume's shape: an AutoBackup block with an empty zippassword,
# which MeshCentral treats as no password and writes plain zips. The value is
# replaced in place and the block's other settings stay.
mkdir "$work/zip"
python3 -I - "$work/first.json" "$work/zip/config.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["settings"]["AutoBackup"]
d["settings"]["AutoBackup"] = {"backupPath": "/opt/meshcentral/meshcentral-backups",
    "backupInvervalHours": 24, "keepLastDaysBackup": "", "zippassword": ""}
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
run "$work/zip" "$key"
c="$work/zip/config.json"
[ "$(field "$c" 'd["settings"]["AutoBackup"]["zippassword"]')" = "$zip" ] || fail "empty zippassword not replaced"
[ "$(field "$c" 'd["settings"]["AutoBackup"]["backupInvervalHours"]')" = 24 ] || fail "AutoBackup lost its other settings"
[ "$(grep -ci zippassword "$c")" -eq 1 ] || fail "zippassword appears more than once"
# A new password from Vault replaces the old one.
run "$work/zip" "$key" "" NewerZipPassword9
[ "$(field "$c" 'd["settings"]["AutoBackup"]["zippassword"]')" = NewerZipPassword9 ] || fail "zip password not updated"
[ "$(field "$c" 'd["settings"]["sessionKey"]')" = "$key" ] || fail "zip password run lost the sessionKey"

# 12. An AutoBackup block without a zippassword gets one.
mkdir "$work/zipnokey"
python3 -I - "$work/zip/config.json" "$work/zipnokey/config.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["settings"]["AutoBackup"]["zippassword"]
d["settings"]["AutoBackup"]["keepLastDaysBackup"] = 10
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
run "$work/zipnokey" "$key"
c="$work/zipnokey/config.json"
[ "$(field "$c" 'd["settings"]["AutoBackup"]["zippassword"]')" = "$zip" ] || fail "zippassword not inserted into AutoBackup"
[ "$(field "$c" 'd["settings"]["AutoBackup"]["keepLastDaysBackup"]')" = 10 ] || fail "AutoBackup lost keepLastDaysBackup"

# 13. A missing or unsafe zip password stops the pod with the config untouched:
# MeshCentral would write unencrypted backups without one.
cp "$work/zip/config.json" "$work/zip.before"
for bad in "" 'abc"def' 'has space' 'a\b'; do
  if run "$work/zip" "$key" "" "$bad" 2>/dev/null; then fail "accepted zip password [$bad]"; fi
  cmp -s "$work/zip/config.json" "$work/zip.before" || fail "bad zip password [$bad] changed the config"
done

# 14. AutoBackup set to something other than an object opened on its own line
# (false turns backups off, a one-line object cannot be edited safely): the pod
# stops with the config untouched instead of writing a second AutoBackup key.
for odd in false '{"backupPath": "/x"}'; do
  rm -rf "$work/zipodd"; mkdir "$work/zipodd"
  python3 -I - "$work/zip/config.json" "$work/zipodd/config.json" "$odd" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["settings"]["AutoBackup"] = "@ODD@"
open(sys.argv[2], "w").write(json.dumps(d, indent=2).replace('"@ODD@"', sys.argv[3]))
PY
  cp "$work/zipodd/config.json" "$work/zipodd.before"
  if run "$work/zipodd" "$key" 2>/dev/null; then fail "accepted AutoBackup: $odd"; fi
  cmp -s "$work/zipodd/config.json" "$work/zipodd.before" || fail "AutoBackup: $odd changed the config"
done

# 15. A zippassword that is not a string (MeshCentral would encrypt with its
# text form, a password nobody holds) stops the pod with the config untouched.
mkdir "$work/zipnum"
sed 's/"zippassword": "[^"]*"/"zippassword": 123/' "$work/zip/config.json" > "$work/zipnum/config.json"
cp "$work/zipnum/config.json" "$work/zipnum.before"
if run "$work/zipnum" "$key" 2>/dev/null; then fail "accepted a numeric zippassword"; fi
cmp -s "$work/zipnum/config.json" "$work/zipnum.before" || fail "numeric zippassword changed the config"

echo "PASS"
