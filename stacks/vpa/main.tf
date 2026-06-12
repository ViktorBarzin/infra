variable "tls_secret_name" { type = string }

# VPA / Goldilocks REMOVED 2026-06-12 (etcd-load-reduction; reverses the re-add
# after memory 2431, ties to code-oflt). All 349 VPAs ran updateMode=Off (no
# auto-right-sizing) yet cost ~800 etcd objects, continuous recommender writes,
# and a pod-creation admission webhook — pure etcd overhead feeding only the
# dashboard. Right-size on demand with krr (Dockerized, no cluster footprint).
#
# The `module "vpa"` block was removed so `scripts/tg apply` DESTROYS the helm
# releases (vpa, goldilocks), the goldilocks-vpa-auto-mode ClusterPolicy, the
# dashboard ingress, and the vpa namespace. The chart-installed VPA CRDs (Helm
# keeps CRDs on uninstall) and any leftover VPA/checkpoint CRs are removed
# post-apply (cascade) via:
#   kubectl delete crd verticalpodautoscalers.autoscaling.k8s.io \
#                      verticalpodautoscalercheckpoints.autoscaling.k8s.io
