---
name: sops-age-secrets-migration
description: |
  Migrate from git-crypt to SOPS + age for multi-user secret management in a
  Terraform/Terragrunt infrastructure repo. Use when: (1) need per-user secret
  access control (git-crypt is all-or-nothing), (2) want operators to push PRs
  without seeing secrets (CI decrypts), (3) migrating from a single encrypted
  terraform.tfvars to structured secret management. Covers: JSON format (not YAML
  — Terraform can't parse YAML tfvars), race condition avoidance with parallel
  terragrunt applies, CI pipeline integration with Woodpecker, age key management,
  and the complete migration sequence.
author: Claude Code
version: 1.0.0
date: 2026-03-07
---

# SOPS + age Secrets Migration from git-crypt

## Problem
git-crypt encrypts entire files — anyone with the key decrypts everything. For multi-user
setups where operators should push code without seeing secrets, you need per-value encryption
with CI-only decryption.

## Context / Trigger Conditions
- Single `terraform.tfvars` encrypted with git-crypt containing 100+ secrets
- Need to onboard operators who shouldn't see API keys, passwords, SSH keys
- Want GitOps (secrets in git) but with access control
- Terraform/Terragrunt stack-per-service architecture

## Solution

### 1. Use JSON, not YAML
SOPS outputs the same format as input. `sops -d file.yaml` → YAML. `sops -d file.json` → JSON.
Terraform natively supports `*.auto.tfvars.json` files. YAML is NOT valid HCL.

```
secrets.sops.json → sops -d → secrets.auto.tfvars.json → Terraform reads it
```

### 2. Split tfvars into config + secrets
```
config.tfvars          ← plaintext (hostnames, IPs, DNS records)
secrets.sops.json      ← SOPS-encrypted (passwords, tokens, keys)
```

### 3. Global decrypt, not per-stack hooks
**CRITICAL**: Do NOT use `before_hook`/`after_hook` for decryption. With `terragrunt run --all`,
70+ stacks run hooks in parallel, all writing to the same output file — race condition.

Instead, use a wrapper script that decrypts once:
```bash
#!/usr/bin/env bash
# scripts/tg — decrypt then terragrunt
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "$REPO_ROOT/secrets.auto.tfvars.json" ] || \
   [ "$REPO_ROOT/secrets.sops.json" -nt "$REPO_ROOT/secrets.auto.tfvars.json" ]; then
  sops -d "$REPO_ROOT/secrets.sops.json" > "$REPO_ROOT/secrets.auto.tfvars.json"
fi
exec terragrunt "$@"
```

### 4. Terragrunt loads both (backward compatible)
```hcl
terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    required_var_files = ["${get_repo_root()}/config.tfvars"]
    optional_var_files = [
      "${get_repo_root()}/terraform.tfvars",        # legacy (git-crypt)
      "${get_repo_root()}/secrets.auto.tfvars.json"  # new (SOPS)
    ]
  }
  before_hook "check_secrets" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["test", "-f", "${get_repo_root()}/secrets.auto.tfvars.json"]
  }
}
```

### 5. Complex types work in JSON
Maps, lists, nested objects, multiline strings (SSH keys as `\n`-escaped) all work:
```json
{
  "simple_password": "abc123",
  "mailserver_accounts": {"user@domain": "pass"},
  "ssh_key": "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn...\n-----END OPENSSH PRIVATE KEY-----\n"
}
```

### 6. CI integration (Woodpecker)
- Store age private key as CI secret (`SOPS_AGE_KEY`)
- Write to temp file for `SOPS_AGE_KEY_FILE` (Woodpecker `from_secret` only does env vars)
- `git add stacks/ state/ .woodpecker/` — NEVER `git add .`
- Cleanup step with `status: [success, failure]`

## Verification
```bash
# Encrypt
sops -e -i secrets.sops.json

# Decrypt and verify
sops -d secrets.sops.json | jq .

# Verify SSH keys
sops -d secrets.sops.json | jq -r '.ssh_key' | ssh-keygen -l -f -

# Test with terragrunt
scripts/tg validate
```

## Notes
- Keep git-crypt for binary files (TLS certs, deploy keys) — SOPS can't encrypt binary
- `sensitive = true` on all secret variable declarations — prevents plan output leaks
- Don't add `sensitive = true` to non-secret variables with "secret" in the name (e.g., `tls_secret_name`, `ingress_path`) — breaks `for_each` on lists
- Age keys are one line — much simpler than GPG
- `.sops.yaml` path_regex should be anchored: `^secrets\.sops\.json$`
