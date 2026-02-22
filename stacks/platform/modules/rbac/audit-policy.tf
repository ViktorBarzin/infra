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
