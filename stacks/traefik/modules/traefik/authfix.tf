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
      """Self-healing responder for a client stranded by the outpost cookie split.

      Traefik routes a 400 from /outpost.goauthentik.io/callback here. That 400 means
      the outpost said "invalid state": the state JWT was minted by one proxy-outpost
      implementation and presented to the other, which cannot validate it. The OAuth
      code is single use, so the browser retries forever and only clearing cookies by
      hand fixes it, which not every user of this estate can do.

      Two things repair it, neither needing a human:
        1. delete the stale authentik_proxy_<hash> cookie so the next flow starts clean
        2. send the browser where it was originally going

      TWO TRAEFIK BEHAVIOURS SHAPE THIS, both measured on 2026-09-19 rather than read:

        The errors middleware builds a FRESH GET against its query template and
        forwards neither the original query string nor an X-Forwarded-Uri. The only
        way to see the original request is the {url} placeholder, which traefik
        url-escapes (pkg/middlewares/customerrors/custom_errors.go).

        It also PRESERVES the upstream status, so this responds 400 and a browser
        ignores a Location header on it. The cookie deletion still applies, which is
        the repair that matters, and a meta refresh is what actually moves the user.
      """
      import base64, html, json, os, re
      from http.server import BaseHTTPRequestHandler, HTTPServer
      from urllib.parse import urlparse, parse_qs, unquote

      COOKIE = os.environ.get("PROXY_COOKIE_NAME", "authentik_proxy_34f8da53")
      DOMAIN = os.environ.get("COOKIE_DOMAIN", "viktorbarzin.me")
      FALLBACK = os.environ.get("FALLBACK_URL", "https://authentik.viktorbarzin.me/")
      SAFE = re.compile(r"^https?://([a-z0-9-]+\.)*" + re.escape(DOMAIN) + r"(/|$)")


      def state_from_url(raw_url: str) -> str:
          """Pull the state parameter out of the original URL traefik passed us."""
          try:
              return (parse_qs(urlparse(unquote(raw_url)).query).get("state") or [""])[0]
          except Exception:
              return ""


      def redirect_from_state(raw: str) -> str:
          """Read the redirect hint out of the state JWT. Never raises.

          The signature is deliberately NOT checked. This is a navigation hint, never
          authentication, and the result is constrained to our own domain below.
          """
          try:
              parts = raw.split(".")
              if len(parts) < 2:
                  return FALLBACK
              pad = parts[1] + "=" * (-len(parts[1]) % 4)
              dest = json.loads(base64.urlsafe_b64decode(pad)).get("redirect", "")
              return dest if SAFE.match(dest or "") else FALLBACK
          except Exception:
              return FALLBACK


      class H(BaseHTTPRequestHandler):
          def do_GET(self):
              # /healthz answers 200 so the kubelet can tell "up" from "serving a
              # repair". Every other path answers 400, because traefik preserves the
              # upstream status and that is what this exists to handle. Pointing the
              # readiness probe at / instead cost a stuck rollout: 64 consecutive
              # "HTTP probe failed with statuscode: 400" before this was added.
              if urlparse(self.path).path == "/healthz":
                  self.send_response(200)
                  self.send_header("Content-Length", "2")
                  self.end_headers()
                  self.wfile.write(b"ok")
                  return
              q = parse_qs(urlparse(self.path).query)
              state = (q.get("state") or [""])[0] or state_from_url((q.get("url") or [""])[0])
              dest = redirect_from_state(state)
              esc = html.escape(dest, quote=True)
              body = (
                  "<!doctype html><meta charset=utf-8>"
                  f'<meta http-equiv="refresh" content="0;url={esc}">'
                  "<title>Signing you back in</title>"
                  f'<p>Your sign-in session expired. Sending you back to <a href="{esc}">{esc}</a>.'
              ).encode()
              self.send_response(400)
              self.send_header("Location", dest)
              self.send_header(
                  "Set-Cookie",
                  f"{COOKIE}=; Max-Age=0; Path=/; Domain={DOMAIN}; Secure; HttpOnly; SameSite=Lax",
              )
              self.send_header("Content-Type", "text/html; charset=utf-8")
              self.send_header("Content-Length", str(len(body)))
              self.send_header("Cache-Control", "no-store")
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, fmt, *a):
              if "/400" in (self.path or ""):
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
              path = "/healthz"
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
        # {url} is url.QueryEscape'd by traefik (custom_errors.go) and is the
        # ONLY way to see the original request here: the errors middleware
        # builds a fresh GET against this template and forwards neither the
        # original query string nor an X-Forwarded-Uri.
        query = "/{status}?url={url}"
      }
    }
  })
  depends_on = [helm_release.traefik, kubernetes_service.authfix]
}
