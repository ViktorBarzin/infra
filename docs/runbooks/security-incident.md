# Security Incident Response

What to do when a wave-1 security alert fires. Each alert links to a Loki query for investigation and concrete remediation steps.

**Status: planned, not yet implemented.** Beads epic: `code-8ywc`. This runbook is the response playbook for when wave 1 ships.

## General workflow

1. **Acknowledge in Alertmanager.** Silence only after triage starts.
2. **Pull context from Loki** (queries below). Get the actor, source IP, timestamp.
3. **Decide: real or false-positive?** Use the "false-positive cases" notes below.
4. **If real:** revoke credentials (Vault token revoke, K8s SA token rotate, SSH key remove, OIDC session invalidate), then post-mortem.
5. **If false-positive:** tune the alert (extend allowlist, refine LogQL query).

## Allowlist CIDRs

All source-IP-based alerts (K2, K9, V7, S1) reference this list. It is **inlined as a regex** in each rule's `expr` in `stacks/monitoring/modules/monitoring/loki.tf` (there is no shared `security_source_ip_allowlist` variable — update every rule when the list changes).

- `10.0.20.0/22` — VLAN 20 (cluster + main LAN)
- `10.0.10.0/24` — VLAN 10 (devvm) — **K2/K9 only** (added 2026-07-06; devvm uses SA-token kubeconfigs, e.g. chrome-service port-forward). Add to V7/S1 if devvm Vault-OIDC / PVE-ssh becomes normal.
- `192.168.1.0/24` — Proxmox + Sofia LAN
- K8s pod CIDR `10.10.0.0/16`
- K8s service CIDR `10.96.0.0/12`
- Headscale tailnet `100.64.0.0/10`

**Anything outside = alert.** No public-IP exceptions.

## Viktor's identity

`me@viktorbarzin.me` is the ONLY allowlisted human identity. NOT `viktor@viktorbarzin.me`. NOT `emo@viktorbarzin.me`. emo's identity scheme is separate and must be added explicitly if/when needed.

---

## K-alerts (K8s API audit)

### K2 — ServiceAccount token used from outside cluster

**Meaning:** A K8s ServiceAccount token authenticated a request whose `sourceIPs[0]` is not in the pod CIDR or trusted LAN. Stolen SA token used externally.

```logql
{job="kubernetes-audit"} | json user_username="user.username", sourceIPs_0="sourceIPs[0]" | user_username =~ "system:serviceaccount:.*" | sourceIPs_0 != "" | sourceIPs_0 !~ "10\\.0\\.2[0-3]\\..*|192\\.168\\.1\\..*|10\\.0\\.10\\..*|10\\.10\\..*|10\\.(9[6-9]|1[01][0-9]|111)\\..*|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\..*"
```

