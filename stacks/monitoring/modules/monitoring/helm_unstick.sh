#!/usr/bin/env bash
# Auto-heal stuck Helm "pending-upgrade" release records (the #6073 recurring class).
#
# WHY: a Woodpecker pipeline SIGKILLed mid `helm upgrade` (cancel-on-new-push)
# leaves the release's newest revision Secret stuck status=pending-upgrade, which
# blocks every later upgrade of that release ("another operation in progress")
# AND the later stacks behind it in the same CI run (2026-07-26: immich never
# applied behind a wedged prometheus rev). The non-disruptive fix (memory #6073)
# is to delete the dead pending-upgrade revision Secret — helm then reads the
# prior `deployed` revision and the live workload (already rolled) is untouched.
# prometheus.tf now also sets wait=false so helm no longer babysits the slow roll
# (shrinking the SIGKILL window ~15min -> ~2s); this CronJob mops up any residual
# and the crowdsec/nextcloud known-issue class. Detection already exists
# (cluster_healthcheck #18 flags `pending`); this closes the loop by clearing.
#
# SAFETY — deletes ONLY a Secret that is ALL of:
#   (1) a helm release record  (label owner=helm)
#   (2) status=pending-upgrade
#   (3) older than THRESHOLD_SECONDS  (> any legitimate helm --wait timeout in
#       this repo, so an upgrade that is genuinely in-flight is never touched)
#   (4) whose release STILL has a `deployed` revision to fall back to  (never
#       deletes the sole revision of a failed first install — that needs a human)
# Namespaces are an explicit allow-list and RBAC is scoped per-namespace, so the
# job can never touch secrets outside {monitoring, crowdsec, nextcloud}.
set -uo pipefail

THRESHOLD_SECONDS="${THRESHOLD_SECONDS:-1800}"        # 30 min (> the 900s prometheus / 600s nextcloud helm waits)
NAMESPACES="${NAMESPACES:-monitoring crowdsec nextcloud}"
DRY_RUN="${DRY_RUN:-false}"

now="$(date +%s)"
cleared=0; needs_human=0; skipped_young=0

for ns in $NAMESPACES; do
  # TSV per helm release secret: release <TAB> version <TAB> status <TAB> created <TAB> secretName
  rows="$(kubectl -n "$ns" get secret -l owner=helm \
    -o jsonpath='{range .items[*]}{.metadata.labels.name}{"\t"}{.metadata.labels.version}{"\t"}{.metadata.labels.status}{"\t"}{.metadata.creationTimestamp}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [ -z "$rows" ] && continue

  # releases in this ns that have >=1 deployed revision (the safe-to-clear guard)
  deployed_releases="$(printf '%s\n' "$rows" | awk -F'\t' '$3=="deployed"{print $1}' | sort -u)"

  while IFS=$'\t' read -r rel ver status created secret; do
    [ "${status:-}" = "pending-upgrade" ] || continue
    created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
    if [ "$created_epoch" = "0" ]; then
      echo "SKIP  $ns/$rel rev=$ver — could not parse creationTimestamp '$created'"; continue
    fi
    age=$(( now - created_epoch ))
    if [ "$age" -lt "$THRESHOLD_SECONDS" ]; then
      echo "SKIP  $ns/$rel rev=$ver pending-upgrade young=${age}s (<${THRESHOLD_SECONDS}s) — possible in-flight upgrade"
      skipped_young=$(( skipped_young + 1 )); continue
    fi
    if ! printf '%s\n' "$deployed_releases" | grep -qx -- "$rel"; then
      echo "NEEDS-HUMAN  $ns/$rel rev=$ver pending-upgrade age=${age}s but NO deployed fallback revision — leaving for manual review"
      needs_human=$(( needs_human + 1 )); continue
    fi
    if [ "$DRY_RUN" = "true" ]; then
      echo "WOULD-CLEAR  $ns/$rel rev=$ver pending-upgrade age=${age}s (deployed fallback exists) -> $secret  [DRY_RUN]"
      cleared=$(( cleared + 1 )); continue
    fi
    echo "CLEAR  $ns/$rel rev=$ver pending-upgrade age=${age}s (deployed fallback exists) -> deleting $secret"
    if kubectl -n "$ns" delete secret "$secret"; then cleared=$(( cleared + 1 )); fi
  done < <(printf '%s\n' "$rows")
done

echo "helm-unstick summary: cleared=$cleared needs_human=$needs_human skipped_young=$skipped_young dry_run=$DRY_RUN namespaces=[$NAMESPACES] threshold=${THRESHOLD_SECONDS}s"
exit 0
