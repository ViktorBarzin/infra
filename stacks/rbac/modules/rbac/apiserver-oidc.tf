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
# DRIFT WARNING: this edits the kube-apiserver static-pod manifest on the single
# master. A `kubeadm upgrade` regenerates that manifest and DROPS this flag (this
# is exactly how OIDC silently broke before — the flag was wiped and the
# content-hash trigger never re-fired). After any k8s control-plane upgrade,
# re-apply the rbac stack to restore apiserver OIDC. See
# docs/plans/2026-06-04-k8s-dashboard-sso-design.md.
#
# SAFETY: the remote script health-gates on /livez and AUTO-ROLLS-BACK the
# manifest from a timestamped backup if the apiserver does not recover, so a
# malformed config cannot leave the single master down.

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
    auth_config = sha256(local.apiserver_auth_config_yaml)
  }
}
