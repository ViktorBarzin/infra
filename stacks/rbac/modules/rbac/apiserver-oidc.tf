# Configure kube-apiserver authentication via a structured
# AuthenticationConfiguration file (apiserver.config.k8s.io/v1, GA on k8s 1.30+).
#
# WHY structured config instead of the legacy --oidc-* flags: the apiserver can
# only carry ONE legacy issuer, but we need TWO — the `kubernetes` app (kubectl
# / kubelogin CLI) AND the `k8s-dashboard` app (oauth2-proxy in front of the
# Kubernetes Dashboard). Structured config supports multiple JWT issuers.
#
# Both issuers map username<-email and groups<-groups with EMPTY prefixes, to
# match the existing RBAC subjects (kind: User, name: <raw email>; group names
# verbatim). Do NOT add a prefix or existing bindings break.
#
# DRIFT WARNING (and how it's now handled): apiserver auth lives in THREE places
# that must stay in sync, because a `kubeadm upgrade` REGENERATES the static-pod
# manifest from kubeadm-config:
#   1. /etc/kubernetes/pki/auth-config.yaml         — the structured authn file
#   2. the live kube-apiserver static-pod manifest  — references it via the flag
#   3. the kubeadm-config ClusterConfiguration CM   — what kubeadm regenerates from
# Originally only (1)+(2) were managed, so every kubeadm upgrade rewrote the
# manifest from the STALE CM, reverting --authentication-config to single-issuer
# --oidc-* flags. The consequence is SSO breakage AFTER the upgrade: kubectl +
# dashboard lose multi-issuer auth (the apiserver does NOT crash on this — verified
# by an isolated repro 2026-06-24; the 2026-06-24 v1.35 upgrade *stall* was a
# separate etcd IO-starvation issue, see
# docs/post-mortems/2026-06-24-kubeadm-oidc-drift-apiserver-upgrade-stall.md). The
# remote script below now ALSO reconciles (3) via `kubeadm init phase
# upload-config`, so a future kubeadm upgrade regenerates a CORRECT manifest. The
# k8s-version-upgrade chain additionally ALERTS (does not block — SSO drift is
# recoverable) via `kubeadm upgrade diff` in preflight if --authentication-config
# would still be dropped.
#
# SAFETY: the remote script health-gates on /livez and AUTO-ROLLS-BACK the
# manifest from a timestamped backup if the apiserver does not recover, so a
# malformed config cannot leave the single master down. Reconciling kubeadm-config
# is zero-impact on the running cluster (the CM is only read during an upgrade).

