#!/bin/sh
# Tests for lib.sh. Run: sh test_lib.sh (no Pi needed).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; printf 'want:\n%s\ngot:\n%s\n' "$2" "$3"; fail=1; fi
}

want='[Service]
DynamicUser=no
User=systemd-journal-upload
ExecStart=
ExecStart=/usr/lib/systemd/systemd-journal-upload --save-state -u http://10.0.20.200:19532'
check "drop-in without cursor" "$want" "$(render_dropin http://10.0.20.200:19532)"

want='[Service]
DynamicUser=no
User=systemd-journal-upload
ExecStart=
ExecStart=/usr/lib/systemd/systemd-journal-upload --save-state -u http://10.0.20.200:19532 --cursor="s=abc;i=1;b=x"'
check "drop-in with first-run cursor" "$want" "$(render_dropin http://10.0.20.200:19532 's=abc;i=1;b=x')"

tmp=$(mktemp -d)
printf '{"url": "http://10.0.20.200:19532"}' > "$tmp/options.json"
check "url from options" "http://10.0.20.200:19532" "$(option_url "$tmp/options.json")"
printf '{}' > "$tmp/options.json"
check "missing url is empty" "" "$(option_url "$tmp/options.json")"

check "cursor line parsed" "s=abc;i=1;b=x" "$(printf '%s\n' '{"__CURSOR":"s=abc;i=1;b=x","MESSAGE":"hi"}' | first_cursor)"
check "no entries gives empty cursor" "" "$(printf '' | first_cursor)"

check "url accepted" "yes" "$(valid_url http://10.0.20.200:19532 && echo yes || echo no)"
check "url with quote refused" "no" "$(valid_url 'http://x" ; rm' && echo yes || echo no)"
check "https accepted" "yes" "$(valid_url https://logs.example:443 && echo yes || echo no)"
check "empty url refused" "no" "$(valid_url '' && echo yes || echo no)"
rm -rf "$tmp"
exit $fail
