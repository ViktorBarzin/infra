# Tune etcd for reduced disk writes on k8s-master.
# Increases snapshot-count from 10000 (default) to 50000 to reduce WAL snapshot frequency.
# etcd writes ~37.5 GB/day; less frequent snapshots reduce this by ~30-40%.
# This patches the kubeadm-managed static pod manifest. Note: kubeadm upgrades
# will reset this, so re-apply after any kubeadm upgrade.

resource "null_resource" "etcd_tuning" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      <<-SCRIPT
      sudo python3 -c "
import yaml

path = '/etc/kubernetes/manifests/etcd.yaml'
with open(path) as f:
    doc = yaml.safe_load(f)

container = doc['spec']['containers'][0]
args = container['command']

# Update or add --snapshot-count=50000
new_args = [a for a in args if not a.startswith('--snapshot-count=')]
new_args.append('--snapshot-count=50000')

# Update or add --quota-backend-bytes (256MB, default is 2GB which is fine)
# Keep default for now

container['command'] = new_args

with open(path, 'w') as f:
    yaml.dump(doc, f, default_flow_style=False)

print('etcd manifest updated: --snapshot-count=50000')
"
      SCRIPT
    ]
  }

  # Re-run if the configuration changes
  triggers = {
    snapshot_count = "50000"
  }
}
