# bridge/, a temporary vendored copy

`client/` and `internal/wire/` are copied, unchanged, from
`/home/wizard/code/browser-bridge` at commit `75efb557`. `homelab browser
bridge` imports `github.com/ViktorBarzin/browser-bridge/client`, the real
import path, and `go.mod` here plus a `replace` in `../go.mod` point that path
at this directory.

## Why a copy

The module has no remote. Three builders compile this CLI and none of them can
fetch it:

| builder | where | fetches from |
|---|---|---|
| hourly reconcile | `scripts/t3-provision-users.sh`, `build_homelab_cli()` | proxy.golang.org, as root, no credentials |
| manual base install | `scripts/workstation/setup-devvm.sh` | proxy.golang.org |
| container image | `.github/workflows/build-cli.yml`, build context `cli` | proxy.golang.org |

A `replace` pointing at `../../browser-bridge` resolves on this workstation and
nowhere else: the Docker context is `cli/`, so the path does not exist inside
the image. A copy inside `cli/` is in all three contexts.

## Removing it

Publish `github.com/ViktorBarzin/browser-bridge`, tag it, then:

1. `go get github.com/ViktorBarzin/browser-bridge@vX.Y.Z` in `cli/`
2. delete the `require` and `replace` lines that name this directory
3. `rm -rf cli/bridge`
4. drop `"$src/bridge"` from the `srchash` line in `scripts/t3-provision-users.sh`

No import path changes, because this directory already answers to the module's
real name.

## Keeping it honest

Refresh with a copy, never an edit:

```sh
cp /home/wizard/code/browser-bridge/client/*.go        cli/bridge/client/
cp /home/wizard/code/browser-bridge/internal/wire/*.go cli/bridge/internal/wire/
cd cli/bridge && go test ./...
```

The tests came with the copy and run from `cli/bridge`, not from `cli`: a
nested module is outside the parent's `./...`.
