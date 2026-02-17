# Multi-User Kubernetes Access Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable multi-user access to the Kubernetes cluster with OIDC authentication via Authentik, Terraform-managed RBAC, audit logging, and a self-service onboarding portal.

**Architecture:** Native OIDC on kube-apiserver (4 flags), Authentik as IdP, three user roles (admin/power-user/namespace-owner), SvelteKit portal for kubeconfig distribution, audit logs to Loki/Grafana.

**Tech Stack:** Terraform (RBAC, deployments), Authentik (OIDC), SvelteKit (portal), kubelogin (kubectl plugin), Loki (audit logs)

**Design document:** `docs/plans/2026-02-17-multi-user-k8s-access-design.md`

---

### Task 1: Create Authentik OIDC Application for Kubernetes

OAuth2 applications are currently created manually in the Authentik UI (not via Terraform provider). Follow this pattern.

**Step 1: Create the OAuth2/OIDC application in Authentik**

Log into Authentik admin at `https://authentik.viktorbarzin.me/if/admin/`.

1. Go to **Applications → Providers → Create**
2. Select **OAuth2/OpenID Connect**
3. Configure:
   - Name: `kubernetes`
   - Authorization flow: `default-provider-authorization-implicit-consent`
   - Client type: `Public`
   - Client ID: `kubernetes` (set manually, don't auto-generate)
   - Redirect URIs: `http://localhost:8000/callback` and `http://localhost:18000/callback` (kubelogin defaults)
   - Scopes: `openid`, `email`, `profile`
   - Subject mode: `Based on the User's Email`
   - Include claims in id_token: **Yes**

4. Go to **Applications → Applications → Create**
   - Name: `Kubernetes`
   - Slug: `kubernetes`
   - Provider: Select the `kubernetes` provider just created

**Step 2: Create a custom scope mapping for groups**

1. Go to **Customization → Property Mappings → Create**
2. Select **Scope Mapping**
3. Configure:
   - Name: `Kubernetes Groups`
   - Scope name: `groups`
   - Expression:
     ```python
     return {
         "groups": [group.name for group in request.user.ak_groups.all()]
     }
     ```

4. Go back to the `kubernetes` provider → Edit → add the `Kubernetes Groups` scope mapping

**Step 3: Create Authentik groups for Kubernetes roles**

1. Go to **Directory → Groups → Create**
2. Create groups:
   - `kubernetes-admins`
   - `kubernetes-power-users`
   - `kubernetes-namespace-owners`
3. Assign your own user to `kubernetes-admins`

**Step 4: Verify OIDC discovery endpoint**

```bash
curl -s https://authentik.viktorbarzin.me/application/o/kubernetes/.well-known/openid-configuration | jq .
```

Expected: JSON with `issuer`, `authorization_endpoint`, `token_endpoint`, `jwks_uri` fields.

**Step 5: Commit a note about the Authentik setup**

No Terraform changes for this step — Authentik apps are managed via UI. Document the client ID in the design doc.

---

### Task 2: Configure kube-apiserver OIDC Flags

The API server runs as a static pod on k8s-master (10.0.20.100). The manifest is at `/etc/kubernetes/manifests/kube-apiserver.yaml`. Kubelet watches this file and auto-restarts the pod on changes.

**Files:**
- Create: `modules/kubernetes/rbac/apiserver-oidc.tf`
- Modify: `modules/kubernetes/main.tf` (add rbac module call)
- Modify: `modules/kubernetes/rbac/main.tf` (will be created in Task 3, but apiserver config is separate)

**Step 1: Create the rbac module directory**

```bash
mkdir -p modules/kubernetes/rbac
```

**Step 2: Create the API server OIDC configuration**

Create `modules/kubernetes/rbac/apiserver-oidc.tf`:

```hcl
# Configure kube-apiserver for OIDC authentication
# This SSHs to k8s-master and adds OIDC flags to the static pod manifest.
# Kubelet auto-restarts the API server when the manifest changes.

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

resource "null_resource" "apiserver_oidc_config" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      # Check if OIDC flags already present
      "if grep -q 'oidc-issuer-url' /etc/kubernetes/manifests/kube-apiserver.yaml; then echo 'OIDC flags already configured'; exit 0; fi",

      # Backup the manifest
      "sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak",

      # Add OIDC flags after the last --etcd flag (safe insertion point)
      "sudo sed -i '/- --tls-private-key-file/a\\    - --oidc-issuer-url=${var.oidc_issuer_url}\\n    - --oidc-client-id=${var.oidc_client_id}\\n    - --oidc-username-claim=email\\n    - --oidc-groups-claim=groups' /etc/kubernetes/manifests/kube-apiserver.yaml",

      # Wait for API server to restart (kubelet watches the manifest)
      "echo 'Waiting for API server to restart...'",
      "sleep 30",
      "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes || echo 'API server still restarting, check manually'",
    ]
  }

  triggers = {
    oidc_issuer_url = var.oidc_issuer_url
    oidc_client_id  = var.oidc_client_id
  }
}
```

**Step 3: Verify the API server accepts OIDC (manual check)**

```bash
ssh wizard@10.0.20.100 "sudo grep oidc /etc/kubernetes/manifests/kube-apiserver.yaml"
```

Expected output:
```
    - --oidc-issuer-url=https://authentik.viktorbarzin.me/application/o/kubernetes/
    - --oidc-client-id=kubernetes
    - --oidc-username-claim=email
    - --oidc-groups-claim=groups
```

---

### Task 3: Create RBAC Terraform Module

**Files:**
- Create: `modules/kubernetes/rbac/main.tf`
- Modify: `modules/kubernetes/main.tf` (add module call + variables)
- Modify: `main.tf` (root, pass ssh_private_key and k8s_users)
- Modify: `terraform.tfvars` (add k8s_users definition)

**Step 1: Create `modules/kubernetes/rbac/main.tf`**

```hcl
variable "tls_secret_name" {}
variable "tier" { type = string }

variable "k8s_users" {
  type = map(object({
    role       = string                          # "admin", "power-user", "namespace-owner"
    email      = string                          # OIDC email claim
    namespaces = optional(list(string), [])       # for namespace-owners
    quota      = optional(object({
      cpu_requests    = optional(string, "2")
      memory_requests = optional(string, "4Gi")
      cpu_limits      = optional(string, "4")
      memory_limits   = optional(string, "8Gi")
      pods            = optional(string, "20")
    }), {})
  }))
  default = {}
}

# --- Admin role ---
# Binds to built-in cluster-admin ClusterRole

resource "kubernetes_cluster_role_binding" "admin_users" {
  for_each = { for name, user in var.k8s_users : name => user if user.role == "admin" }

  metadata {
    name = "oidc-admin-${each.key}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }
}

# --- Power-user role ---
# Can manage workloads cluster-wide but cannot modify RBAC, nodes, or persistent volumes

resource "kubernetes_cluster_role" "power_user" {
  metadata {
    name = "oidc-power-user"
  }

  # Core resources
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec", "services", "endpoints", "configmaps", "secrets", "persistentvolumeclaims", "events", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims"]
    verbs      = ["create", "update", "patch", "delete"]
  }

  # Apps
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Batch
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Networking
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Autoscaling
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Read-only on cluster-level resources
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "power_users" {
  for_each = { for name, user in var.k8s_users : name => user if user.role == "power-user" }

  metadata {
    name = "oidc-power-user-${each.key}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.power_user.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }
}

# --- Namespace-owner role ---
# Full admin within assigned namespaces + read-only cluster-wide

locals {
  # Flatten user→namespace pairs for iteration
  namespace_owner_pairs = flatten([
    for name, user in var.k8s_users : [
      for ns in user.namespaces : {
        user_key  = name
        namespace = ns
        email     = user.email
        quota     = user.quota
      }
    ] if user.role == "namespace-owner"
  ])
}

resource "kubernetes_namespace" "user_namespaces" {
  for_each = { for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair }

  metadata {
    name = each.value.namespace
    labels = {
      tier                    = var.tier
      "k8s-portal/owner"      = each.value.user_key
      "k8s-portal/managed-by" = "rbac-module"
    }
  }
}

resource "kubernetes_role_binding" "namespace_owner" {
  for_each = { for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair }

  metadata {
    name      = "namespace-owner-${each.value.user_key}"
    namespace = each.value.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin" # Built-in ClusterRole with full namespace access
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [kubernetes_namespace.user_namespaces]
}

# Read-only cluster-wide access for namespace owners
resource "kubernetes_cluster_role" "namespace_owner_readonly" {
  metadata {
    name = "oidc-namespace-owner-readonly"
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "namespace_owner_readonly" {
  for_each = { for name, user in var.k8s_users : name => user if user.role == "namespace-owner" }

  metadata {
    name = "oidc-ns-owner-readonly-${each.key}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.namespace_owner_readonly.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }
}

# Resource quotas per user namespace
resource "kubernetes_resource_quota" "user_namespace_quota" {
  for_each = { for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair }

  metadata {
    name      = "user-quota"
    namespace = each.value.namespace
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.quota.cpu_requests
      "requests.memory" = each.value.quota.memory_requests
      "limits.cpu"      = each.value.quota.cpu_limits
      "limits.memory"   = each.value.quota.memory_limits
      "pods"            = each.value.quota.pods
    }
  }

  depends_on = [kubernetes_namespace.user_namespaces]
}

# ConfigMap with user-role mapping for the self-service portal
resource "kubernetes_config_map" "user_roles" {
  metadata {
    name      = "k8s-user-roles"
    namespace = "k8s-portal"
  }

  data = {
    "users.json" = jsonencode({
      for name, user in var.k8s_users : user.email => {
        role       = user.role
        namespaces = user.namespaces
      }
    })
  }
}
```

**Step 2: Add variables and module call to `modules/kubernetes/main.tf`**

Add these variables at the top of the file (after existing variables):

```hcl
variable "k8s_users" {
  type    = map(any)
  default = {}
}
variable "ssh_private_key" {
  type      = string
  default   = ""
  sensitive = true
}
```

Add the module call (after the authentik module block, around line 830):

```hcl
module "rbac" {
  source          = "./rbac"
  for_each        = contains(local.active_modules, "authentik") ? { rbac = true } : {}
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
  k8s_users       = var.k8s_users
  ssh_private_key = var.ssh_private_key
}
```

**Step 3: Pass variables from root `main.tf`**

Add to the `module "kubernetes_cluster"` block (around line 514):

```hcl
  k8s_users       = var.k8s_users
  ssh_private_key = var.ssh_private_key
```

Add the `k8s_users` variable definition at the root level:

```hcl
variable "k8s_users" {
  type    = map(any)
  default = {}
}
```

**Step 4: Add users to `terraform.tfvars`**

```hcl
k8s_users = {
  "viktor" = {
    role       = "admin"
    email      = "viktor@viktorbarzin.me"
    namespaces = []
  }
}
```

**Step 5: Run terraform plan to verify**

```bash
terraform plan -target=module.kubernetes_cluster.module.rbac -var="kube_config_path=$(pwd)/config"
```

Expected: Plan shows ClusterRoleBinding for admin user, power-user ClusterRole, namespace-owner ClusterRole, and ConfigMap creation.

**Step 6: Apply**

```bash
terraform apply -target=module.kubernetes_cluster.module.rbac -var="kube_config_path=$(pwd)/config" -auto-approve
```

**Step 7: Commit**

```bash
git add modules/kubernetes/rbac/ modules/kubernetes/main.tf main.tf
git commit -m "[ci skip] Add RBAC module for multi-user Kubernetes access"
```

---

### Task 4: Configure Audit Logging on kube-apiserver

**Files:**
- Create: `modules/kubernetes/rbac/audit-policy.tf`

**Step 1: Create the audit policy configuration**

Create `modules/kubernetes/rbac/audit-policy.tf`:

```hcl
# Deploy audit policy to k8s-master and configure kube-apiserver to use it.
# Audit logs are written to /var/log/kubernetes/audit.log on the master node.
# Alloy (log collector DaemonSet) will pick them up and ship to Loki.

resource "null_resource" "audit_policy" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  # Upload audit policy file
  provisioner "file" {
    content = yamlencode({
      apiVersion = "audit.k8s.io/v1"
      kind       = "Policy"
      rules = [
        {
          # Don't log requests to the API discovery endpoints (very noisy)
          level = "None"
          resources = [{
            group     = ""
            resources = ["endpoints", "services", "services/status"]
          }]
          users = ["system:kube-proxy"]
        },
        {
          # Don't log watch requests (very noisy)
          level = "None"
          verbs = ["watch"]
        },
        {
          # Don't log health checks
          level = "None"
          nonResourceURLs = ["/healthz*", "/readyz*", "/livez*"]
        },
        {
          # Log secret access at Metadata level only (no request/response bodies)
          level = "Metadata"
          resources = [{
            group     = ""
            resources = ["secrets"]
          }]
        },
        {
          # Log all other mutating requests at RequestResponse level
          level = "RequestResponse"
          verbs = ["create", "update", "patch", "delete"]
        },
        {
          # Log read requests at Metadata level
          level = "Metadata"
          verbs = ["get", "list"]
        },
      ]
    })
    destination = "/tmp/audit-policy.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      # Move audit policy to proper location
      "sudo mkdir -p /etc/kubernetes/policies",
      "sudo mv /tmp/audit-policy.yaml /etc/kubernetes/policies/audit-policy.yaml",
      "sudo chown root:root /etc/kubernetes/policies/audit-policy.yaml",

      # Create audit log directory
      "sudo mkdir -p /var/log/kubernetes",

      # Check if audit flags already present
      "if grep -q 'audit-policy-file' /etc/kubernetes/manifests/kube-apiserver.yaml; then echo 'Audit flags already configured'; exit 0; fi",

      # Add audit flags to kube-apiserver manifest
      "sudo sed -i '/- --oidc-groups-claim/a\\    - --audit-policy-file=/etc/kubernetes/policies/audit-policy.yaml\\n    - --audit-log-path=/var/log/kubernetes/audit.log\\n    - --audit-log-maxage=7\\n    - --audit-log-maxbackup=3\\n    - --audit-log-maxsize=100' /etc/kubernetes/manifests/kube-apiserver.yaml",

      # Add volume mount for audit policy (hostPath)
      # The kube-apiserver pod needs access to the policy file and log directory
      "sudo sed -i '/volumes:/a\\  - hostPath:\\n      path: /etc/kubernetes/policies\\n      type: DirectoryOrCreate\\n    name: audit-policy\\n  - hostPath:\\n      path: /var/log/kubernetes\\n      type: DirectoryOrCreate\\n    name: audit-log' /etc/kubernetes/manifests/kube-apiserver.yaml",

      "sudo sed -i '/volumeMounts:/a\\    - mountPath: /etc/kubernetes/policies\\n      name: audit-policy\\n      readOnly: true\\n    - mountPath: /var/log/kubernetes\\n      name: audit-log' /etc/kubernetes/manifests/kube-apiserver.yaml",

      # Wait for API server to restart
      "echo 'Waiting for API server to restart with audit logging...'",
      "sleep 30",
      "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes || echo 'API server still restarting'",
    ]
  }

  triggers = {
    policy_version = "v1" # Bump to re-apply
  }

  depends_on = [null_resource.apiserver_oidc_config]
}
```

**Step 2: Apply**

```bash
terraform apply -target=module.kubernetes_cluster.module.rbac -var="kube_config_path=$(pwd)/config" -auto-approve
```

**Step 3: Verify audit log is being written**

```bash
ssh wizard@10.0.20.100 "sudo tail -5 /var/log/kubernetes/audit.log | jq -r '.user.username + \" \" + .verb + \" \" + .objectRef.resource'"
```

Expected: Lines showing API server requests with usernames and resources.

**Step 4: Commit**

```bash
git add modules/kubernetes/rbac/audit-policy.tf
git commit -m "[ci skip] Add Kubernetes audit logging to kube-apiserver"
```

---

### Task 5: Configure Alloy to Collect Audit Logs

The Alloy DaemonSet (log collector) needs to be configured to also collect `/var/log/kubernetes/audit.log` from the master node and ship it to Loki.

**Files:**
- Modify: `modules/kubernetes/monitoring/alloy.yaml` (add audit log scrape config)

**Step 1: Add audit log collection to Alloy config**

In `modules/kubernetes/monitoring/alloy.yaml`, add a new `local.file_match` and `loki.source.file` block for audit logs:

```
local.file_match "audit_logs" {
  path_targets = [{
    __path__ = "/var/log/kubernetes/audit.log"
    job      = "kubernetes-audit"
    node     = env("HOSTNAME")
  }]
}

loki.source.file "audit_logs" {
  targets    = local.file_match.audit_logs.targets
  forward_to = [loki.write.default.receiver]
}
```

**Step 2: Ensure Alloy DaemonSet mounts `/var/log/kubernetes`**

The Alloy Helm values need to mount `/var/log/kubernetes` from the host. Check if the existing `/var/log` hostPath mount already covers this (it likely does, since `/var/log/kubernetes` is a subdirectory).

**Step 3: Apply monitoring module**

```bash
terraform apply -target=module.kubernetes_cluster.module.monitoring -var="kube_config_path=$(pwd)/config" -auto-approve
```

**Step 4: Verify in Grafana**

Go to Grafana → Explore → Loki datasource. Run:

```logql
{job="kubernetes-audit"} | json | line_format "{{.user.username}} {{.verb}} {{.objectRef.resource}}"
```

**Step 5: Commit**

```bash
git add modules/kubernetes/monitoring/alloy.yaml
git commit -m "[ci skip] Add Kubernetes audit log collection to Alloy"
```

---

### Task 6: Build Self-Service Portal (SvelteKit App)

**Files:**
- Create: `modules/kubernetes/k8s-portal/` (entire module)
- Create: `modules/kubernetes/k8s-portal/files/` (SvelteKit app source)
- Modify: `modules/kubernetes/main.tf` (add module call)
- Modify: `terraform.tfvars` (add DNS entry)

**Step 1: Create the SvelteKit app**

```bash
mkdir -p modules/kubernetes/k8s-portal/files
cd modules/kubernetes/k8s-portal/files
npm create svelte@latest . -- --template skeleton --types typescript
npm install
```

**Step 2: Create the portal pages**

The portal has three pages:
1. **`/`** — Landing page showing user's role and namespaces
2. **`/download`** — Generates and serves the kubeconfig file
3. **`/setup`** — Instructions for installing kubectl and kubelogin

The app reads user identity from Traefik forward auth headers (`X-authentik-email`, `X-authentik-username`, `X-authentik-groups`) and user role data from the `k8s-user-roles` ConfigMap (mounted as a volume).

Create `src/routes/+page.server.ts`:
```typescript
import type { PageServerLoad } from './$types';
import { readFileSync } from 'fs';

interface UserRole {
  role: string;
  namespaces: string[];
}

export const load: PageServerLoad = async ({ request }) => {
  const email = request.headers.get('x-authentik-email') || 'unknown';
  const username = request.headers.get('x-authentik-username') || 'unknown';
  const groups = request.headers.get('x-authentik-groups') || '';

  // Read user roles from ConfigMap-mounted file
  let userRole: UserRole = { role: 'unknown', namespaces: [] };
  try {
    const usersJson = readFileSync('/config/users.json', 'utf-8');
    const users = JSON.parse(usersJson);
    if (users[email]) {
      userRole = users[email];
    }
  } catch {
    // ConfigMap not mounted or parse error
  }

  return {
    email,
    username,
    groups: groups.split('|').filter(Boolean),
    role: userRole.role,
    namespaces: userRole.namespaces,
  };
};
```

Create `src/routes/+page.svelte`:
```svelte
<script lang="ts">
  let { data } = $props();
</script>

<main>
  <h1>Kubernetes Access Portal</h1>

  <section>
    <h2>Your Identity</h2>
    <p><strong>Username:</strong> {data.username}</p>
    <p><strong>Email:</strong> {data.email}</p>
    <p><strong>Role:</strong> {data.role}</p>
    {#if data.namespaces.length > 0}
      <p><strong>Namespaces:</strong> {data.namespaces.join(', ')}</p>
    {/if}
  </section>

  <section>
    <h2>Get Started</h2>
    <ol>
      <li><a href="/setup">Install kubectl and kubelogin</a></li>
      <li><a href="/download">Download your kubeconfig</a></li>
      <li>Run <code>kubectl get pods</code> to verify access</li>
    </ol>
  </section>
</main>

<style>
  main { max-width: 640px; margin: 2rem auto; font-family: system-ui; }
  code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
  section { margin: 2rem 0; }
</style>
```

Create `src/routes/download/+server.ts`:
```typescript
import type { RequestHandler } from './$types';
import { readFileSync } from 'fs';

const CLUSTER_SERVER = 'https://10.0.20.100:6443';
const OIDC_ISSUER = 'https://authentik.viktorbarzin.me/application/o/kubernetes/';
const OIDC_CLIENT_ID = 'kubernetes';

export const GET: RequestHandler = async ({ request }) => {
  const email = request.headers.get('x-authentik-email') || 'user';

  // Read CA cert from mounted kubeconfig or file
  let caCert = '';
  try {
    caCert = readFileSync('/config/ca.crt', 'utf-8');
  } catch {
    // CA cert not available
  }

  const caCertBase64 = Buffer.from(caCert).toString('base64');
  const sanitizedEmail = email.replace(/[^a-zA-Z0-9@._-]/g, '');

  const kubeconfig = `apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${caCertBase64}
  name: home-cluster
contexts:
- context:
    cluster: home-cluster
    user: oidc-${sanitizedEmail}
  name: home-cluster
current-context: home-cluster
users:
- name: oidc-${sanitizedEmail}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      args:
        - oidc-login
        - get-token
        - --oidc-issuer-url=${OIDC_ISSUER}
        - --oidc-client-id=${OIDC_CLIENT_ID}
      interactiveMode: IfAvailable
`;

  return new Response(kubeconfig, {
    headers: {
      'Content-Type': 'application/yaml',
      'Content-Disposition': `attachment; filename="kubeconfig-home-cluster.yaml"`,
    },
  });
};
```

Create `src/routes/setup/+page.svelte`:
```svelte
<main>
  <h1>Setup Instructions</h1>

  <section>
    <h2>1. Install kubectl</h2>
    <h3>macOS</h3>
    <pre>brew install kubectl</pre>
    <h3>Linux</h3>
    <pre>curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/</pre>
  </section>

  <section>
    <h2>2. Install kubelogin (OIDC plugin)</h2>
    <h3>macOS</h3>
    <pre>brew install int128/kubelogin/kubelogin</pre>
    <h3>Linux</h3>
    <pre>curl -LO https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
unzip kubelogin_linux_amd64.zip && sudo mv kubelogin /usr/local/bin/kubectl-oidc_login</pre>
  </section>

  <section>
    <h2>3. Download and use your kubeconfig</h2>
    <pre>
# Download from the portal
curl -o ~/.kube/config-home https://k8s-portal.viktorbarzin.me/download

# Set the KUBECONFIG environment variable
export KUBECONFIG=~/.kube/config-home

# Test access (opens browser for login)
kubectl get namespaces
    </pre>
  </section>

  <p><a href="/">← Back to portal</a></p>
</main>

<style>
  main { max-width: 640px; margin: 2rem auto; font-family: system-ui; }
  pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; }
  section { margin: 2rem 0; }
</style>
```

Create `Dockerfile`:
```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=build /app/build ./build
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
ENV PORT=3000
EXPOSE 3000
CMD ["node", "build"]
```

Ensure SvelteKit uses the Node adapter. Update `svelte.config.js`:
```javascript
import adapter from '@sveltejs/adapter-node';
export default { kit: { adapter: adapter() } };
```

Install the Node adapter:
```bash
cd modules/kubernetes/k8s-portal/files
npm install -D @sveltejs/adapter-node
```

**Step 3: Create the Terraform module**

Create `modules/kubernetes/k8s-portal/main.tf`:

```hcl
variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "k8s_portal" {
  metadata {
    name = "k8s-portal"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "k8s_portal" {
  metadata {
    name      = "k8s-portal"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
    labels = {
      app  = "k8s-portal"
      tier = var.tier
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "k8s-portal"
      }
    }

    template {
      metadata {
        labels = {
          app = "k8s-portal"
        }
      }

      spec {
        container {
          name  = "portal"
          image = "10.0.20.10:5000/k8s-portal:latest"
          port {
            container_port = 3000
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = "k8s-portal-config"
          }
        }
      }
    }
  }
}

resource "kubernetes_config_map" "k8s_portal_config" {
  metadata {
    name      = "k8s-portal-config"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  data = {
    # CA cert extracted from kubeconfig — pass via variable or read from file
    "ca.crt" = "" # Will be populated with cluster CA cert
  }
}

resource "kubernetes_service" "k8s_portal" {
  metadata {
    name      = "k8s-portal"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  spec {
    selector = {
      app = "k8s-portal"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  name            = "k8s-portal"
  tls_secret_name = var.tls_secret_name
  protected       = true # Require Authentik login
}
```

**Step 4: Add module call to `modules/kubernetes/main.tf`**

```hcl
module "k8s-portal" {
  source          = "./k8s-portal"
  for_each        = contains(local.active_modules, "authentik") ? { portal = true } : {}
  tier            = local.tiers.edge
  tls_secret_name = var.tls_secret_name
}
```

**Step 5: Add DNS record**

Add `k8s-portal` to `cloudflare_non_proxied_names` in `terraform.tfvars`.

**Step 6: Build and push Docker image**

```bash
cd modules/kubernetes/k8s-portal/files
docker build -t 10.0.20.10:5000/k8s-portal:latest .
docker push 10.0.20.10:5000/k8s-portal:latest
```

**Step 7: Apply**

```bash
terraform apply -target=module.kubernetes_cluster.module.k8s-portal -var="kube_config_path=$(pwd)/config" -auto-approve
terraform apply -target=module.kubernetes_cluster.module.cloudflared -var="kube_config_path=$(pwd)/config" -auto-approve
```

**Step 8: Verify portal works**

Visit `https://k8s-portal.viktorbarzin.me` — should redirect to Authentik login, then show your role and kubeconfig download.

**Step 9: Commit**

```bash
git add modules/kubernetes/k8s-portal/ modules/kubernetes/main.tf
git commit -m "[ci skip] Add self-service Kubernetes access portal"
```

---

### Task 7: Create Grafana Dashboard for Audit Logs

**Files:**
- Create: `modules/kubernetes/monitoring/dashboards/k8s-audit.json`

**Step 1: Create Grafana dashboard**

Create a dashboard JSON file that queries Loki for audit logs. The dashboard should show:
- **Panel 1**: Table of recent actions (user, verb, resource, namespace, timestamp)
- **Panel 2**: Time series of request count by user
- **Panel 3**: Table of denied requests

LogQL queries:
- Recent actions: `{job="kubernetes-audit"} | json | line_format "{{.user.username}} {{.verb}} {{.objectRef.resource}} {{.objectRef.namespace}}"`
- By user: `sum by (user_username) (count_over_time({job="kubernetes-audit"} | json [5m]))`
- Denied: `{job="kubernetes-audit"} | json | responseStatus_code >= 403`

Store the dashboard JSON in `modules/kubernetes/monitoring/dashboards/k8s-audit.json` and provision it via Grafana's file provisioning (same pattern as other dashboards).

**Step 2: Apply monitoring**

```bash
terraform apply -target=module.kubernetes_cluster.module.monitoring -var="kube_config_path=$(pwd)/config" -auto-approve
```

**Step 3: Commit**

```bash
git add modules/kubernetes/monitoring/dashboards/k8s-audit.json
git commit -m "[ci skip] Add Grafana dashboard for Kubernetes audit logs"
```

---

### Task 8: End-to-End Verification

**Step 1: Test OIDC login with kubelogin**

```bash
# Install kubelogin
brew install int128/kubelogin/kubelogin

# Download kubeconfig from portal
curl -H "X-authentik-email: viktor@viktorbarzin.me" -o /tmp/test-kubeconfig https://k8s-portal.viktorbarzin.me/download

# Test kubectl with OIDC
KUBECONFIG=/tmp/test-kubeconfig kubectl get namespaces
```

This should open a browser for Authentik login, then return the namespace list.

**Step 2: Test RBAC enforcement**

Create a test namespace-owner user in `terraform.tfvars`, apply, then verify they can only access their namespace.

**Step 3: Test audit logging**

After running kubectl commands, verify they appear in Grafana:
- Go to Grafana → Explore → Loki
- Query: `{job="kubernetes-audit"} | json | user_username="viktor@viktorbarzin.me"`

**Step 4: Final commit and push**

```bash
git add -A
git commit -m "[ci skip] Multi-user Kubernetes access: complete implementation"
git push origin master
```
