# -----------------------------------------------------------------------------
# authfix — self-healing recovery for a stale authentik proxy cookie.
#
# WHY THIS EXISTS. The Go and Rust proxy outposts write the same cookie name,
# authentik_proxy_<sha256(client_id)[:8]>, in mutually unreadable formats: Go a
# 52-char base32 session id which IS the session_key column, Rust an HMAC plus a
# UUID. The same split applies to the state JWT. So whenever forward-auth moves
# between the two implementations, a browser mid-sign-in presents a state one
# side minted and the other cannot validate, the outpost answers 400 "invalid
# state", and the OAuth code is single use so retrying never works. Measured on
# 2026-09-19: four 400s in a row, one per retry, and the only fix was clearing
# cookies by hand.
#
# Clearing cookies by hand is not available to every user of this estate, which
# is the whole reason this exists. Viktor: "i don't want any manual actions by
# the client as emo can't do it himself".
#
# WHY IT IS KEYED ON THE 400 AND NOT APPLIED ALWAYS. A Set-Cookie deletion on
# every response would loop forever: delete, re-authenticate, delete again. The
# 400 is the precise signal that a client is stuck, so the repair fires only for
# clients that need it and cannot touch a healthy session.
# -----------------------------------------------------------------------------

resource "kubernetes_config_map" "authfix" {
  metadata {
    name      = "authfix"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
  data = {
    "authfix.py" = <<-PYEOF
      """Self-healing responder for a stale authentik proxy cookie.
      
      Traefik routes a 400 from /outpost.goauthentik.io/callback here. That 400 means
      the outpost said "invalid state": the state JWT was minted by one outpost
      implementation and presented to the other, which cannot validate it. The client
      is stuck and retrying will never work, because the OAuth code is single use.
      
      Two things fix it, and neither needs a human:
        1. delete the stale authentik_proxy_<hash> cookie, so the next flow starts clean
        2. send the browser to where it was originally going
      
      The destination is recoverable. The state parameter is a JWT whose payload
      carries {"redirect": "..."}. We only READ it as a hint and never trust it as
      authentication, so the signature is deliberately not checked; the redirect is
      still constrained to our own domain below.
      """
      import base64, json, os, re
      from http.server import BaseHTTPRequestHandler, HTTPServer
      from urllib.parse import urlparse, parse_qs
      
      COOKIE = os.environ.get("PROXY_COOKIE_NAME", "authentik_proxy_34f8da53")
      DOMAIN = os.environ.get("COOKIE_DOMAIN", "viktorbarzin.me")
      FALLBACK = os.environ.get("FALLBACK_URL", "https://authentik.viktorbarzin.me/")
      SAFE = re.compile(r"^https?://([a-z0-9-]+\.)*" + re.escape(DOMAIN) + r"(/|$)")
      
      
      def redirect_from_state(raw: str) -> str:
          """Pull the redirect hint out of the state JWT. Never raises."""
          try:
              parts = raw.split(".")
              if len(parts) < 2:
                  return FALLBACK
              pad = parts[1] + "=" * (-len(parts[1]) % 4)
              dest = json.loads(base64.urlsafe_b64decode(pad)).get("redirect", "")
              # Only ever bounce somewhere on our own domain.
              return dest if SAFE.match(dest or "") else FALLBACK
          except Exception:
              return FALLBACK
      
      
      class H(BaseHTTPRequestHandler):
          def do_GET(self):
              q = parse_qs(urlparse(self.path).query)
              state = (q.get("state") or [""])[0]
              # Traefik's errors middleware rewrites the path, so also accept the
              # original URI if it forwards one.
              if not state:
                  fwd = self.headers.get("X-Forwarded-Uri", "")
                  state = (parse_qs(urlparse(fwd).query).get("state") or [""])[0]
              dest = redirect_from_state(state)
              self.send_response(302)
              self.send_header("Location", dest)
              # Max-Age=0 with a matching Domain/Path is what actually deletes it.
              self.send_header(
                  "Set-Cookie",
                  f"{COOKIE}=; Max-Age=0; Path=/; Domain={DOMAIN}; Secure; HttpOnly; SameSite=Lax",
              )
              self.send_header("Cache-Control", "no-store")
              self.end_headers()
              self.wfile.write(b"")
      
          def log_message(self, fmt, *a):
              print("authfix " + (fmt % a), flush=True)
      
      
      if __name__ == "__main__":
          HTTPServer(("", 8080), H).serve_forever()
      
    PYEOF
  }
}

resource "kubernetes_deployment" "authfix" {
  metadata {
    name      = "authfix"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels    = { app = "authfix" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "authfix" } }
    template {
      metadata {
        labels      = { app = "authfix" }
        annotations = { "checksum/script" = sha256(kubernetes_config_map.authfix.data["authfix.py"]) }
      }
      spec {
        container {
          name    = "authfix"
          image   = "python:3.13-alpine"
          command = ["python3", "/app/authfix.py"]
          port { container_port = 8080 }
          volume_mount {
            name       = "script"
            mount_path = "/app"
          }
          resources {
            requests = { cpu = "5m", memory = "24Mi" }
            limits   = { memory = "64Mi" }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }
        }
        volume {
          name = "script"
          config_map { name = kubernetes_config_map.authfix.metadata[0].name }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "authfix" {
  metadata {
    name      = "authfix"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
  spec {
    selector = { app = "authfix" }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}

# Catches ONLY 400. The outpost returns 400 for an unvalidatable state and for
# very little else on this path, so the blast radius is one failure mode.
resource "kubectl_manifest" "authfix_middleware" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "authfix"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      errors = {
        status = ["400"]
        service = {
          name      = kubernetes_service.authfix.metadata[0].name
          namespace = kubernetes_namespace.traefik.metadata[0].name
          port      = 8080
        }
        query = "/{status}"
      }
    }
  })
  depends_on = [helm_release.traefik, kubernetes_service.authfix]
}
