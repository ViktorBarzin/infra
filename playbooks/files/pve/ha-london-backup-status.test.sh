#!/usr/bin/env bash
# Tests for playbooks/files/pve/ha-london-backup-status. Each case builds a
# throwaway backup directory with known file times, runs the script against it
# and reads the textfile it writes, so nothing on the host is touched.
#
#   bash playbooks/files/pve/ha-london-backup-status.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/ha-london-backup-status"

fails=0 passes=0
ok() { passes=$((passes + 1)); echo "ok   $1"; }
bad() { fails=$((fails + 1)); echo "FAIL $1"; [ $# -gt 1 ] && printf '     %s\n' "${@:2}"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $(printf %q "$2")" "got:  $(printf %q "$3")"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
OUT="$T/textfile/ha_london_backup.prom"

run() { # run the script against $T/backup; prints the exit code
  BACKUP_DIR="$T/backup" TEXTFILE_DIR="$T/textfile" bash "$SCRIPT" >"$T/out.log" 2>&1
  echo $?
}
metric() { # value of one metric line from the textfile, empty if absent
  awk -v m="$1" '$1 == m { print $2 }' "$OUT" 2>/dev/null
}
reset() { rm -rf "$T/backup" "$T/textfile"; mkdir -p "$T/textfile"; }

# --- the backup directory is missing (export not created, or a typo) --------
reset
eq "a missing directory still exits 0" "0" "$(run)"
eq "a missing directory reports dir_present 0" "0" "$(metric ha_london_backup_dir_present)"
eq "a missing directory reports newest 0" "0" "$(metric ha_london_backup_newest_file_timestamp_seconds)"
eq "a missing directory reports 0 files" "0" "$(metric ha_london_backup_files)"
last=$(metric ha_london_backup_status_last_run_timestamp_seconds)
now=$(date +%s)
if [ -n "$last" ] && [ $((now - last)) -lt 60 ]; then ok "the last-run timestamp is now"; else bad "the last-run timestamp is now" "got: $last, now: $now"; fi

# --- an empty directory -----------------------------------------------------
reset; mkdir -p "$T/backup"
run >/dev/null
eq "an empty directory reports dir_present 1" "1" "$(metric ha_london_backup_dir_present)"
eq "an empty directory reports newest 0, so the staleness alert fires" "0" "$(metric ha_london_backup_newest_file_timestamp_seconds)"
eq "an empty directory reports 0 files" "0" "$(metric ha_london_backup_files)"

# --- backups present: the newest tar wins, other files are ignored ----------
reset; mkdir -p "$T/backup"
head -c 100 /dev/zero >"$T/backup/old.tar"; touch -d @1762000000 "$T/backup/old.tar"
head -c 250 /dev/zero >"$T/backup/new.tar"; touch -d @1762600000 "$T/backup/new.tar"
# A newer file that is not a backup archive (a probe, a partial upload with
# another name) must not make the export look fresh.
echo x >"$T/backup/.probe"; touch -d @1762900000 "$T/backup/.probe"
mkdir -p "$T/backup/sub"; head -c 7 /dev/zero >"$T/backup/sub/nested.tar"; touch -d @1762950000 "$T/backup/sub/nested.tar"
run >/dev/null
eq "the newest .tar's mtime is reported" "1762600000" "$(metric ha_london_backup_newest_file_timestamp_seconds)"
eq "only top-level .tar files are counted" "2" "$(metric ha_london_backup_files)"
eq "bytes sum the counted archives" "350" "$(metric ha_london_backup_bytes)"

# --- file names with spaces (HA names backups after their display name) -----
reset; mkdir -p "$T/backup"
head -c 10 /dev/zero >"$T/backup/Automatic backup 2026.11.0.tar"; touch -d @1762700000 "$T/backup/Automatic backup 2026.11.0.tar"
run >/dev/null
eq "a name with spaces is read" "1762700000" "$(metric ha_london_backup_newest_file_timestamp_seconds)"

# --- the write is atomic: no temp file is left behind ------------------------
eq "only the .prom file is left in the textfile directory" "ha_london_backup.prom" "$(find "$T/textfile" -mindepth 1 -printf '%f\n')"
if grep -q '^# HELP ha_london_backup_newest_file_timestamp_seconds' "$OUT"; then ok "metrics carry HELP lines"; else bad "metrics carry HELP lines" "$(cat "$OUT")"; fi

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
