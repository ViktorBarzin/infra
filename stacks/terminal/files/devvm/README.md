# DevVM terminal-multi files

These files configure the multi-session terminal on the DevVM (`10.0.10.10`).
They install **alongside** the existing `ttyd.service` (port 7681) and
`ttyd-ro.service` (port 7682) — the existing units are **not** modified.

## Layout

| Source | Destination on DevVM |
|--------|----------------------|
| `tmux-attach.sh` | `/usr/local/bin/tmux-attach.sh` (chmod 0755) |
| `ttyd-multi.service` | `/etc/systemd/system/ttyd-multi.service` |
| `tmux-api.service` | `/etc/systemd/system/tmux-api.service` |
| `../index-multi.html` (one level up) | `/usr/local/share/ttyd/index-multi.html` |
| `../../tmux-api/` binary, built `GOOS=linux GOARCH=amd64` | `/usr/local/bin/tmux-api` (chmod 0755) |

## Apply

From the workstation (`infra/` repo root):

```bash
DEVVM=10.0.10.10   # SSH config provides the user

# 1. Build the tmux-api binary for linux/amd64
( cd infra/stacks/terminal/tmux-api && GOOS=linux GOARCH=amd64 go build -o /tmp/tmux-api . )

# 2. HTML page + wrapper script
scp infra/stacks/terminal/files/index-multi.html $DEVVM:/tmp/index-multi.html
scp infra/stacks/terminal/files/devvm/tmux-attach.sh $DEVVM:/tmp/tmux-attach.sh
ssh $DEVVM "sudo install -m 0644 /tmp/index-multi.html /usr/local/share/ttyd/index-multi.html && \
            sudo install -m 0755 /tmp/tmux-attach.sh    /usr/local/bin/tmux-attach.sh && \
            rm /tmp/index-multi.html /tmp/tmux-attach.sh"

# 3. tmux-api binary
scp /tmp/tmux-api $DEVVM:/tmp/tmux-api
ssh $DEVVM "sudo install -m 0755 /tmp/tmux-api /usr/local/bin/tmux-api && rm /tmp/tmux-api"

# 4. systemd units
scp infra/stacks/terminal/files/devvm/ttyd-multi.service $DEVVM:/tmp/
scp infra/stacks/terminal/files/devvm/tmux-api.service   $DEVVM:/tmp/
ssh $DEVVM "sudo mv /tmp/ttyd-multi.service /etc/systemd/system/ && \
            sudo mv /tmp/tmux-api.service   /etc/systemd/system/ && \
            sudo systemctl daemon-reload && \
            sudo systemctl enable --now ttyd-multi tmux-api"

# 5. Sanity checks
ssh $DEVVM "systemctl status ttyd-multi tmux-api --no-pager"
ssh $DEVVM "curl -sf localhost:7684/sessions"
ssh $DEVVM "curl -sf localhost:7685/ | head -5"
ssh $DEVVM "systemctl is-active ttyd ttyd-ro"   # existing units untouched
```

## Notes

- **`User=wizard`** matches the existing `ttyd.service` so the new services
  share the same tmux server (one socket per Unix user). Sessions created
  via either `terminal.viktorbarzin.me` or `term.viktorbarzin.me` are
  cross-visible. This is intentional.
- **ttyd version** is `1.7.7` on the DevVM — the `-a` flag (allow URL args
  → argv) requires ≥ 1.7.
- **Argv flow**: `?arg=foo` on the URL → ttyd appends `foo` as `$1` to
  `tmux-attach.sh` → the wrapper regex-validates and runs
  `tmux new-session -A -s "$name"`. ttyd uses argv (never a shell string),
  so there is no injection path.
- **No external exposure of 7684/7685** — the DevVM is reachable only from
  the cluster (`10.0.10.10` is on the internal VLAN). Authentik forward-auth
  on the ingress is the access gate.
