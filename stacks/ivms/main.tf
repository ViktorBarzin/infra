# iVMS-4200, Hikvision's access-control client for the Vermont complex, under
# Wine in the browser (ADR-0035). Emil manages people, cards and faces on the
# complex's entrance panels and access terminal from one list here.
#
# The app runs from the generic wine_app module; this stack owns the namespace,
# the iVMS install recipe (app/) and the rule that only this namespace may
# reach the complex alias 10.77.1.0/24.
#
# Path to the devices: pod -> pfSense static route (no NAT) -> rpi-sofia
# (VERMONT_NETMAP allowlist, playbooks/rpi-sofia-netmap.yml) -> NETMAP onto the
# complex network. pfSense side: playbooks/pfsense-vermont-alias.yml.

locals {
  # 10.77.1.x is the complex device 192.168.1.x (CONTEXT.md: Complex alias).
  complex_alias_cidr = "10.77.1.0/24"
}

resource "kubernetes_namespace" "ivms" {
  metadata {
    name = "ivms"
    labels = {
      "istio-injection" = "disabled"
      # 3-edge: allows an 8Gi container and a 4Gi requests.memory quota;
      # 4-aux caps a container at 4Gi, under iVMS's limit.
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.ivms.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ivms" {
  source          = "../../modules/kubernetes/wine_app"
  name            = "ivms"
  title           = "iVMS-4200"
  namespace       = kubernetes_namespace.ivms.metadata[0].name
  host            = "ivms"
  tls_secret_name = var.tls_secret_name
  nfs_server      = var.nfs_server
  image_tag       = "aba5ebaf9d6789b8bd7f416b428d83bd73b7829b"

  app_files = {
    "app.env"       = file("${path.module}/app/app.env")
    "install.sh"    = file("${path.module}/app/install.sh")
    "post-start.sh" = file("${path.module}/app/post-start.sh")
    "pre-stop.sh"   = file("${path.module}/app/pre-stop.sh")
  }

  # Spike 2026-10-17: about 3.2 GB PSS idle with one device online.
  memory_request = "3584Mi"
  memory_limit   = "5Gi"
}

# Only the ivms namespace may reach the complex alias. ClusterNetworkPolicy
# (v1alpha2, Admin tier) because v1alpha1 AdminNetworkPolicy is not enforced
# on this cluster since Calico 3.33 (infra#123). Traffic it does not match
# continues to namespace NetworkPolicies unchanged. hostNetwork pods and node
# processes are outside any pod policy; pfSense and the Pi admit only the k8s
# node addresses and the devvm.
resource "kubernetes_manifest" "complex_alias_ivms_only" {
  manifest = {
    apiVersion = "policy.networking.k8s.io/v1alpha2"
    kind       = "ClusterNetworkPolicy"
    metadata = {
      name = "complex-alias-ivms-only"
    }
    spec = {
      tier     = "Admin"
      priority = 20
      subject = {
        namespaces = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values   = [kubernetes_namespace.ivms.metadata[0].name]
          }]
        }
      }
      egress = [{
        name   = "deny-complex-alias"
        action = "Deny"
        to     = [{ networks = [local.complex_alias_cidr] }]
      }]
    }
  }
}
