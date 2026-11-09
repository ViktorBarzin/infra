# analytics-inject-plugin

A Traefik local plugin that adds the Rybbit analytics script to the HTML pages
of the third-party apps we host (Immich, Nextcloud, Forgejo and others), as
decided in ADR-0041 and described in
`docs/plans/2026-11-09-product-analytics-design.md` ("Third-party apps").

The tag it inserts, with the default config:

```html
<script src="/_t/r/script.js" data-site-id="SITE" defer></script>
```

The script is served from the app's own origin, so a Content-Security-Policy
of `script-src 'self'` allows it. Apps whose CSP uses nonces will block it;
the design doc lists that as an open question.

## Config

| key | default | meaning |
|---|---|---|
| `siteId` | none, required | Rybbit site id, written to `data-site-id` |
| `scriptSrc` | `/_t/r/script.js` | script URL; also the marker for "already injected" |
| `maxBodyBytes` | `5242880` (5 MiB) | largest HTML body held in memory; larger bodies pass through unmodified |
| `extraAttributes` | none | extra attributes, sorted by name, for example `data-track-errors: "true"`. An empty value renders a bare attribute. `src`, `data-site-id` and `defer` are rejected. |
| `excludeHosts` | none | hosts never touched: not wrapped, `Accept-Encoding` kept. Wins over `includeHosts`. |
| `includeHosts` | none | when non-empty, the only eligible hosts. Meant for a staged rollout, then cleared. |

Values are HTML-escaped. `New()` rejects a missing `siteId`, attribute
names outside `[A-Za-z][A-Za-z0-9_:.-]*`, and invalid host patterns.

Host patterns are an exact name (`vault.viktorbarzin.me`) or `*.` plus a name
(`*.authentik.viktorbarzin.me`). The wildcard matches subdomains only, so list
the apex separately when it needs the same treatment. Matching is
case-insensitive against `req.Host` with its port, IPv6 brackets and trailing
dot removed. Patterns may hold letters, digits, `-`, `_` and `.`; anything else
(a scheme, a path, a port, a `*` elsewhere) is rejected at load time.

## What it touches

A request is handled only when all of these hold:

- the method is `GET`;
- `Accept` contains `text/html`, or `Sec-Fetch-Dest` is `document`;
- there is no `Range` header and no `Upgrade` / `Connection: upgrade`;
- the host is not in `excludeHosts`, and is in `includeHosts` when that is set.

Every other request goes to the next handler with the original writer, so
websockets, SSE, range requests, `HEAD`, API calls and excluded hosts are not
wrapped at all.

## SDK opt-out

First-party apps that load Rybbit themselves add the script from JavaScript,
so the "already contains `scriptSrc`" check cannot see it. They opt out in
either of two ways:

- the response header `X-Analytics: sdk` (value case-insensitive);
- `<meta name="analytics" content="sdk">` in the HTML, in either attribute
  order, with double, single or no quotes, any case for the tag and the value.
  The plugin finds it anywhere in the held body, which is at most
  `maxBodyBytes`.

The plugin removes `X-Analytics`, whatever its value, from every response it
wraps, so the client does not see it. Responses it does not wrap (requests
that do not qualify, excluded hosts) keep the header. Apps that care can send
it only on HTML pages.

For a handled request the plugin removes `Accept-Encoding`, so the backend
answers uncompressed, and holds the body only when the response is a `200`
with a `Content-Type` starting with `text/html`, no `Content-Encoding` (or
`identity`), and a `Content-Length` that is absent or within `maxBodyBytes`.
Anything else (304, 206, redirects, errors, compressed or oversized bodies)
goes straight through as the backend sent it.

The tag goes before `</head>`. Without one it goes after the `<head ...>`
open tag, and without that after the `<body ...>` open tag. A body that has
none of these, or already contains `scriptSrc`, is sent unchanged.
`Content-Length` is set to the new length; all other headers are kept,
including `ETag`.

If the body grows past `maxBodyBytes` while it is being held, the held bytes
are sent unmodified and the rest streams. If the backend flushes while the
body is held, the plugin injects into what it has (when an insertion point is
there), sends it, and streams the rest.

## Compression and ordering

The plugin runs as a websecure entrypoint middleware, after `compress`:

```
crowdsec -> compress -> analytics-inject -> router middlewares -> backend
```

