# DevVM terminal files

ttyd + tmux-api on the DevVM (`10.0.10.10`). ttyd serves the multi-session
lobby on port 7681 and attaches each Authentik identity into its own OS
user's tmux server. tmux-api (port 7684) backs the lobby's list/kill
actions, scoped to the same OS user.

`terminal-ro.service` (port 7682, single read-only session) and
`clipboard-upload` (port 7683) are unchanged by these files.

## Per-user isolation

The Authentik forward-auth middleware injects `X-authentik-username` on
every authenticated request:

1. **ttyd** is started with `-H X-authentik-username`, so the header value
   lands as `$TTYD_USER` in each launched `tmux-attach.sh` invocation.
2. **`tmux-attach.sh`** looks up `$TTYD_USER` in `/etc/ttyd-user-map`,
   denies the connection if there is no mapping, and otherwise
   `sudo -n -H -u <os_user> /usr/bin/tmux …`.
3. **`tmux-api`** reads `X-authentik-username` on every request and runs
   tmux as the mapped OS user too — so the lobby's session list is the
   intersection of "your Authentik identity" and "what tmux on that OS
   user's socket reports".

Different Authentik identities map to different Unix users, which means
different `/tmp/tmux-<uid>/default` sockets — kernel-level isolation,
not "the API filtered the list".

Adding a new user:

1. Append a line to `/etc/ttyd-user-map` (canonical at
   `files/devvm/ttyd-user-map`).
2. Append `wizard ALL=(<os_user>) NOPASSWD: /usr/bin/tmux` to
   `/etc/sudoers.d/ttyd-users` (canonical at
   `files/devvm/sudoers.d-ttyd-users`).
3. Ensure the OS user exists (`useradd -m <os_user>`).

## Layout

| Source | Destination on DevVM | Mode |
|--------|----------------------|------|
| `tmux-attach.sh` | `/usr/local/bin/tmux-attach.sh` | 0755 |
| `ttyd.service` | `/etc/systemd/system/ttyd.service` | 0644 |
| `tmux-api.service` | `/etc/systemd/system/tmux-api.service` | 0644 |
| `ttyd-user-map` | `/etc/ttyd-user-map` | 0644 |
| `sudoers.d-ttyd-users` | `/etc/sudoers.d/ttyd-users` | 0440, root:root |
| `../index.html` (one dir up) | `/usr/local/share/ttyd/index.html` | 0644 |
| `../../tmux-api/` Go binary | `/usr/local/bin/tmux-api` | 0755 |

## Apply

From the workstation (`infra/` repo root):

```bash
DEVVM=10.0.10.10   # SSH config provides the user

# 1. Build the tmux-api binary for linux/amd64
( cd infra/stacks/terminal/tmux-api && GOOS=linux GOARCH=amd64 go build -o /tmp/tmux-api . )

# 2. HTML + config files
scp infra/stacks/terminal/files/index.html                          $DEVVM:/tmp/index.html
scp infra/stacks/terminal/files/devvm/tmux-attach.sh                $DEVVM:/tmp/tmux-attach.sh
scp infra/stacks/terminal/files/devvm/ttyd-user-map                 $DEVVM:/tmp/ttyd-user-map
scp infra/stacks/terminal/files/devvm/sudoers.d-ttyd-users          $DEVVM:/tmp/sudoers.d-ttyd-users
ssh $DEVVM "
  sudo install -m 0644 /tmp/index.html              /usr/local/share/ttyd/index.html
  sudo install -m 0755 /tmp/tmux-attach.sh          /usr/local/bin/tmux-attach.sh
  sudo install -m 0644 /tmp/ttyd-user-map           /etc/ttyd-user-map
  sudo install -m 0440 -o root -g root /tmp/sudoers.d-ttyd-users /etc/sudoers.d/ttyd-users
  sudo visudo -cf /etc/sudoers.d/ttyd-users
  rm /tmp/index.html /tmp/tmux-attach.sh /tmp/ttyd-user-map /tmp/sudoers.d-ttyd-users
"

# 3. tmux-api binary
scp /tmp/tmux-api $DEVVM:/tmp/tmux-api
ssh $DEVVM "sudo install -m 0755 /tmp/tmux-api /usr/local/bin/tmux-api && rm /tmp/tmux-api"

# 4. systemd units
scp infra/stacks/terminal/files/devvm/ttyd.service     $DEVVM:/tmp/
scp infra/stacks/terminal/files/devvm/tmux-api.service $DEVVM:/tmp/
ssh $DEVVM "
  sudo mv /tmp/ttyd.service     /etc/systemd/system/
  sudo mv /tmp/tmux-api.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now tmux-api
  sudo systemctl restart ttyd
"

# 5. Sanity checks
ssh $DEVVM "systemctl status ttyd tmux-api --no-pager"
ssh $DEVVM "curl -sf -H 'X-Authentik-Username: vbarzin'    localhost:7684/whoami"
ssh $DEVVM "curl -sf -H 'X-Authentik-Username: emil.barzin' localhost:7684/whoami"
ssh $DEVVM "curl -si       -H 'X-Authentik-Username: nobody' localhost:7684/whoami | head -3"
```

## Notes

- **ttyd ≥ 1.7** required for the `-a` flag (URL args → argv). DevVM has 1.7.7.
- **Argv flow**: `?arg=foo` → ttyd appends `foo` as `$1` to `tmux-attach.sh`
  → wrapper regex-validates and runs `tmux new-session -A -s "$name"`. ttyd
  uses argv, never a shell string — no injection path.
- **No external exposure of 7681/7684** — DevVM is internal-VLAN-only;
  Authentik forward-auth is the access gate.
- **Cutover history** — `term.viktorbarzin.me` and `ttyd-multi.service`
  (port 7685) were the staging surface for this design; both retired
  when the multi-session config was promoted to port 7681. The
  per-Authentik-user isolation followed in a separate change.
