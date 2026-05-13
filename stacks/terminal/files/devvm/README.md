# DevVM terminal files

These files configure ttyd + tmux-api on the DevVM (`10.0.10.10`). ttyd
serves the multi-session lobby (and per-session attach via `?arg=<name>`)
on port 7681; tmux-api is a small Go REST API on 7684 that powers the
lobby's list/kill actions.

`terminal-ro.service` (port 7682, single read-only session) and
`clipboard-upload` (port 7683) are unchanged by these files.

## Layout

| Source | Destination on DevVM |
|--------|----------------------|
| `tmux-attach.sh` | `/usr/local/bin/tmux-attach.sh` (chmod 0755) |
| `ttyd.service` | `/etc/systemd/system/ttyd.service` |
| `tmux-api.service` | `/etc/systemd/system/tmux-api.service` |
| `../index.html` (one level up) | `/usr/local/share/ttyd/index.html` |
| `../../tmux-api/` binary, built `GOOS=linux GOARCH=amd64` | `/usr/local/bin/tmux-api` (chmod 0755) |

## Apply

From the workstation (`infra/` repo root):

```bash
DEVVM=10.0.10.10   # SSH config provides the user

# 1. Build the tmux-api binary for linux/amd64
( cd infra/stacks/terminal/tmux-api && GOOS=linux GOARCH=amd64 go build -o /tmp/tmux-api . )

# 2. HTML page + wrapper script
scp infra/stacks/terminal/files/index.html $DEVVM:/tmp/index.html
scp infra/stacks/terminal/files/devvm/tmux-attach.sh $DEVVM:/tmp/tmux-attach.sh
ssh $DEVVM "sudo install -m 0644 /tmp/index.html /usr/local/share/ttyd/index.html && \
            sudo install -m 0755 /tmp/tmux-attach.sh /usr/local/bin/tmux-attach.sh && \
            rm /tmp/index.html /tmp/tmux-attach.sh"

# 3. tmux-api binary
scp /tmp/tmux-api $DEVVM:/tmp/tmux-api
ssh $DEVVM "sudo install -m 0755 /tmp/tmux-api /usr/local/bin/tmux-api && rm /tmp/tmux-api"

# 4. systemd units
scp infra/stacks/terminal/files/devvm/ttyd.service     $DEVVM:/tmp/
scp infra/stacks/terminal/files/devvm/tmux-api.service $DEVVM:/tmp/
ssh $DEVVM "sudo mv /tmp/ttyd.service     /etc/systemd/system/ && \
            sudo mv /tmp/tmux-api.service /etc/systemd/system/ && \
            sudo systemctl daemon-reload && \
            sudo systemctl enable --now tmux-api && \
            sudo systemctl restart ttyd"

# 5. Sanity checks
ssh $DEVVM "systemctl status ttyd tmux-api --no-pager"
ssh $DEVVM "curl -sf localhost:7684/sessions"
ssh $DEVVM "curl -sf localhost:7681/ | head -5"
ssh $DEVVM "systemctl is-active terminal-ro"   # unrelated unit, unaffected
```

## Notes

- **`User=wizard`** — single Unix user owns the tmux server. Sessions are
  shared across every browser tab that attaches.
- **ttyd version** must be ≥ 1.7 for the `-a` flag (allow URL args → argv).
  The DevVM currently has 1.7.7.
- **Argv flow**: `?arg=foo` on the URL → ttyd appends `foo` as `$1` to
  `tmux-attach.sh` → the wrapper regex-validates and runs
  `tmux new-session -A -s "$name"`. ttyd uses argv (never a shell string),
  so there is no injection path.
- **No external exposure of 7684/7681** — the DevVM is reachable only from
  the cluster (`10.0.10.10` is on the internal VLAN). Authentik forward-auth
  on the ingress is the access gate.
- **Cutover history** — `term.viktorbarzin.me` and `ttyd-multi.service`
  (port 7685) were the staging surface for this design. Both were retired
  in the same commit that promoted the multi-session config to port 7681.