Traefik's compress middleware (v3.7.17, `pkg/middlewares/compress`) picks the
encoding from the request's `Accept-Encoding` when the request reaches it, and
passes the request on with that header intact. With `compress` first, it reads
the client's header and wraps the writer, then this plugin removes the header
so the backend answers uncompressed, injects, and `compress` gzips or brotlis
the result on the way out.

The other order breaks compression for HTML pages. If this plugin ran first,
`compress` would see a request with no `Accept-Encoding`; with no
`defaultEncoding` configured it then compresses nothing, so every HTML page
would leave uncompressed. `crowdsec` stays first so a banned client is turned
away before any buffering or compression work.

## Wiring (entrypoint form)

Register the plugin in `../main.tf` under `experimental.localPlugins`:

```hcl
analytics-inject = {
  moduleName = "github.com/viktorbarzin/analytics-inject-plugin"
  mountPath  = "/plugins-local/src/github.com/viktorbarzin/analytics-inject-plugin"
  type       = "inlinePlugin"
  source = {
    "go.mod"       = file("${path.module}/analytics-inject-plugin/go.mod")
    ".traefik.yml" = file("${path.module}/analytics-inject-plugin/.traefik.yml")
    "main.go"      = file("${path.module}/analytics-inject-plugin/main.go")
    "filters.go"   = file("${path.module}/analytics-inject-plugin/filters.go")
  }
}
```

Declare the Middleware in `../middleware.tf`, next to `crowdsec`:

```hcl
resource "kubectl_manifest" "middleware_analytics_inject" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "analytics-inject"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      plugin = {
        analytics-inject = {
          siteId       = "<hosted site id>"
          excludeHosts = ["authentik.viktorbarzin.me", "*.authentik.viktorbarzin.me", "vault.viktorbarzin.me", "..."]
          includeHosts = ["<first third-party host>"] # staged rollout; remove to cover every host
        }
      }
    }
  })
}
```

Then add it to the websecure entrypoint in `../main.tf`, after `compress`:

```hcl
middlewares = [
  "traefik-crowdsec@kubernetescrd",
  "traefik-compress@kubernetescrd",
  "traefik-analytics-inject@kubernetescrd",
]
```

The Middleware must exist before the entrypoint references it: an entrypoint
middleware that does not resolve invalidates every router on websecure. As
with crowdsec, apply the Middleware first, then the entrypoint change, which
is static config and rolls the three replicas.

## Yaegi notes

Traefik runs the plugin under Yaegi, and one plugin that fails to load
disables every plugin (see the NOTE in `../main.tf`). The code is stdlib only.

Three behaviours differ from compiled Go, and the Yaegi test in
`scripts/yaegi-plugin-gate` checks both:

- Compiled code that receives the wrapped writer sees `http.Hijacker` but not
  `http.Flusher`. Yaegi v0.16.1 (the version Traefik v3.7.17 embeds) ships a
  composed wrapper for ResponseWriter plus Hijacker only. Only handled HTML
  navigations get the wrapped writer, so a streamed HTML page reaches the
  browser in larger chunks instead of at each backend flush; it still arrives
  complete.
- Loops in plugin code are interpreted. The tag search uses one
  `bytes.Index` call per pattern, which runs natively: about 20 ms for a
  5 MiB page and 85 ms for a 5 MiB fragment with no head or body, against
  12.6 s for the first byte-by-byte version.
- A tagless switch case with two expressions (`case a, b:`) evaluated only
  the first under Yaegi, so `content='sdk'` went unnoticed while the compiled
  tests passed. The code uses `if a || b` instead, and the Yaegi test runs the
  whole opt-out meta table.

## Tests

```sh
# unit tests, compiled
cd stacks/traefik/modules/traefik/analytics-inject-plugin && go test -race ./...

# the same source under Yaegi, loaded the way Traefik loads it
cd scripts/yaegi-plugin-gate && go test -run TestAnalyticsUnderYaegi -v .
go run . -dir ../../stacks/traefik/modules/traefik/analytics-inject-plugin \
         -import github.com/viktorbarzin/analytics-inject-plugin \
         -config '{"siteId":"7"}' -accept text/html \
         -backend-type text/html -backend-body '<html><head></head></html>' \
         -want-body 'data-site-id="7" defer></script></head>' -want-hijacker
```

Without a Go toolchain, run the same commands in a container:
`docker run --rm -v "$PWD":/src -w /src/<dir> golang:1.24 go test ./...`.
