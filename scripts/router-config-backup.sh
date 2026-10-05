#!/bin/bash
# router-config-backup — weekly config backup of the OpenWrt site routers to
# sda, picked up by offsite-sync-backup for the Synology.
#
# Each router streams `sysupgrade -b -` (the standard OpenWrt config backup:
# /etc/config, keys, passwords, the files listed in /etc/sysupgrade.conf) over
# SSH into /mnt/backup/routers/<name>/backup-<name>-<YYYYMMDD>.tar.gz. The file
# is appended to the offsite manifest, so the next daily offsite-sync copies it
# (and only it) to Synology:/Backup/Viki/pve-backup/routers/.
#
# Auth: dedicated key /root/.ssh/id_router_backup. On each router that key is
# pinned in /etc/dropbear/authorized_keys to command="sysupgrade -b -" with
# forwarding and pty disabled, so it can produce a backup and nothing else.
#
# Archives hold the routers' WireGuard private keys and root password hashes;
# they are written 0600, like the pfSense config.xml copies.
#
# Metrics: Pushgateway job router-config-backup, one instance per router,
# backup_last_status / backup_last_success_timestamp / backup_last_bytes, in
# both success and failure paths so RouterConfigBackupStale/Failing can fire.
#
# Design + routers: docs/architecture/backup-dr.md, docs/architecture/vpn.md.
set -uo pipefail

BACKUP_ROOT="/mnt/backup"
DEST_BASE="${BACKUP_ROOT}/routers"
MANIFEST="${BACKUP_ROOT}/.changed-files"
MANIFEST_LOCK="${MANIFEST}.lock"
PUSHGATEWAY="${ROUTER_BACKUP_PUSHGATEWAY:-http://10.0.20.100:30091}"
SSH_KEY="${ROUTER_BACKUP_SSH_KEY:-/root/.ssh/id_router_backup}"
# Weekly runs, so 8 copies = about two months on sda. The Synology keeps its
# own daily snapshots of the Backup share on top of that.
KEEP="${ROUTER_BACKUP_KEEP:-8}"
# name=ssh-target, space separated. Targets are tunnel addresses, reached from
# this host via the TP-Link -> pfSense -> WireGuard route.
ROUTERS="${ROUTERS:-mladost3-openwrt=root@10.3.2.7}"
DATE="$(date +%Y%m%d)"

log()  { echo "$(date '+%F %T') $*"; }
warn() { echo "$(date '+%F %T') WARN: $*" >&2; }

manifest_append() {
    (
        flock -x 200
        cat >> "${MANIFEST}"
    ) 200>"${MANIFEST_LOCK}"
}

push_metrics() {
    local name="$1" status="$2" bytes="$3"
    {
        echo "backup_last_status ${status}"
        echo "backup_last_bytes ${bytes}"
        [ "${status}" -eq 0 ] && echo "backup_last_success_timestamp $(date +%s)"
    } | curl -s --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/router-config-backup/instance/${name}" 2>/dev/null || true
}

if ! mountpoint -q "${BACKUP_ROOT}"; then
    warn "${BACKUP_ROOT} not mounted, aborting"
    for entry in ${ROUTERS}; do push_metrics "${entry%%=*}" 1 0; done
    exit 1
fi

RC=0
for entry in ${ROUTERS}; do
    name="${entry%%=*}"
    target="${entry#*=}"
    dest="${DEST_BASE}/${name}"
    file="backup-${name}-${DATE}.tar.gz"
    tmp="${dest}/.${file}.part"
    mkdir -p "${dest}"
    chmod 700 "${DEST_BASE}" "${dest}"

    log "--- ${name} (${target}) ---"
    status=1
    bytes=0
    # The router ignores the command we send and runs its pinned one.
    if (umask 077; ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes \
            -i "${SSH_KEY}" "${target}" "sysupgrade -b -" > "${tmp}"); then
        # Accept only a complete archive that really holds a router config.
        # List first, then match: `tar | grep -q` stops reading at the first
        # match, tar dies of SIGPIPE, and pipefail turns that into a failure.
        listing="$(tar tzf "${tmp}" 2>/dev/null)" || listing=""
        if gzip -t "${tmp}" 2>/dev/null && grep -qx 'etc/config/network' <<< "${listing}"; then
            mv -f "${tmp}" "${dest}/${file}"
            chmod 600 "${dest}/${file}"
            bytes="$(stat -c %s "${dest}/${file}")"
            echo "routers/${name}/${file}" | manifest_append
            status=0
            log "  OK: ${file} (${bytes} bytes)"
        else
            warn "${name}: stream was not a valid config backup"
        fi
    else
        warn "${name}: ssh to ${target} failed"
    fi
    rm -f "${tmp}"

    # Retention: newest KEEP archives.
    ls -t "${dest}"/backup-"${name}"-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -f

    push_metrics "${name}" "${status}" "${bytes}"
    [ "${status}" -eq 0 ] || RC=1
done

exit "${RC}"
