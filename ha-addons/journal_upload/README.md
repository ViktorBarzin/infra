# Journal upload add-on (ha-london)

This Home Assistant OS add-on streams the host's systemd journal to the
homelab Loki. The journal holds everything on the Pi: kernel lines (out of
memory kills, Wi-Fi driver errors), Home Assistant Core, the Supervisor and
every add-on. In Loki it is `{job="systemd-journal", host="ha-london"}`.

## How it works

HAOS ships `systemd-journal-upload` and its hardened unit, switched off. HAOS
keeps `/etc` read-only, so the add-on cannot enable the unit for good. Instead,
at every start it:

1. enters the host's mount namespace (`nsenter -t 1 -m`),
2. writes `/run/systemd/system/systemd-journal-upload.service.d/50-homelab.conf`
   (tmpfs, so it is gone after a reboot until the add-on starts again),
3. reloads systemd and restarts the unit,
4. checks every 60 s that the unit is active and restarts it if not.

The drop-in sets the receiver URL and runs the unit as the static
`systemd-journal-upload` user instead of a dynamic one. HAOS keeps
`/var/lib/private` on tmpfs but `/var/lib/systemd` on the data partition, so
only with a static user does the cursor file `/var/lib/systemd/journal-upload/state`
survive a reboot. With the cursor kept, a tunnel outage or a reboot sends the
backlog when the receiver is back. The first run has no cursor and starts at
the beginning of the current boot.

The uploader rewrites its cursor after every batch, every few seconds. Since
1.2.0 it writes it to `/run/journal-upload/state` in RAM; the add-on copies
that to the card file hourly and when it stops (once per boot it seeds the RAM
file from the card file). On the card that rewrite cost about 0.05 GB a day of
filesystem journal writes. After a freeze the uploader resumes from the last
hourly copy; Loki drops lines it already has with the same timestamp.

Stopping the add-on stops the uploader and removes the drop-in.

## Journal in RAM

Since 1.1.0 the add-on also keeps the host's journal in RAM instead of on the
SD card, as the cluster nodes and the Proxmox host do. Loki has the logs; the
card copy cost about 0.5 GB of writes a day on ha-london for about 1.9 MB of
log text, because journald rewrites scattered pages of its file every 30 s.

- At start it runs `journalctl --relinquish-var`, writes
  `/run/systemd/journald.conf.d/50-homelab.conf` (`RuntimeMaxUse=48M`) and
  restarts journald once to read it. The uploader reads the RAM journal the
  same way it read the card.
- Every 60 s, if journald has gone back to the card (the
  `/run/systemd/journal/flushed` flag is set), it relinquishes again.
- At stop, which a clean reboot does before journald stops, it runs
  `journalctl --flush`: the RAM journal goes to the card, and journald writes
  there again. The upload cursor then sends those entries after the reboot.
  `timeout: 60` in `config.yaml` gives the flush time.

48 MB holds about 4 days at ha-london's ~11 MB a day; past that, journald drops
the oldest entries, uploaded or not. A freeze or a power cut loses whatever the
uploader had not sent yet. The first minute or two of each boot, before the
add-on starts, still goes to the card.

The receiver is the `alloy-journal` pod in `stacks/monitoring`
(`alloy_journal.tf`), at `http://10.0.20.200:19532` over the WireGuard tunnel.
Its `journal-remote` container writes the upload to journal files and Alloy
reads them into Loki.

## Labels

| label | from | examples |
|---|---|---|
| `host` | machine id (every HAOS host is called `homeassistant`) | `ha-london` |
| `container` | `CONTAINER_NAME` (Docker's journald driver) | `homeassistant`, `hassio_supervisor`, `app_local_led_strip` |
| `app` | `SYSLOG_IDENTIFIER` | `kernel`, `homeassistant`, `NetworkManager` |
| `unit` | `_SYSTEMD_UNIT` | `docker.service` |
| `level` | `PRIORITY` | `err`, `warning`, `info` |

One-off `docker run --rm` helpers (the `nsenter` commands in the runbooks)
show up under Docker's random names, such as `container="beautiful_curran"`.
Name them with `--name` to make their lines easy to find.

## Privileges

`host_pid`, `SYS_ADMIN` and `SYS_PTRACE` with AppArmor off: entering PID 1's
mount namespace needs all of them. The add-on itself is a shell loop, about
1 MB of RAM; the uploader is the host's C binary.

## Alerts

Loki group "Off-cluster host journals" in `stacks/monitoring/modules/monitoring/loki.tf`:

- `HostOutOfMemoryKill` pages on any kernel `Out of memory: Killed process` line.
- `HostJournalSilent` warns when ha-london sends nothing for 30 minutes.

## Deploy

Bump `version` in `config.yaml`, land the change on master (GitHub Actions
builds `ghcr.io/viktorbarzin/ha-addon-journal-upload:<version>` for arm64 and
amd64), then run `./deploy.sh`. It waits for the tag, copies the add-on to
`/addons/journal_upload` on ha-london, and installs or updates it.

## Checks

```sh
homelab logs query '{job="systemd-journal", host="ha-london"}' --since 10m
homelab ha ssh --instance london -- 'sudo docker run --rm --privileged --pid=host --entrypoint nsenter docker:29.1.3-cli -t 1 -m -- systemctl status systemd-journal-upload'
```

```sh
# journal in RAM: flushed absent, RAM journal growing, card journal mtime old
homelab ha ssh --instance london -- 'sudo docker run --rm --privileged --pid=host --entrypoint nsenter docker:29.8.2-cli -t 1 -m -- sh -c "ls /run/systemd/journal/flushed; du -sh /run/log/journal; ls -l /var/log/journal/*/system.journal"'
```

Tests for the drop-in rendering: `sh test_lib.sh`.
