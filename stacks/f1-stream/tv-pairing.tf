# Pairing a television with the f1 API (f1-stream ADR-0007).
#
# The TV shows a short code and polls; a person opens /pair on a phone, signs in
# through Authentik, types the code, and the backend mints that device a token.
# Nothing is ever typed on the television, which is the whole point: a password
# field on a TV remote is about forty D-pad presses.
#
# WHY THIS IS A PATH CARVE-OUT AND NOT A NEW HOST. Everything else the TV talks
# to already lives on f1.viktorbarzin.me, and the Anubis policy in main.tf
# already allows `^/(_app/|openapi\.json|docs|api/)`, so the device endpoints
# under /api/device/ reach the app without a proof-of-work challenge. A separate
# api host (which is how tripit solved the same problem) would need its own DNS
# record, ingress and certificate for no gain here.
#
# WHY forward-auth RATHER THAN AUTHENTIK'S OWN DEVICE-CODE FLOW. Authentik does
# advertise RFC 8628 -- `device_authorization_endpoint` and the
# `urn:ietf:params:oauth:grant-type:device_code` grant are both in the discovery
# document -- but the default brand has `flow_device_code` unset and this
# instance has no device-code flow to point it at, so the endpoint has no page
# to render. Standing that up is a flow-authoring change we have not tested.
# Forward-auth on this one path is the gate that already works here, and it is
# the same gate /admin/login has used since the admin session was introduced.
#
# The television never sees any of this. Its contract is "ask for a code, poll
# for a token", which is identical whether the backend approves the code itself
# or proxies Authentik's device endpoint. Moving to RFC 8628 later is a change
# behind /api/device/ with no client release.
module "ingress_tv_pairing" {
  source       = "../../modules/kubernetes/ingress_factory"
  auth         = "required"
  host         = "f1"
  name         = "f1-tv-pairing"
  ingress_path = ["/pair"]
  namespace    = kubernetes_namespace.f1-stream.metadata[0].name
  service_name = kubernetes_service.f1-stream.metadata[0].name
  port         = 80

  # The public ingress owns the DNS record and the uptime monitor for this host;
  # this is a longer path prefix on the same name, which Traefik prefers, and it
  # points at the app directly rather than through Anubis. A proof-of-work
  # challenge in front of a sign-in redirect only gets in the way, and Authentik
  # is the stronger gate -- the same reasoning as ingress_admin_login above it.
  dns_type         = "none"
  homepage_enabled = false
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false

  # Starts narrow deliberately. Today one television needs pairing and Viktor is
  # the person who pairs it. Widening this to the group that may watch is a
  # one-line change here; narrowing it after friends have paired devices is not,
  # because their tokens would already exist. The app checks the header again
  # before it approves a code, so this list is the outer gate rather than the
  # only one.
  allowed_groups = ["Home Server Admins"]
}
