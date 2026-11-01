# Lets the shared Android emulator's gate see this namespace's GPU-seat pods
# (stacks/android-emulator/gate.py, yield_loop). The Transcoder and the Worker
# carry android-emulator-yields-to=gpu-seat; when one waits Pending on
# Insufficient viktorbarzin.me/gpumem the gate puts the emulator to sleep so
# the pod gets the 800 gpumem the emulator holds.
#
# This Role lives here, not in stacks/android-emulator, because it is created
# in this stack's namespace (f1-stream plan 2026-11-01-tv-rebrand, review
# finding 18). The android-emulator stack applies before this one in CI, so a
# Role there would be created before the namespace exists and fail. Reading
# pods here needs list on pods and nothing more.
resource "kubernetes_role_v1" "android_emulator_yield_watch" {
  metadata {
    name      = "android-emulator-yield-watch"
    namespace = kubernetes_namespace.tv.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding_v1" "android_emulator_yield_watch" {
  metadata {
    name      = "android-emulator-yield-watch"
    namespace = kubernetes_namespace.tv.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.android_emulator_yield_watch.metadata[0].name
  }
  # The gate's account, kubernetes_service_account.gate in
  # stacks/android-emulator/gate.tf.
  subject {
    kind      = "ServiceAccount"
    name      = "android-emulator-gate"
    namespace = "android-emulator"
  }
}
