#!/usr/bin/env bash
# Reconcile per-user t3 Workstation instances from roster.yaml (the single source
# of truth). roster_engine.py derives the desired state (accounts, per-tier groups,
# sticky ports, /etc/ttyd-user-map, dispatch.json); this script APPLIES it.
#
# ADDITIVE-ONLY for existing users: never removes a group, never replaces a home,
# never re-locks/re-chmods an existing account — so a routine (hourly) reconcile is
# always safe for live users. Destructive offboarding (userdel) is a SEPARATE, gated
# path, never here. Runs hourly as root via t3-provision-users.timer; root has no
# Vault token, so tier validation is best-effort (skipped when k8s_users is unreachable).
#
# DRY_RUN=1 prints actions without mutating. WORKSTATION_DIR overrides the roster/engine location.
set -euo pipefail

WORKSTATION_DIR="${WORKSTATION_DIR:-/home/wizard/code/infra/scripts/workstation}"
ENGINE="$WORKSTATION_DIR/roster_engine.py"
ROSTER="$WORKSTATION_DIR/roster.yaml"
ENVDIR=/etc/t3-serve
MAP=/etc/ttyd-user-map
DRY_RUN="${DRY_RUN:-0}"

log() { echo "[t3-provision] $*"; }
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

[[ $EUID -eq 0 ]] || { echo "t3-provision-users: must run as root" >&2; exit 1; }
for bin in python3 jq; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
[[ -f "$ROSTER" && -f "$ENGINE" ]] || { echo "roster/engine not under $WORKSTATION_DIR" >&2; exit 1; }
install -d -m 0755 "$ENVDIR"

# 1) current sticky ports from existing .env files -> {os_user: port}
ports_file="$(mktemp)"; trap 'rm -f "$ports_file" "${desired_file:-}"' EXIT
{ echo "{}"; for f in "$ENVDIR"/*.env; do
    [[ -e "$f" ]] || continue
    u="$(basename "$f" .env)"; p="$(grep -oE 'T3_PORT=[0-9]+' "$f" | cut -d= -f2)"
    [[ -n "$p" ]] && jq -n --arg u "$u" --argjson p "$p" '{($u): $p}'
  done; } | jq -s 'add' > "$ports_file"

# 2) tier validation vs live k8s_users (best-effort; aborts only on a real conflict)
if command -v vault >/dev/null; then
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  if k8s_raw="$(vault kv get -field=k8s_users secret/platform 2>/dev/null)"; then
    k8s_file="$(mktemp)"; echo "$k8s_raw" | jq -c 'map_values(.role)' > "$k8s_file"
    if ! python3 "$ENGINE" validate --roster "$ROSTER" --k8s-users-json "$k8s_file"; then
      rm -f "$k8s_file"; echo "[t3-provision] ABORT: roster tier conflicts with k8s_users" >&2; exit 1
    fi
    rm -f "$k8s_file"
  else
    log "WARN: k8s_users unreachable (no Vault token?) -> skipping tier validation"
  fi
fi

# 3) derive desired state
desired_file="$(mktemp)"
python3 "$ENGINE" derive --roster "$ROSTER" --ports-json "$ports_file" > "$desired_file"
jq -e . "$desired_file" >/dev/null || { echo "[t3-provision] derive produced invalid JSON" >&2; exit 1; }

# 4) per-account: create-if-absent + ADDITIVE tier groups (never strip)
while IFS=$'\t' read -r os_user shell groups_csv; do
  if ! id "$os_user" >/dev/null 2>&1; then
    log "create account: $os_user (shell $shell)"
    run useradd -m -s "$shell" "$os_user"
    run passwd -l "$os_user"           # SSO/t3 only — no local password
    run chmod 700 "/home/$os_user"
  fi
  [[ -z "$groups_csv" ]] && continue
  current="$(id -nG "$os_user" 2>/dev/null | tr ' ' '\n')"
  IFS=',' read -ra want <<< "$groups_csv"
  for g in "${want[@]}"; do
    grep -qx "$g" <<< "$current" && continue          # already a member -> skip
    getent group "$g" >/dev/null 2>&1 || continue      # group must exist
    log "add $os_user -> group $g"; run gpasswd -a "$os_user" "$g" >/dev/null
  done
done < <(jq -r '.accounts[] | [.os_user, .shell, (.groups|join(","))] | @tsv' "$desired_file")

# 5) per-user .env (sticky port) + enable t3-serve@
while IFS=$'\t' read -r os_user port; do
  envf="$ENVDIR/$os_user.env"
  if [[ ! -f "$envf" ]] || ! grep -qx "T3_PORT=$port" "$envf"; then
    run bash -c "printf 'T3_PORT=%s\n' '$port' > '$envf'"
  fi
  id "$os_user" >/dev/null 2>&1 && run systemctl enable --now "t3-serve@$os_user.service" >/dev/null 2>&1 || true
done < <(jq -r '.ports | to_entries[] | [.key, .value] | @tsv' "$desired_file")

# 6) regenerate /etc/ttyd-user-map + dispatch.json from the desired state (SSoT:
#    a roster entry removed here DISAPPEARS, which is what the offboarding cut relies on)
if [[ "$DRY_RUN" == 1 ]]; then
  log "[dry-run] would regenerate $MAP + $ENVDIR/dispatch.json"
else
  jq -r '.ttyd_user_map' "$desired_file" > "$MAP.tmp" && install -m 0644 "$MAP.tmp" "$MAP" && rm -f "$MAP.tmp"
  jq -c '.dispatch' "$desired_file" > "$ENVDIR/dispatch.json.tmp" && install -m 0644 "$ENVDIR/dispatch.json.tmp" "$ENVDIR/dispatch.json" && rm -f "$ENVDIR/dispatch.json.tmp"
fi

log "reconcile complete ($([[ "$DRY_RUN" == 1 ]] && echo DRY-RUN || echo applied))"
