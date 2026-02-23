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
          level           = "None"
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

      # Idempotently add audit flags, volumes, and volumeMounts using Python
      # to avoid sed duplication bugs on re-runs
      <<-SCRIPT
      sudo python3 -c "
import yaml

path = '/etc/kubernetes/manifests/kube-apiserver.yaml'
with open(path) as f:
    doc = yaml.safe_load(f)

container = doc['spec']['containers'][0]
cmd = container['command']

# Add audit flags if missing
audit_flags = {
    '--audit-policy-file=/etc/kubernetes/policies/audit-policy.yaml': True,
    '--audit-log-path=/var/log/kubernetes/audit.log': True,
    '--audit-log-maxage=7': True,
    '--audit-log-maxbackup=3': True,
    '--audit-log-maxsize=100': True,
}
existing = set(cmd)
for flag in audit_flags:
    if flag not in existing:
        cmd.append(flag)

# Add volumes if missing (deduplicate by name)
vol_names = {v['name'] for v in doc['spec']['volumes']}
for vol in [
    {'name': 'audit-policy', 'hostPath': {'path': '/etc/kubernetes/policies', 'type': 'DirectoryOrCreate'}},
    {'name': 'audit-log', 'hostPath': {'path': '/var/log/kubernetes', 'type': 'DirectoryOrCreate'}},
]:
    if vol['name'] not in vol_names:
        doc['spec']['volumes'].append(vol)
        vol_names.add(vol['name'])

# Add volumeMounts if missing (deduplicate by mountPath)
mount_paths = {vm['mountPath'] for vm in container['volumeMounts']}
for vm in [
    {'mountPath': '/etc/kubernetes/policies', 'name': 'audit-policy', 'readOnly': True},
    {'mountPath': '/var/log/kubernetes', 'name': 'audit-log'},
]:
    if vm['mountPath'] not in mount_paths:
        container['volumeMounts'].append(vm)
        mount_paths.add(vm['mountPath'])

with open(path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False)

print('Audit config applied (idempotent)')
"
      SCRIPT
      ,

      # Wait for API server to restart
      "echo 'Waiting for API server to restart with audit logging...'",
      "sleep 30",
      "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes || echo 'API server still restarting'",
    ]
  }

  triggers = {
    policy_version = "v1" # Bump to force re-apply of manifest flags
    policy_hash = sha256(yamlencode({
      apiVersion = "audit.k8s.io/v1"
      kind       = "Policy"
      rules = [
        {
          level = "None"
          resources = [{
            group     = ""
            resources = ["endpoints", "services", "services/status"]
          }]
          users = ["system:kube-proxy"]
        },
        {
          level = "None"
          verbs = ["watch"]
        },
        {
          level           = "None"
          nonResourceURLs = ["/healthz*", "/readyz*", "/livez*"]
        },
        {
          level = "Metadata"
          resources = [{
            group     = ""
            resources = ["secrets"]
          }]
        },
        {
          level = "RequestResponse"
          verbs = ["create", "update", "patch", "delete"]
        },
        {
          level = "Metadata"
          verbs = ["get", "list"]
        },
      ]
    }))
  }

  depends_on = [null_resource.apiserver_oidc_config]
}
