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
  version    = "0.15.3"
  namespace  = kubernetes_namespace.metallb.metadata[0].name
  timeout    = 600

  values = [yamlencode({
    controller = {
      image = {
        pullPolicy = "IfNotPresent"
      }
    }
    speaker = {
      image = {
        pullPolicy = "IfNotPresent"
      }
      frr = {
        enabled = false
      }
    }
  })]
}

resource "kubernetes_manifest" "ip_address_pool" {
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "default"
      namespace = "metallb-system"
    }
    spec = {
      addresses = ["10.0.20.200-10.0.20.220"]
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
