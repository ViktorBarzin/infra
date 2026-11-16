#!/bin/sh
# Tests uploader.sh against a fake Immich CLI and a fake Pushgateway.
# Run it inside the uploader image, so find, date and node match production:
#   podman run --rm -v "$PWD:/t:ro" --entrypoint sh ghcr.io/immich-app/immich-cli:3.4.1 /t/uploader_test.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'kill "$PUSH_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$WORK/incoming/DCIM/100NZ5_2"
printf 'jpeg' > "$WORK/incoming/DSC_0001.JPG"
printf 'jpeg' > "$WORK/incoming/DCIM/100NZ5_2/DSC_0002.JPG"
printf 'stuck' > "$WORK/incoming/DSC_0003.JPG"

# Fake CLI: records its arguments and "uploads" every file except DSC_0003.JPG,
# which plays a file Immich keeps rejecting, the way the real CLI leaves a
# failed file in place.
cat > "$WORK/fake-cli" <<'EOF'
#!/bin/sh
echo "$@" >> "$FAKE_LOG"
find "$INCOMING" -type f ! -name DSC_0003.JPG -delete
EOF
chmod +x "$WORK/fake-cli"

# Fake Pushgateway: keeps the body of the last PUT.
cat > "$WORK/push.js" <<'EOF'
require('http').createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    require('fs').writeFileSync(process.env.PUSH_LOG, req.method + '\n' + body);
    res.end();
  });
}).listen(19091);
EOF
PUSH_LOG="$WORK/push.log" node "$WORK/push.js" &
PUSH_PID=$!
# Wait until the fake Pushgateway listens.
i=0
until node -e 'require("net").connect(19091, "127.0.0.1").on("connect", () => process.exit(0)).on("error", () => process.exit(1))'; do
  i=$((i + 1)); [ "$i" -lt 50 ] || fail "fake Pushgateway did not start"; sleep 0.2
done

run_uploader() {
  INCOMING="$WORK/incoming" INTERVAL=0 ROUNDS=1 CLI="$WORK/fake-cli" FAKE_LOG="$WORK/cli.log" \
    PUSH_URL=http://127.0.0.1:19091/metrics/job/camera-import \
    timeout 60 sh "$HERE/uploader.sh" || fail "uploader exited with $?"
}
run_uploader

grep -q -- 'upload --recursive --delete --delete-duplicates --no-progress' "$WORK/cli.log" \
  || fail "CLI not called with the upload flags: $(cat "$WORK/cli.log")"
[ ! -e "$WORK/incoming/DSC_0001.JPG" ] || fail "uploaded file still there"
[ ! -d "$WORK/incoming/DCIM" ] || fail "empty folders were not removed"
[ -e "$WORK/incoming/DSC_0003.JPG" ] || fail "a file the CLI did not take was deleted"
head -n1 "$WORK/push.log" | grep -qx PUT || fail "metrics not sent with PUT"
grep -qx 'camera_import_files_waiting 1' "$WORK/push.log" || fail "waiting count wrong: $(cat "$WORK/push.log")"
grep -q '^camera_import_oldest_waiting_seconds [0-9]' "$WORK/push.log" || fail "no oldest-age metric"
grep -q '^camera_import_last_run_timestamp [0-9]' "$WORK/push.log" || fail "no last-run metric"

# An empty inbox does not call the CLI at all.
rm -f "$WORK/incoming/DSC_0003.JPG" "$WORK/cli.log"
rm -f "$WORK/push.log"
run_uploader
[ ! -e "$WORK/cli.log" ] || fail "CLI called for an empty inbox"
grep -qx 'camera_import_files_waiting 0' "$WORK/push.log" || fail "empty inbox not reported as 0"
grep -qx 'camera_import_oldest_waiting_seconds 0' "$WORK/push.log" || fail "empty inbox age not 0"

echo PASS