> **Note (2026-07-06):** use **explicit** array extraction `| json sourceIPs_0="sourceIPs[0]"` — a bare `| json` does NOT populate `sourceIPs_0` (arrays aren't auto-indexed), so the old query matched every SA event. The `sourceIPs_0 != ""` guard is required.

**Action:** Identify the SA. Rotate its token (`kubectl delete secret <sa-token-name>` if old-style, or recreate the SA if projected token). Audit the SA's permissions and tighten.

**False positives:** The devvm (`10.0.10.10`, VLAN 10) legitimately uses SA-token kubeconfigs (e.g. `chrome-service:emo-browser` kubectl port-forward) — allowlisted since 2026-07-06. Pod-to-apiserver traffic that egresses and re-enters via NodePort/LB (rare). Investigate the originating workload.

### K3 — Secret read in sensitive namespace by unexpected actor

**Meaning:** A Secret in `vault`, `sealed-secrets`, or `external-secrets` namespace was read by an SA NOT in the allowlist (ESO controller, sealed-secrets controller, Vault SA, `me@viktorbarzin.me`).

```logql
{job="kubernetes-audit"} | json | verb =~ "get|list" | objectRef_resource = "secrets" | objectRef_namespace =~ "vault|sealed-secrets|external-secrets" | user_username !~ "(me@viktorbarzin.me|system:serviceaccount:external-secrets:.*|system:serviceaccount:sealed-secrets:.*|system:serviceaccount:vault:.*)"
```

**Action:** Identify the actor. If a service account, audit its bindings — it shouldn't have RBAC to read those secrets. Revoke the binding. Rotate any secrets that were read.

### K4 — Exec into sensitive pod

**Meaning:** Someone `kubectl exec`'d into a pod in `vault`, `kube-system`, `dbaas`, or `cnpg-system`.

```logql
{job="kubernetes-audit"} | json | verb = "create" | objectRef_resource = "pods" | objectRef_subresource = "exec" | objectRef_namespace =~ "vault|kube-system|dbaas|cnpg-system" | user_username != "me@viktorbarzin.me"
```

**Action:** Determine if Viktor authorized the exec. If unrecognized actor, revoke their access and rotate any credentials they could have read inside the pod.

**False positives:** Break-glass SAs used during incident response — extend the allowlist to include them by SA name.

### K5 — Mass delete

**Meaning:** Single actor deleted >5 Pods, Secrets, or ConfigMaps in 60 seconds. Either a script gone wrong or destructive intrusion.

```logql
sum by (user_username) (count_over_time({job="kubernetes-audit"} | json | verb = "delete" | objectRef_resource =~ "pods|secrets|configmaps" | user_username !~ "^system:(node:.+|serviceaccount:(kube-system:(generic-garbage-collector|namespace-controller)|woodpecker:.+))$" [1m])) > 5
```

> **Note (2026-07-06):** the rule **excludes legitimate bulk-deleters** — kubelets (`system:node:*`), the kube-system `generic-garbage-collector` + `namespace-controller`, and woodpecker CI — which otherwise flapped SECURITY/CRITICAL+RESOLVED on every routine cleanup burst. A human (`me@viktorbarzin.me`/`kubernetes-admin`) or an app-namespace SA still fires. If another controller starts flapping this alert, add it to the exclusion regex in `stacks/monitoring/modules/monitoring/loki.tf` (K5) rather than widening the whole rule.

**Action:** Identify actor. If a Terraform apply or known cleanup job, false positive. If unrecognized, suspend the actor's credentials immediately and audit what was deleted.

### K6 — Audit policy modified

**Meaning:** Someone changed the kube-apiserver audit policy. Should only happen via Terraform.

**Action:** Verify the change came from a planned Terraform apply (check recent commits to `stacks/infra`). If not, treat as critical compromise — attacker disabling visibility.

### K7 — New ClusterRole with full wildcards

**Meaning:** A new ClusterRole was created with `verbs: ["*"]` and `resources: ["*"]`. Privilege escalation primitive.

```logql
{job="kubernetes-audit"} | json | verb = "create" | objectRef_resource = "clusterroles" | requestObject_rules_0_verbs_0 = "*" | requestObject_rules_0_resources_0 = "*"
```

**Action:** Verify the change is intentional (some operators install such roles — calico, kyverno). If unrecognized, delete the ClusterRole and audit the creator.

### K8 — Anonymous binding

**Meaning:** A RoleBinding or ClusterRoleBinding was created referencing `system:anonymous` or `system:unauthenticated`. Catastrophic — allows unauthenticated cluster access.

**Action:** Delete the binding immediately. Audit who created it. Treat as full cluster compromise — rotate all secrets, force kubeconfig re-issue.

### K9 — Viktor's identity from unexpected source IP

**Meaning:** A request authenticated as `me@viktorbarzin.me` arrived from a source IP outside the allowlist. Stolen OIDC token / kubeconfig.

```logql
{job="kubernetes-audit"} | json user_username="user.username", sourceIPs_0="sourceIPs[0]" | user_username = "me@viktorbarzin.me" | sourceIPs_0 != "" | sourceIPs_0 !~ "10\\.0\\.2[0-3]\\..*|192\\.168\\.1\\..*|10\\.0\\.10\\..*|10\\.10\\..*|10\\.(9[6-9]|1[01][0-9]|111)\\..*|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\..*"
```

**Action:** Revoke Viktor's OIDC session in Authentik. Rotate Vault OIDC tokens. Audit recent activity from that IP. Verify Viktor's devices for compromise.

**False positives:** Viktor's machine on a new network without VPN — should not happen per the "no public IP access" policy. If it does, the policy needs revisiting, not the alert.

---

## V-alerts (Vault audit)

### V1 — Root token created

```logql
{job="vault-audit"} | json | request_path = "auth/token/create" | response_auth_policies = "root"
```

**Action:** Verify against Terraform / planned operation. Root tokens should ONLY be created during initial Vault setup or break-glass.

### V2 — Audit device disabled/modified

**Action:** Attacker silencing visibility. Re-enable immediately. Treat as critical compromise.

### V3 — Seal status changed

**Action:** Verify whether this is a planned operation (unseal during upgrade). If unplanned, treat as critical.

### V4 — Policy modified

**Action:** Confirm change came from a Terraform apply. Allowlist Terraform's source IP / token role. Otherwise: review the policy diff, revert if malicious.

### V5 — Auth failure spike

**Action:** Identify the auth method and source. If CI token rotation, false positive. If unknown source brute-forcing, block the source IP at pfSense.

### V6 — Token with policies different from parent

**Action:** Privilege escalation attempt. Revoke the new token. Audit the parent token's policies.

### V7 — Viktor's Vault identity from unexpected source IP

**Meaning:** A Vault operation authenticated as Viktor's entity_id arrived from an IP not in the allowlist. Requires `x_forwarded_for_authorized_addrs` to be configured (Vault sits behind Traefik so `remote_addr` is Traefik's pod IP without XFF trust).

