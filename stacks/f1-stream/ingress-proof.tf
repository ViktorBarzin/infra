# Proving that a request reached the app through Traefik.
#
# Two routes on f1.viktorbarzin.me read `X-authentik-username` and
# `X-authentik-groups` and act on them: /admin/login, which exchanges them for
# a session cookie, and /pair, which approves a television and mints it a
# device token. Both sit behind the authentik-forward-auth middleware, whose
# authResponseHeaders overwrite whatever a client sent, so no browser on the
# public internet can forge an identity on either path.
#
# What forward-auth cannot say is whether a request went through Traefik at
# all. Anything that can open a connection to the Service reaches the same two
# routes with the same handlers behind them. The f1-stream audit found this
# while installing a build for an unrelated device test and recorded it as
# item 15: a `kubectl port-forward -n f1-stream svc/f1` carrying those two
# headers returned "Paired" and minted a device token. The write-up is
# docs/plans/2026-09-17-live-streaming-performance-audit.md in the f1-stream
# repo, which is where the measurement lives; nothing here re-ran it.
#
# So the ingress stamps a value the client cannot guess and the app requires
# it. customRequestHeaders SETS the header rather than adding to it, which
# means a caller who sends their own copy has it replaced on the way through.
# A request that never met the middleware arrives without one.
#
# WHY THE VALUE LIVES IN TERRAFORM STATE AND NOWHERE ELSE. It is read by
# exactly two things, the Middleware below and the Deployment in main.tf, both
# of them in this file's stack. Putting it in Vault would add a second place to
# rotate it from and a second thing to keep in step, for no consumer that
# cannot already read it here. Rotating it is `terraform taint` on this
# resource plus an apply, which updates the Middleware and the Deployment in
# the same run.
#
# NOT A CHANGE TO stacks/traefik. A namespaced Middleware is enough, and it
# keeps this to one stack: the shared middleware file is attached to every
# ingress in the cluster, and a mistake there costs more than a mistake here.
resource "random_password" "ingress_proof" {
  length = 48
  # Alphanumeric only. This ends up as an HTTP header value and travels through
  # two YAML manifests; there is no reason to make either of those interesting
  # when 48 characters of [A-Za-z0-9] is already far past guessing.
  special = false
}

resource "kubernetes_manifest" "ingress_proof" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingress-proof"
      namespace = kubernetes_namespace.f1-stream.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-F1-Ingress-Proof" = random_password.ingress_proof.result
        }
      }
    }
  }
}
