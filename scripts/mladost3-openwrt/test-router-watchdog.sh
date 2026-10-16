#!/usr/bin/env bash
# Tests for router-watchdog, run in an OpenWrt 23.05 container so the script
# meets the same busybox ash and applets as the router. The reboot becomes a
# printed REBOOT line, ping is faked per address, and the stick lives in fake
# /sys, /dev and /proc/mounts trees. Needs docker. Usage:
#   scripts/mladost3-openwrt/test-router-watchdog.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
image=openwrt/rootfs:x86-64-23.05.0

docker run --rm -i --network none -v "$here:/w:ro" "$image" /bin/sh -s <<'EOF'
BB=/bin/busybox
pass=0
fail=0

# Fake ping: an address answers if /tmp/t/up/<ip> exists, or once its
# /tmp/t/flaky/<ip> countdown of failures reaches zero.
cat > /tmp/fakeping <<'P'
#!/bin/sh
for ip; do :; done
[ -e /tmp/t/up/$ip ] && exit 0
f=/tmp/t/flaky/$ip
[ -e $f ] || exit 1
read -r n < $f
[ "$n" -le 0 ] && exit 0
echo $((n - 1)) > $f
exit 1
P
chmod +x /tmp/fakeping

# A fake partition whose ext4 superblock carries UUID $2 (32 hex chars).
mkdisk() {
	$BB dd if=/dev/zero of="$1" bs=1024 count=4 2>/dev/null
	hex=$2 oct=
	while [ -n "$hex" ]; do
		b=${hex%"${hex#??}"}; hex=${hex#??}
		oct="$oct\\$(printf '%03o' 0x$b)"
	done
	printf "$oct" | $BB dd of="$1" bs=1 seek=1128 conv=notrunc 2>/dev/null
}
STICK=794b3f7cdd284368980755ed25237783
OTHER=00112233445566778899aabbccddeeff

reset() {
	rm -rf /tmp/t
	mkdir -p /tmp/t/up /tmp/t/flaky /tmp/t/sys/sda1 /tmp/t/dev
	echo "/dev/sda1 /overlay ext4 rw,relatime 0 0" > /tmp/t/mounts
	mkdisk /tmp/t/dev/sda1 $STICK
	echo 1 > /tmp/t/up/176.12.22.76
}

# run SECONDS [VAR=value ...]: start the watchdog with test timings, let it run,
# stop it, and leave its output in /tmp/t/out.
run() {
	secs=$1; shift
	# PATH points nowhere: the script may use only builtins and $BB, as on a
	# router whose stick is gone.
	env PATH=/nonexistent TICK=1 CHECK_EVERY=2 RETRY_EVERY=1 RETRIES=2 HOLD=6 \
		BB=$BB PING=/tmp/fakeping REBOOT=echo LOG_STDOUT=1 \
		MARKER=/tmp/t/marker SYS_BLOCK=/tmp/t/sys DEV_DIR=/tmp/t/dev MOUNTS=/tmp/t/mounts \
		"$@" /bin/sh /w/router-watchdog > /tmp/t/out 2>&1 &
	pid=$!
	t=0
	while [ $t -lt $secs ] && kill -0 $pid 2>/dev/null; do
		[ -n "$DURING" ] && [ $t -eq "${DURING_AT:-2}" ] && eval "$DURING"
		sleep 1; t=$((t + 1))
	done
	kill $pid 2>/dev/null; wait $pid 2>/dev/null
	DURING=
}

check() { # check NAME CONDITION
	if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"
	else fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     | /' /tmp/t/out; fi
}
has() { grep -q -- "$1" /tmp/t/out; }

reset; echo 1 > /tmp/t/up/10.3.2.1; run 6
check "tunnel up: healthy, no reboot" 'has healthy && ! has REBOOT'

reset; echo 1 > /tmp/t/up/10.0.10.1; run 6
check "second target alone is enough" 'has healthy && ! has REBOOT'

reset; run 10
check "tunnel down, Sofia up: reboots" 'has "REBOOT tunnel down" && has "Sofia.s public address answers"'
check "tunnel reboot leaves a marker" '[ -s /tmp/t/marker ]'

reset; echo 2 > /tmp/t/flaky/10.3.2.1; run 8
check "recovers during retries: no reboot" 'has "healthy (after 2 retries)" && ! has REBOOT'

reset; echo previous > /tmp/t/marker; run 6
check "marker present: holds instead of rebooting" 'has "holding" && ! has REBOOT'

reset; echo previous > /tmp/t/marker; run 20
check "marker present: reboots once HOLD has passed" 'has "REBOOT tunnel down" && has "did not help"'

reset; rm /tmp/t/up/176.12.22.76; run 6
check "tunnel and Sofia down: holds" 'has "holding" && has "Sofia down" && ! has REBOOT'

reset; rm /tmp/t/up/176.12.22.76; run 20
check "tunnel and Sofia down: reboots after HOLD" 'has "REBOOT tunnel down" && has "Sofia down"'

reset; echo old > /tmp/t/marker; echo 1 > /tmp/t/up/10.3.2.1; run 5
check "healthy check clears the marker" '[ ! -e /tmp/t/marker ] && has "cleared"'

reset; echo 1 > /tmp/t/up/10.3.2.1
DURING='rm -r /tmp/t/sys/sda1; mkdir /tmp/t/sys/sdb /tmp/t/sys/sdb1; cp /tmp/t/dev/sda1 /tmp/t/dev/sdb1; mkdisk /tmp/t/dev/sdb $OTHER'
run 8 CHECK_EVERY=100
check "stick drops and returns: reboots" 'has "REBOOT stick dropout" && has "back as sdb1"'
check "dropout reboot leaves no marker" '[ ! -e /tmp/t/marker ]'

reset; echo 1 > /tmp/t/up/10.3.2.1
DURING='rm -r /tmp/t/sys/sda1'
run 6 CHECK_EVERY=100
check "stick gone for good: logs once, no reboot" '[ "$(grep -c "is gone" /tmp/t/out)" = 1 ] && ! has REBOOT'

reset; echo 1 > /tmp/t/up/10.3.2.1
DURING='rm -r /tmp/t/sys/sda1; mkdir /tmp/t/sys/sdb1; mkdisk /tmp/t/dev/sdb1 $OTHER'
run 6 CHECK_EVERY=100
check "a different disk appears: no reboot" '! has REBOOT'

reset; echo 1 > /tmp/t/up/10.3.2.1
DURING='rm -r /tmp/t/sys/sda1; mkdir /tmp/t/sys/sdb1; echo 8:17 > /tmp/t/sys/sdb1/dev'
run 6 CHECK_EVERY=100
check "returned stick without a /dev node does not crash the loop" '! has REBOOT && has "is gone"'

reset; echo 1 > /tmp/t/up/10.3.2.1; echo "/dev/mtdblock4 /overlay jffs2 rw 0 0" > /tmp/t/mounts; run 4
check "overlay on internal flash: dropout check off" 'has "dropout check is off" && has healthy'

reset; echo 1 > /tmp/t/up/10.3.2.1
DURING='rm -r /tmp/t/sys/sda1; mkdir /tmp/t/sys/sdb1; cp /tmp/t/dev/sda1 /tmp/t/dev/sdb1'
run 6 CHECK_EVERY=100 MIN_UPTIME=999999999
check "too soon after boot: no reboot, says why" '! has REBOOT && has "would reboot (stick dropout"'

reset; echo 1 > /tmp/t/up/10.3.2.1; echo "100.00 50.00" > /tmp/t/uptime
DURING='grep -c started /tmp/t/out > /tmp/t/early'
run 6 UPTIME=/tmp/t/uptime BOOT_DELAY=4 MIN_UPTIME=0
check "just after boot: start line waits for the log restart" '[ "$(cat /tmp/t/early)" = 0 ] && has started'

# The real busybox ping, no fake: loopback answers, TEST-NET-1 has no route.
reset; run 6 PING= TARGETS=127.0.0.1
check "real ping: loopback target is healthy" 'has healthy && ! has REBOOT'
reset; run 12 PING= TARGETS=192.0.2.1 SOFIA=127.0.0.1
check "real ping: unroutable target reboots" 'has "REBOOT tunnel down"'

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
EOF
