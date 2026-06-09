# SOPS Multi-User Secrets Migration — Design Document (v3)

## Goal
Enable non-technical operators to manage cluster services via PR → review → merge → CI apply, without access to secrets. Viktor retains full local apply capability.

## Current State
- **terraform.tfvars**: 211 variables (mix of secrets + non-secret config), git-crypt encrypted as a whole
- **secrets/**: TLS certs, deploy keys, NFS config — git-crypt encrypted (binary files)
- **.gitattributes**: encrypts `*.tfvars`, `*.tfstate`, `secrets/**`
- **Woodpecker CI**: unlocks git-crypt via K8s ConfigMap, applies `stacks/platform/` on push
- **Terragrunt**: loads `terraform.tfvars` via `required_var_files` for all stacks

## Design

### 1. Split terraform.tfvars into Two Files

**`config.tfvars`** (NOT encrypted — committed in plaintext):
Non-secret configuration that operators need to read/edit:
- `nfs_server`, `redis_host`, `postgresql_host`, `mysql_host`, `ollama_host`, `mail_host`
- `bind_db_viktorbarzin_me`, `bind_db_viktorbarzin_lan`, `bind_named_conf_options`
- `tls_secret_name`, `client_certificate_secret_name`
- WireGuard peer **public** keys and AllowedIPs only — **NOT** `wireguard_wg_0_conf` (contains private key inline), NOT any `PrivateKey` fields
- Cloudflare DNS zone definitions (record names, not tokens)

**`secrets.sops.json`** (SOPS-encrypted, per-value, JSON format):
All actual secrets, including complex types. JSON format chosen because:
- `sops -d` outputs the same format as input — JSON in, JSON out
- Terraform natively supports `*.auto.tfvars.json` files
- JSON supports all Terraform types: strings, maps, lists, nested objects
- No format conversion needed in the decryption pipeline

**Complex types** in JSON (these are NOT flat strings):
```json
{
  "hackmd_db_password": "simple-string-secret",
  "mailserver_accounts": {
    "info@viktorbarzin.me": "password1",
    "admin@viktorbarzin.me": "password2"
  },
  "homepage_credentials": {
    "technitium": {"token": "abc123"},
    "crowdsec": {"username": "user", "password": "pass"}
  },
  "k8s_users": {
    "viktor": {"role": "admin", "email": "v@example.com", "namespaces": []}
  },
  "xray_reality_clients": [
    {"id": "uuid-here", "flow": "xtls-rprx-vision"}
  ],
  "webhook_handler_ssh_key": "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn...\n-----END OPENSSH PRIVATE KEY-----\n",
  "wireguard_wg_0_conf": "[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\n..."
}
```

### 2. SOPS Configuration

```yaml
# .sops.yaml
creation_rules:
  - path_regex: ^secrets\.sops\.json$
    age: >-
      age1viktor_public_key,
      age1ci_public_key
```

Path regex anchored to repo root (`^`). All secrets encrypted to Viktor + CI.

### 3. Terragrunt Changes

```hcl
# terragrunt.hcl — updated variable loading
terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    required_var_files = [
      "${get_repo_root()}/config.tfvars"
    ]
  }

  extra_arguments "secrets" {
    commands = get_terraform_commands_that_need_vars()
    optional_var_files = [
      "${get_repo_root()}/secrets.auto.tfvars.json"
    ]
  }

  # Safety check: fail loudly if secrets file is missing (prevents silent apply with empty secrets)
  before_hook "check_secrets" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["test", "-f", "${get_repo_root()}/secrets.auto.tfvars.json"]
  }
}
```

**Global decrypt-once wrapper** (run instead of raw terragrunt):
```bash
#!/usr/bin/env bash
# scripts/tg — wrapper: decrypt then terragrunt
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOPS_FILE="$REPO_ROOT/secrets.sops.json"
OUT_FILE="$REPO_ROOT/secrets.auto.tfvars.json"

if [ ! -f "$OUT_FILE" ] && [ -f "$SOPS_FILE" ]; then
  TEMP=$(mktemp "$OUT_FILE.XXXXXX")
  trap "rm -f '$TEMP'" EXIT
  sops -d "$SOPS_FILE" > "$TEMP"
  mv "$TEMP" "$OUT_FILE"
  echo "Decrypted secrets → secrets.auto.tfvars.json"
fi

exec terragrunt "$@"
```

Usage: `scripts/tg apply --non-interactive` instead of `terragrunt apply --non-interactive`.

**Why not before_hook/after_hook for decryption?** When using `run --all`, each of 70+ stacks would run hooks in parallel, all writing to the same file — race condition. The wrapper decrypts once.

**Why before_hook for the existence check?** It's read-only (just `test -f`) — safe in parallel. Fails loudly if someone forgets to decrypt, instead of silently applying with empty secrets.

### 4. File Protection

**.gitignore** (add these entries):
```
/secrets.auto.tfvars.json
/secrets.auto.tfvars.json.*
```

**.gitattributes** changes (done atomically in Phase 4):
```
# KEEP for binary files
secrets/** filter=git-crypt diff=git-crypt
*.tfstate filter=git-crypt diff=git-crypt

# REMOVED: *.tfvars filter=git-crypt diff=git-crypt
```

### 5. Woodpecker CI Pipeline Changes

**default.yml**:
```yaml
steps:
  - name: prepare
    image: alpine
    commands:
      - "apk update && apk add jq curl git git-crypt"
      # git-crypt for secrets/ directory (TLS certs, deploy key)
      # Note: K8s Secret .data values are base64-encoded by the API
      - |
        curl -k https://10.0.20.100:6443/api/v1/namespaces/woodpecker/secrets/git-crypt-key \
          -H "Authorization:Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
          | jq -r '.data.key' | base64 -d > /tmp/key
      - "git-crypt unlock /tmp/key && rm /tmp/key"
      # Install SOPS to workspace (shared across steps via workspace volume)
      - "wget -qO ./sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64"
      - "echo '848ac8ee4b4e3ae1e72a58f0e9bae04b3e85ca59fa06f0dcd2d32b76542e8417  ./sops' | sha256sum -c"
      - "chmod +x ./sops"
      # Write age key to file (Woodpecker from_secret injects as env var, not file)
      - "echo \"$SOPS_AGE_KEY\" > /tmp/age-key.txt"
      - "SOPS_AGE_KEY_FILE=/tmp/age-key.txt ./sops -d secrets.sops.json > secrets.auto.tfvars.json"
      - "shred -u /tmp/age-key.txt"
    environment:
      SOPS_AGE_KEY:
        from_secret: sops_age_key  # CI's age private key material

  - name: terragrunt-plan
    image: alpine
    commands:
      - "apk update && apk add curl unzip git openssh-client"
      - "wget -qO /tmp/tf.zip https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip"
      - "unzip -o /tmp/tf.zip -d /usr/local/bin/ && chmod 755 /usr/local/bin/terraform"
      - "wget -qO /usr/local/bin/terragrunt https://github.com/gruntwork-io/terragrunt/releases/download/v0.99.4/terragrunt_linux_amd64"
      - "chmod 755 /usr/local/bin/terragrunt"
      - "cd stacks/platform && terragrunt plan --non-interactive -out=tfplan 2>&1 | grep -v 'sensitive'"
    when:
      event: pull_request

  - name: terragrunt-apply
    image: alpine
    commands:
      - "apk update && apk add curl unzip git openssh-client"
      - "wget -qO /tmp/tf.zip https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip"
      - "unzip -o /tmp/tf.zip -d /usr/local/bin/ && chmod 755 /usr/local/bin/terraform"
      - "wget -qO /usr/local/bin/terragrunt https://github.com/gruntwork-io/terragrunt/releases/download/v0.99.4/terragrunt_linux_amd64"
      - "chmod 755 /usr/local/bin/terragrunt"
      - "cd stacks/platform && terragrunt apply --non-interactive -auto-approve"
    when:
      event: push
      branch: master

  - name: cleanup-and-push
    image: alpine
    commands:
      - "rm -f secrets.auto.tfvars.json secrets.auto.tfvars.json.*"
      - "apk update && apk add openssh-client git git-crypt"
      - "mkdir -p ~/.ssh && ssh-keyscan -H github.com >> ~/.ssh/known_hosts"
      - "chmod 400 secrets/deploy_key"
      - "git add stacks/ state/ .woodpecker/ || true"
      - "git remote set-url origin git@github.com:ViktorBarzin/infra.git"
      - "git commit -m 'Woodpecker CI deploy commit [CI SKIP]' || echo 'No changes'"
      - "GIT_SSH_COMMAND='ssh -i ./secrets/deploy_key -o IdentitiesOnly=yes' git push origin master"
    when:
      - event: push
        branch: master
      - status: [success, failure]  # Always clean up, even on failure

  - name: slack
    image: curlimages/curl
    commands:
      - |
        curl -s -X POST -H 'Content-type: application/json' \
          --data "{\"text\":\"Woodpecker CI: infra pipeline ${CI_PIPELINE_STATUS}\"}" \
          "$SLACK_WEBHOOK" || true
    environment:
      SLACK_WEBHOOK:
        from_secret: slack_webhook
    when:
      - status: [success, failure]
```

**renew-tls.yml** — ALSO update this pipeline:
- Change `git add .` to `git add secrets/ state/` in the `commit-certs` step
- Same defense-in-depth as default.yml

Key design decisions:
- `SOPS_AGE_KEY` (env var, not file) — Woodpecker `from_secret` only supports env vars. The prepare step writes it to a temp file, uses `SOPS_AGE_KEY_FILE`, then `shred`s the file
- SOPS binary in workspace (shared volume) — not per-container `/usr/local/bin/`
- `cleanup-and-push` runs on `status: [success, failure]` — always cleans up decrypted file
- `git add stacks/ state/ .woodpecker/` — never `git add .`
- Plan output filtered through `grep -v sensitive` — belt-and-suspenders with `sensitive = true`

### 6. Branch Protection (Required)

GitHub branch protection on `master`:
- **Require pull request reviews**: at least 1 reviewer (Viktor)
- **Restrict who can push**: Viktor only (direct push for `[ci skip]` commits)
- **Restrict who can dismiss reviews**: Viktor only

This prevents operators from modifying `.woodpecker/`, `terragrunt.hcl`, or `.sops.yaml` without review.

**Residual risk**: An operator can add `provisioner "local-exec" { command = "echo ${var.secret}" }` in a PR. Viktor must catch this in review. Mitigated by: (1) PR review is required, (2) `sensitive = true` hides values in plan output, (3) `local-exec` provisioners are unusual in this codebase and should be flagged during review.

### 7. K8s RBAC for Operators

Scoped operator role — no cluster-wide secrets access:

```hcl
resource "kubernetes_cluster_role" "operator" {
  metadata { name = "cluster-operator" }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "endpoints", "configmaps", "events"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }
}

# Per-namespace full access (edit role includes secrets within namespace — accepted residual risk)
resource "kubernetes_role_binding" "operator_namespace" {
  for_each = toset(var.operator_namespaces)
  metadata {
    name      = "operator-access"
    namespace = each.value
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "edit"
  }
  subject {
    kind = "Group"
    name = "operators"
  }
}
```

**Excluded namespaces** (never in `operator_namespaces`): `woodpecker`, `kube-system`, `dbaas`, `monitoring`, `authentik`.

### 8. Operator Workflow

**Setup (one-time)**: GitHub collaborator + Authentik "operators" group. No encryption keys, no local tools beyond git.

**Day-to-day**: Create branch → edit → push → open PR → Viktor reviews → merge → CI applies → Slack notification.

**kubectl**: `kubectl oidc-login` → Authentik → scoped to assigned namespaces.

**New secrets**: Comment on PR, Viktor adds to `secrets.sops.json`.

### 9. Migration Plan (Phased)

**Phase 1 — Setup tooling (no functional change)**
- Install `sops` and `age` locally (Docker)
- Generate age keys: Viktor + CI
- Store CI age key as Woodpecker secret (`sops_age_key`)
- Move git-crypt key from K8s ConfigMap to Secret (update RBAC for Woodpecker SA)
- Create `.sops.yaml` config file
- Add `/secrets.auto.tfvars.json` to `.gitignore`
- Create `scripts/tg` wrapper
- Backup Viktor's age private key to Vaultwarden

**Phase 2 — Create SOPS file alongside existing tfvars**
- Categorize all 211 variables: secret vs. non-secret (WireGuard private keys → secrets)
- Extract non-secret config into `config.tfvars` (plaintext)
- Extract secrets into `secrets.sops.json` (JSON, including complex types: maps, lists, nested objects)
- Encrypt with SOPS
- Verify round-trip: `sops -d secrets.sops.json | jq .` produces valid JSON
- Verify SSH keys: `sops -d secrets.sops.json | jq -r '.truenas_ssh_private_key' | ssh-keygen -l -f -`
- Verify complex types: `sops -d secrets.sops.json | jq '.mailserver_accounts'` returns expected map
- Add `sensitive = true` to ALL secret variable declarations across all stacks (BEFORE CI plan step is enabled)

**Phase 3 — Switch terragrunt to SOPS**
- Update `terragrunt.hcl`: `config.tfvars` (required) + `secrets.auto.tfvars.json` (optional) + existence check hook
- Test: `scripts/tg apply --non-interactive` works per-stack
- Test: `scripts/tg run --all -- plan` works (no race condition)
- Test failure mode: delete `secrets.auto.tfvars.json`, verify `before_hook` fails loudly

**Phase 4 — Atomic cutover**
- Step 1: `git rm terraform.tfvars` (removes file while git-crypt filter still active — clean deletion)
- Step 2: Remove `*.tfvars filter=git-crypt` from `.gitattributes`
- Step 3: `git commit` both changes

**Phase 5 — Update CI pipelines**
- Update `.woodpecker/default.yml` with new pipeline
- Update `.woodpecker/renew-tls.yml`: change `git add .` to `git add secrets/ state/`
- Add `sops_age_key` Woodpecker secret
- Enable GitHub branch protection on master
- Test: CI pipeline applies successfully

**Phase 6 — Security hardening**
- Create scoped operator RBAC role
- Remove `secrets` from `power-user` ClusterRole
- Update CLAUDE.md and AGENTS.md documentation

**Phase 7 — Onboard operator**
- Add as GitHub collaborator
- Create Authentik account in "operators" group
- Walk through first PR workflow

### 10. Rollback Plan
- **Phase 1-2**: No functional change — delete SOPS artifacts
- **Phase 3**: Revert `terragrunt.hcl` to load `terraform.tfvars`
- **Phase 4+**: `git show HEAD~1:terraform.tfvars > terraform.tfvars`, re-add `.gitattributes` rule. Backfill any secrets added during SOPS period.
- Git-crypt stays functional for `secrets/` and `*.tfstate`

### 11. What Stays with git-crypt
- `secrets/` directory: TLS certs, deploy keys (binary)
- `*.tfstate` files: Terraform state
- git-crypt key: K8s **Secret** in `woodpecker` namespace (migrated from ConfigMap)

### 12. Security Considerations
- **Decrypted file**: temporary, `.gitignore`d, never staged by CI, cleaned up on success AND failure
- **CI staging**: `git add stacks/ state/ .woodpecker/` — never `git add .` (all pipelines)
- **Age key in CI**: `SOPS_AGE_KEY` env var → written to temp file → `SOPS_AGE_KEY_FILE` → `shred` after use
- **Age key backup**: Viktor's in Vaultwarden. CI's as Woodpecker secret
- **Branch protection**: Operators cannot modify CI pipeline, terragrunt.hcl, or .sops.yaml without review
- **RBAC**: Operator role excludes cluster-wide secrets. Namespace `edit` role allows secrets within assigned namespaces (accepted residual risk). Excluded: woodpecker, kube-system, dbaas, monitoring, authentik
- **Terraform variables**: `sensitive = true` on all secret vars — applied in Phase 2 BEFORE plan step is enabled
- **Plan output**: filtered through `grep -v sensitive` as belt-and-suspenders
- **`local-exec` exfiltration**: residual risk mitigated by PR review requirement — Viktor must review all PRs
- **State files**: contain secret values, git-crypt encrypted. Future: remote backend
- **Rotation**: new CI age key → re-encrypt → update Woodpecker secret → rotate affected secrets
- **Git history**: old `terraform.tfvars` remains git-crypt encrypted in history — recoverable only with git-crypt key (K8s Secret, not accessible to operators)
