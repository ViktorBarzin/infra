# Pairing a television with the f1 API (f1-stream ADR-0007).
#
# The TV shows a short code and polls; a member of "F1 Users" opens /pair on a
# phone, signs in through the f1-stream OIDC application (members.tf), types
# the code, and the backend records the TV and mints it a token bound to that
# record (f1-stream ADR-0021).
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
# WHY NOT AUTHENTIK'S OWN DEVICE-CODE FLOW. Authentik does
# advertise RFC 8628 -- `device_authorization_endpoint` and the
# `urn:ietf:params:oauth:grant-type:device_code` grant are both in the discovery
# document -- but the default brand has `flow_device_code` unset and this
# instance has no device-code flow to point it at, so the endpoint has no page
# to render. Standing that up is a flow-authoring change we have not tested.
# This path used forward-auth until 2026-10-10; it now relies on the app's own
# Member session, because forward-auth admits Home Server Admins only.
#
# The television never sees any of this. Its contract is "ask for a code, poll
# for a token", which is identical whether the backend approves the code itself
# or proxies Authentik's device endpoint. Moving to RFC 8628 later is a change
# behind /api/device/ with no client release.
module "ingress_tv_pairing" {
  source       = "../../modules/kubernetes/ingress_factory"
  host         = "f1"
  name         = "f1-tv-pairing"
  ingress_path = ["/pair"]
  namespace    = kubernetes_namespace.f1-stream.metadata[0].name
  service_name = kubernetes_service.f1-stream.metadata[0].name
  port         = 80

  # The public ingress owns the DNS record and the uptime monitor for this host;
  # this is a longer path prefix on the same name, which Traefik prefers, and it
  # points at the app directly rather than through Anubis. A proof-of-work
  # challenge in front of a sign-in redirect only gets in the way, and the
  # Member session the app checks is the stronger gate.
  dns_type         = "none"
  homepage_enabled = false
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false

  # No forward-auth since 2026-10-10 (f1-stream ADR-0021). Any member of
  # "F1 Users" may pair a TV now, and the domain-wide forward-auth application
  # admits Home Server Admins only, so it would refuse them here. The app is the
  # gate instead: /pair reads the Member session cookie that sign-in through the
  # f1-stream OIDC application mints (members.tf), and redirects to /login
  # without one. Paired TVs are recorded and can be unpaired, which is what
  # makes widening this safe to undo.
  # auth = "app": the f1-stream Member session (OIDC sign-in, members.tf) gates /pair
  auth = "app"

  # No ingress-proof middleware any more: it guarded X-authentik-* headers, and
  # /pair no longer reads any. A Member session is a cookie this app signed, so
  # reaching the Service directly gains a caller nothing.
}