**Action:** Revoke Viktor's Vault OIDC tokens. Force OIDC re-auth. Audit Vault access from that IP.

---

## S-alerts (Host)

### S1 — PVE sshd auth success from unexpected IP

```logql
{job="sshd-pve"} |= "Accepted" | regexp "Accepted (?P<method>\\S+) for (?P<user>\\S+) from (?P<ip>\\S+)" | ip !~ "10\\.0\\.20\\..*|192\\.168\\.1\\..*|<headscale-cidr>"
```

**Action:** Remove the user's SSH key from `/root/.ssh/authorized_keys` if it's still there. Audit recent sudo/login history (`last`, `sudo -i; journalctl _COMM=sudo`). Consider PVE as compromised — rotate root password, audit `/root/.luks-backup-key`, audit `/usr/local/bin/lvm-pvc-snapshot` and backup scripts for tampering.

---

## False-positive triage decision tree

```
Did the alert fire from a known operational event?
├─ Terraform apply at the same time?       → likely V4 (policy modified)
├─ Keel auto-roll?                          → not a security path
├─ CI/CD pipeline running?                  → check V5 / K5
└─ Viktor doing recovery work?              → K4, K9, S1 candidates
                                              Extend allowlist if persistent
```

## Escalation

For SEV1 (multiple alerts, cluster-admin grants, anonymous bindings, mass deletes):

1. Cordon all nodes (`kubectl cordon`) to prevent further pod scheduling — but be aware this also stops legitimate recovery work
2. Revoke all OIDC sessions in Authentik
3. Rotate Vault root keys + reseal
4. Restore from a pre-incident backup if data integrity is questionable
5. Post-mortem per `incident-response.md`

## Related

- [Security architecture](../architecture/security.md)
- [Monitoring architecture](../architecture/monitoring.md)
- [Incident response (general)](../architecture/incident-response.md)
- Beads epic: `code-8ywc`
