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

      # Add OIDC flags after the last --tls-private-key-file flag (safe insertion point)
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