variable "k8s_master_host" {
  type    = string
  default = "10.0.20.100"
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "oidc_issuer_url" {
  type    = string
  default = "https://authentik.viktorbarzin.me/application/o/kubernetes/"
}

variable "oidc_client_id" {
  type    = string
  default = "kubernetes"
}

variable "k8s_dashboard_issuer_url" {
  type    = string
  default = "https://authentik.viktorbarzin.me/application/o/k8s-dashboard/"
}

variable "k8s_dashboard_audience" {
  type    = string
  default = "k8s-dashboard"
}

locals {
  apiserver_auth_config_yaml = <<-YAML
    apiVersion: apiserver.config.k8s.io/v1
    kind: AuthenticationConfiguration
    jwt:
      - issuer:
          url: "${var.oidc_issuer_url}"
          audiences:
            - "${var.oidc_client_id}"
        claimMappings:
          username:
            claim: email
            prefix: ""
          groups:
            claim: groups
            prefix: ""
      - issuer:
          url: "${var.k8s_dashboard_issuer_url}"
          audiences:
            - "${var.k8s_dashboard_audience}"
        claimMappings:
          username:
            claim: email
            prefix: ""
          groups:
            claim: groups
            prefix: ""
  YAML

  # Indentation-safe manifest editor: appends the --authentication-config flag
  # using the exact leading whitespace of the --authorization-mode line.
  apiserver_flag_insert_py = <<-PY
    import sys
    p = sys.argv[1]
    lines = open(p).read().splitlines(True)
    out, done = [], False
    for ln in lines:
        out.append(ln)
        if not done and '- --authorization-mode=' in ln:
            indent = ln[:len(ln) - len(ln.lstrip())]
            out.append(indent + '- --authentication-config=/etc/kubernetes/pki/auth-config.yaml\n')
            done = True
    open(p, 'w').writelines(out)
    print('flag-inserted' if done else 'ANCHOR-NOT-FOUND')
  PY

  # Reconciles the kubeadm-config ClusterConfiguration's apiServer.extraArgs:
  # drops the stale single-issuer --oidc-* args and ensures --authentication-config
  # is present (anchored after --authorization-mode). Stdlib-only (the master is
  # only guaranteed python3, not pyyaml/yq). Idempotent; preserves all other
  # fields (etcd args, audit args, extraVolumes) verbatim. Exits 3 if the
  # authorization-mode anchor is missing (fail loud, leave the CM untouched).
  kubeadm_oidc_reconcile_py = <<-PY
    import sys
    lines = sys.stdin.read().split('\n')
    out, i, n = [], 0, len(lines)
    have_authn = any('name: authentication-config' in l for l in lines)
    inserted = have_authn
    while i < n:
        ln = lines[i]; s = ln.strip()
        if s.startswith('- name: oidc-'):
            i += 2 if (i + 1 < n and lines[i + 1].strip().startswith('value:')) else 1
            continue
        out.append(ln)
        if (not inserted) and s == '- name: authorization-mode':
            indent = ln[:len(ln) - len(ln.lstrip())]
            if i + 1 < n and lines[i + 1].strip().startswith('value:'):
                out.append(lines[i + 1]); i += 2
            else:
                i += 1
            out.append(indent + '- name: authentication-config')
            out.append(indent + '  value: /etc/kubernetes/pki/auth-config.yaml')
            inserted = True
            continue
        i += 1
    if not inserted:
        sys.stderr.write('ANCHOR-NOT-FOUND: authorization-mode\n'); sys.exit(3)
    sys.stdout.write('\n'.join(out))
  PY

  # Whole remote operation, base64-embedded for byte-exact transfer (no
  # heredoc/escaping hazards across SSH).
  apiserver_auth_remote_script = <<-SH
    MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
    AUTHCFG=/etc/kubernetes/pki/auth-config.yaml
    TS=$(date +%s)

    # 1. Write the structured AuthenticationConfiguration (hot-reloaded by the
    #    apiserver on change; mounted into the pod via the existing pki hostPath).
    echo '${base64encode(local.apiserver_auth_config_yaml)}' | base64 -d | sudo tee "$AUTHCFG" >/dev/null
    sudo chmod 600 "$AUTHCFG"

    # 2. Ensure the apiserver references it. Only touch the manifest (→ restart)
    #    when the flag is missing; otherwise the file write above hot-reloads.
    if ! sudo grep -q -- '--authentication-config=' "$MANIFEST"; then
      sudo cp "$MANIFEST" "$MANIFEST.bak.$TS"
      sudo sed -i '/--oidc-issuer-url/d;/--oidc-client-id/d;/--oidc-username-claim/d;/--oidc-groups-claim/d' "$MANIFEST"
      echo '${base64encode(local.apiserver_flag_insert_py)}' | base64 -d | sudo python3 - "$MANIFEST"
    fi

    # 3. Fail loudly if the flag still isn't present (e.g. anchor not found).
    if ! sudo grep -q -- '--authentication-config=' "$MANIFEST"; then
      echo "ERROR: --authentication-config absent after edit"; exit 1
    fi

    # 4. Health-gate on /livez; auto-rollback the manifest if it never recovers.
    echo "Waiting for kube-apiserver /livez ..."
    ok=0
    for i in $(seq 1 60); do
      sleep 2
      if curl -sk https://localhost:6443/livez 2>/dev/null | grep -q '^ok'; then ok=1; break; fi
    done
    if [ "$ok" != "1" ]; then
      echo "kube-apiserver UNHEALTHY after change — rolling back"
      BAK=$(ls -t "$MANIFEST".bak.* 2>/dev/null | head -1)
      if [ -n "$BAK" ]; then sudo cp "$BAK" "$MANIFEST"; fi
      for i in $(seq 1 60); do sleep 2; if curl -sk https://localhost:6443/livez 2>/dev/null | grep -q '^ok'; then break; fi; done
      echo "rolled back to previous manifest"; exit 1
    fi
    echo "kube-apiserver healthy with multi-issuer --authentication-config"

    # 5. Reconcile kubeadm-config so a FUTURE `kubeadm upgrade` regenerates the
    #    apiserver manifest WITH --authentication-config instead of reverting to
    #    the stale single-issuer --oidc-* flags. Without this, kubeadm rewrote the
    #    manifest from kubeadm-config on every control-plane upgrade and the
    #    regenerated apiserver crash-looped (the 2026-06-24 v1.35 upgrade stall).
    #    Zero live impact (the CM is only read at upgrade time); idempotent;
    #    best-effort (the chain's `kubeadm upgrade diff` preflight gate is the
    #    backstop if this cannot run).
    KC="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"
    CC=$($KC -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null || true)
    if [ -n "$CC" ] && { echo "$CC" | grep -q 'oidc-issuer-url' || ! echo "$CC" | grep -q 'authentication-config'; }; then
      echo "Reconciling kubeadm-config (oidc-* -> authentication-config) so kubeadm upgrade keeps structured auth"
      echo '${base64encode(local.kubeadm_oidc_reconcile_py)}' | base64 -d > /tmp/reconcile_kubeadm_oidc.py
      if printf '%s' "$CC" | python3 /tmp/reconcile_kubeadm_oidc.py > /tmp/kubeadm-cc-new.yaml \
         && sudo kubeadm init phase upload-config kubeadm --config /tmp/kubeadm-cc-new.yaml; then
        echo "kubeadm-config reconciled: future control-plane upgrades keep --authentication-config"
      else
        echo "WARN: kubeadm-config reconcile failed; the upgrade-chain preflight gate will block the next upgrade"
      fi
      rm -f /tmp/reconcile_kubeadm_oidc.py /tmp/kubeadm-cc-new.yaml
    else
      echo "kubeadm-config already uses --authentication-config (no oidc drift)"
    fi
  SH
}

resource "null_resource" "apiserver_oidc_config" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${base64encode(local.apiserver_auth_remote_script)}' | base64 -d | bash",
    ]
  }

  triggers = {
    # Intentionally hash ONLY the issuer config, NOT the remote script. CI applies
    # the rbac stack with no ssh_private_key (var defaults to ""), so a re-run of
    # this SSH provisioner in CI would fail — hence the null_resource must stay a
    # no-op on a plain CI apply. Script changes (e.g. the 2026-06-24 kubeadm-config
    # reconciliation) reach the cluster via the apiserver-oidc-restore ConfigMap
    # below (a plain k8s resource, no ssh) which the upgrade chain re-runs. To force
    # this provisioner to re-run after a script change, apply locally with
    # `-replace` + TF_VAR_ssh_private_key (see docs/runbooks/k8s-version-upgrade.md).
    auth_config = sha256(local.apiserver_auth_config_yaml)
  }
}

# Publish the restore script to a ConfigMap so the k8s-version-upgrade chain can
# re-apply apiserver OIDC on master immediately after a `kubeadm upgrade` (which
# regenerates the apiserver manifest and drops --authentication-config → breaks
# SSO). This is the SAME script the null_resource above runs over SSH, so the
# rbac stack stays the single source of truth — the chain just re-runs it
# post-upgrade (phase_master in
# stacks/k8s-version-upgrade/scripts/upgrade-step.sh) instead of waiting for a
# manual `tg apply`. Content is config (issuer URLs + claim mappings), not
# secrets, so a ConfigMap is appropriate.
resource "kubernetes_config_map_v1" "apiserver_oidc_restore" {
  metadata {
    name      = "apiserver-oidc-restore"
    namespace = "kube-system"
  }
  data = {
    "restore.sh" = local.apiserver_auth_remote_script
  }
}
