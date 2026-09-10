# yaegi-plugin-gate

Loads a vendored Traefik middleware plugin under the **same Yaegi interpreter
version Traefik itself embeds**, the way Traefik loads a `localPlugins`
(`inlinePlugin`) entry: one interpreter per plugin, stdlib symbols only,
`CreateConfig()` then `New()` per middleware instantiation.

## Why this exists

One broken plugin disables **every** Traefik plugin at startup — Traefik logs
`Plugins are disabled because an error has occurred.` and
`api-token-middleware` goes with it, taking paperless-mcp and repowise's gates
down. `go build` and `go test` do **not** catch that class: the plugin compiles
and its tests pass, then Yaegi rejects it at import.

That is not hypothetical. `crowdsec-bouncer-plugin` compiled and passed 26 unit
tests while panicking Yaegi at import (`index out of range [2] with length 2` in
`callBin`) because it held a **variadic func in a struct field**. The same
signature is fine as a parameter or a package-level func — only the field
breaks, and nothing but an interpreter run reveals it.

## Use

Run before any apply that changes a vendored plugin:

    go run . -dir ../../stacks/traefik/modules/traefik/crowdsec-bouncer-plugin \
             -import github.com/viktorbarzin/crowdsec-bouncer-plugin \
             -config '{"lapiKey":"gate","lapiUrl":"http://127.0.0.1:1","pollSeconds":3600}'

    go run . -dir ../../stacks/traefik/modules/traefik/real-ip-plugin \
             -import github.com/viktorbarzin/real-ip-plugin

    go run . -dir ../../stacks/traefik/modules/traefik/sablier-plugin \
             -import github.com/sablierapp/sablier-traefik-plugin \
             -config '{"group":"gate","dynamic":{"theme":"ghost"}}'

Exit 0 = the plugin loads and serves a request under Yaegi.

Two failure classes, and the output names which one you hit:

* **Load failure** (staging / interpret / import / entrypoint lookup) — this is
  the one that disables every Traefik plugin at startup. Do not apply.
* **`New()` rejected the config** — the plugin loaded; only these values were
  refused. In production that is a per-middleware error, not a fleet-wide
  outage. Usually it means the gate needs a `-config`, as sablier does above.

`-config` is JSON overlaid onto whatever `CreateConfig()` returned, exactly as
Traefik overlays a Middleware CRD's `spec.plugin.<key>` block. Pass anything
`New()` refuses to start without.

Keep the pinned `yaegi` version level with the one in Traefik's `go.mod` for the
running chart (check with
`curl -s https://proxy.golang.org/github.com/traefik/traefik/v3/@v/vX.Y.Z.mod`);
a gate on a different interpreter proves less than it appears to. Needs the Go
module proxy on first run.
