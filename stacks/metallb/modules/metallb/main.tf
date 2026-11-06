variable "tier" { type = string }

resource "kubernetes_namespace" "metallb" {
  metadata {
    name = "metallb-system"
    labels = {
      app = "metallb"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  # 0.15.3 -> 0.16.1 (2026-10-12). 0.16.0 flipped frrk8s.enabled to true, which
  # would add a frr-k8s DaemonSet, 4 CRDs and a second webhook; we run native L2
  # only, so frrk8s stays off. 0.16.0 is skipped on purpose: its controller probes
  # target 127.0.0.1 on a non-hostNetwork pod (fixed in 0.16.1, metallb#3062).
  # CRDs are templates in the chart's crds subchart, so helm upgrades them with
  # the release.
  version   = "0.16.2"
  namespace = kubernetes_namespace.metallb.metadata[0].name
  timeout   = 600

  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    frrk8s = {
      enabled = false
    }
    # Priority class, set explicitly (2026-10-20). metallb-system is excluded
    # from Kyverno's inject-priority-class-from-tier, so the controller and all
    # six speakers ran at priority 0 and could be preempted by any tiered pod.
    # The speakers announce every LoadBalancer IP (traefik, DNS, forgejo-ssh),
    # so they sit with traefik at tier-0-core.
    controller = {
      priorityClassName = "tier-0-core"
      image = {
        pullPolicy = "IfNotPresent"
      }
    }
    speaker = {
      priorityClassName = "tier-0-core"
      image = {
        pullPolicy = "IfNotPresent"
      }
      frr = {
        enabled = false
      }
      # reboot-self-heal Phase 2: ADDITIVE — control-plane/master tolerations
      # still come from speaker.tolerateMaster=true (chart default, untouched);
      # this only ADDS the GPU toleration so the speaker keeps a pod on the
      # GPU-tainted k8s-node1 when nvidia.com/gpu flips to NoSchedule.
      tolerations = [
        { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
      ]
    }
  })]
}

resource "kubernetes_manifest" "ip_address_pool" {
  # The pool was created with `kubectl apply` in 2026-03, so that field manager
  # still owned spec.addresses and the first change from Terraform conflicted.
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "default"
      namespace = "metallb-system"
    }
    spec = {
      # IPv6 range added for cluster dual-stack (docs/plans/2026-11-02-cluster-dual-stack.md,
      # phase 6). It is in this same pool because a dual-stack Service needs
      # both of its IPs from one pool. On-link with the nodes' VLAN 20 /64, so
      # L2 (NDP) announcement works. Only Traefik (::203) and mailserver-v6
      # (::204) ask for IPv6, both pinned with metallb.io/loadBalancerIPs.
      addresses = [
        "10.0.20.200-10.0.20.220",
        "2001:470:5a7f:20::200-2001:470:5a7f:20::220",
      ]
    }
  }
  depends_on = [helm_release.metallb]
}

resource "kubernetes_manifest" "l2_advertisement" {
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = "default"
      namespace = "metallb-system"
    }
    spec = {
      ipAddressPools = ["default"]
    }
  }
  depends_on = [helm_release.metallb]
}
