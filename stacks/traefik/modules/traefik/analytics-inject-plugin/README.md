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

Values are HTML-escaped. `New()` rejects a missing `siteId` and attribute
names outside `[A-Za-z][A-Za-z0-9_:.-]*`.

## What it touches

A request is handled only when all of these hold:

- the method is `GET`;
- `Accept` contains `text/html`, or `Sec-Fetch-Dest` is `document`;
- there is no `Range` header and no `Upgrade` / `Connection: upgrade`.

Every other request goes to the next handler with the original writer, so
websockets, SSE, range requests, `HEAD` and API calls are not wrapped at all.

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

## Compression

The `compress` middleware runs on the websecure entrypoint, and entrypoint
middlewares run before router middlewares. It has therefore already read the
client's `Accept-Encoding` before this plugin removes it, and it compresses
the HTML this plugin writes. If this plugin is ever placed outside a
`compress` middleware, the inner `compress` would see no `Accept-Encoding`
and send those pages uncompressed.

## Yaegi notes

Traefik runs the plugin under Yaegi, and one plugin that fails to load
disables every plugin (see the NOTE in `../main.tf`). The code is stdlib only.

Two behaviours differ from compiled Go, and the Yaegi test in
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
