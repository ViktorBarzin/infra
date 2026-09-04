# Proves the control-plane SSH path this module's provisioners depend on, without
# touching the control plane.
#
# The three real provisioners (etcd-tuning.tf, audit-policy.tf, apiserver-oidc.tf)
# all rewrite a static-pod manifest under /etc/kubernetes/manifests, and on a
# single-node control plane the kubelet restarts etcd or the kube-apiserver when
# one of those files changes. That makes them a poor way to answer "can CI reach
# the node at all". This resource answers exactly that question and nothing else:
# it opens the same SSH connection, as the same user, with the same key variable,
# runs two read-only commands, and writes nothing.
#
# Bump `check` to re-run it. The pipeline log line to look for is
# "rbac provisioner SSH ok: wizard@k8s-master".
#
# The count guard keeps a keyless apply behaving as it always has. With no key
# (var.ssh_private_key unset AND the Vault key absent) the resource is not
# created, so an apply that could not have reached the node does not fail
# pretending it tried.

resource "null_resource" "provisioner_ssh_check" {
  count = var.ssh_private_key != "" ? 1 : 0

  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
    timeout     = "60s"
  }

  provisioner "remote-exec" {
    inline = [
      "echo \"rbac provisioner SSH ok: $(whoami)@$(hostname) at $(date -Is)\"",
      "sudo -n true && echo 'rbac provisioner sudo ok' || { echo 'rbac provisioner sudo DENIED'; exit 1; }",
    ]
  }

  triggers = {
    # Bumped 2026-09-04 to prove the dedicated CI key works end to end (bd code-5w5u).
    check = "1"
  }
}
