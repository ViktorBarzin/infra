resource "kubernetes_namespace" "proxmox_csi" {
  metadata {
    name = "proxmox-csi"
    labels = {
      tier                              = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
}

resource "helm_release" "proxmox_csi" {
  namespace        = kubernetes_namespace.proxmox_csi.metadata[0].name
  create_namespace = false
  name             = "proxmox-csi-plugin"
  atomic           = true
  timeout          = 300

  repository = "oci://ghcr.io/sergelogvinov/charts"
  chart      = "proxmox-csi-plugin"

  values = [yamlencode({
    config = {
      clusters = [{
        url          = var.proxmox_url
        insecure     = true
        token_id     = var.proxmox_token_id
        token_secret = var.proxmox_token_secret
        region       = var.proxmox_cluster_name
      }]
    }

    # StorageClass for block volumes on existing HDD thin pool
    storageClass = [{
      name                 = "proxmox-lvm"
      storage              = "local-lvm"
      reclaimPolicy        = "Retain"
      fstype               = "ext4"
      ssd                  = false
      cache                = "none"
      volumeBindingMode    = "WaitForFirstConsumer"
      allowVolumeExpansion = true
    }]

    controller = {
      replicas = 2
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }

    node = {
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }
  })]
}

# Topology labels on K8s nodes — required for Proxmox CSI to map nodes to Proxmox VMs.
# region = Proxmox cluster name, zone = Proxmox node name (where the VM runs).
# All our VMs run on the single Proxmox node "pve".
locals {
  k8s_nodes = {
    "k8s-master" = { vmid = 200, proxmox_node = "pve" }
    "k8s-node1"  = { vmid = 201, proxmox_node = "pve" }
    "k8s-node2"  = { vmid = 202, proxmox_node = "pve" }
    "k8s-node3"  = { vmid = 203, proxmox_node = "pve" }
    "k8s-node4"  = { vmid = 204, proxmox_node = "pve" }
  }
}

resource "null_resource" "node_labels" {
  for_each = local.k8s_nodes

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig=${var.kube_config_path} label node ${each.key} \
        topology.kubernetes.io/region=${var.proxmox_cluster_name} \
        topology.kubernetes.io/zone=${each.value.proxmox_node} \
        node.csi.proxmox.sinextra.dev/name=${each.key} \
        --overwrite
    EOT
  }

  triggers = {
    region = var.proxmox_cluster_name
    zone   = each.value.proxmox_node
  }
}
