# ADR-0035: Windows apps run under Wine in the cluster, starting with iVMS-4200

- Status: accepted
- Date: 2026-10-17
- Related: `modules/kubernetes/wine_app/`, `images/wine-app/`, `stacks/ivms/`, `playbooks/pfsense-vermont-alias.yml`, `playbooks/rpi-sofia-netmap.yml`, `docs/plans/2026-10-17-ivms-in-cluster-design.md`, `docs/runbooks/cameras-nvr-intercom.md`, infra#121, infra#123, ADR-0036 (remote display chosen by benchmark)

## Context

Emil manages access control at the Vermont complex after the handover from
the previous maintenance company. The 6 entrance panels and the access
terminal each keep their own list of people, cards and faces, so every change
to a resident is repeated on each device. Hikvision's tool for one shared list
is iVMS-4200, a Windows client.

On 2026-10-17 Emil's session prepared VM 300 (Windows 10, 8 GB, already
swapping) for iVMS, and gave the complex network a second, non-overlapping
range on rpi-sofia: `10.77.1.x` maps 1:1 to the complex's `192.168.1.x`. The
next steps needed a reboot of VM 300, a display change and 12 GB of RAM
(infra#121). Viktor asked for an approach that keeps iVMS's graphical
interface without a Windows VM running for it, and that also serves the next
Windows apps Emil will want.

What we checked:

- iVMS-4200 V3.14.1.4 under WineHQ 11.0 in a Debian container installs and
  runs. Person, Card, Access Group and Video Intercom work, and a Hikvision
  indoor station logged in and showed Online. While awake it uses about
  3.2 GB of RAM and 0.67 of a core.
- iVMS-4200 for Mac has no access control. Hikvision ships no Linux client,
  and HikCentral is Windows-only.
- No maintained self-hosted tool syncs people across Hikvision devices.
- Sablier does not refresh its session on WebSocket traffic (ADR-0022), and a
  noVNC session is one long WebSocket.
- pfSense's automatic rule for traffic from its own WAN address routes to the
  TP-Link, so traffic NATed to that address cannot be routed to the Pi.
- v1alpha1 AdminNetworkPolicy is not enforced since Calico 3.33 (infra#123);
  ClusterNetworkPolicy v1alpha2 is the current form.

## Decision

1. Each Windows app runs in its own pod from the shared module
   `modules/kubernetes/wine_app`, shown in the browser through noVNC behind
   Authentik. iVMS is the first, at `ivms.viktorbarzin.me`, for Home Server
   Admins.
2. All apps share one public base image, `ghcr.io/viktorbarzin/wine-app`
   (Wine, noVNC, no app). Each app's installer is downloaded, checked by
   sha256 and installed into its Wine prefix on its PVC on first start, by the
   app's own `install.sh`. No proprietary installer is in any registry.
3. A pod sleeps when idle: a wake gate copied from the android-emulator stack
   starts it on visit, and a CronJob stops it after 30 minutes with no viewer
   or 2 hours with no keyboard or mouse input.
4. pfSense routes `10.77.1.0/24` to rpi-sofia without NAT, for the k8s nodes
   and the devvm, and blocks every other source. The Pi allowlists the same
   addresses. A ClusterNetworkPolicy denies that range to every namespace
   except `ivms`. The disabled `4g_router` gateway, which pointed at the Pi's
   address, is deleted.
5. The Pi's `vermont-netmap` rules move into `playbooks/rpi-sofia-netmap.yml`,
   and the pfSense side into `playbooks/pfsense-vermont-alias.yml`.
6. VM 300's route, snapshot and installer stay in place as a dormant fallback.
7. iVMS's scope is access control. Live view stays with Frigate and Home
   Assistant.
8. Apps that do not run under Wine are decided one by one.

## Consequences

- No Windows licence and no VM held running. A pod uses its memory only while
  someone is using it (iVMS: 3.5Gi requested).
- The first start of an app takes several minutes while it installs. Later
  wakes take about one to two minutes.
- iVMS stops collecting live events while it sleeps. The panels and the
  terminal keep their own event logs, which iVMS can search on the device.
- Under Wine, scrolling over a dropdown changes its value. The iVMS setup
  checks the system settings, with "Auto-Upgrade Device" set to Disable.
- An app upgrade is a version and sha256 bump in its `app.env`; the next start
  runs the new installer over the existing prefix.
- Every devvm user and container can reach the complex devices, guarded by
  the device passwords. Emil's `~/bin` tools can use the alias instead of
  per-device SSH tunnels.
- The complex network becomes a dependency of a cluster service through
  rpi-sofia, a Pi 3 with an ageing SD card. If the Pi is down, iVMS shows the
  devices offline and nothing else in the cluster is affected.
- The k8s node list is written in two places (pfSense alias, Pi allowlist). A
  new node needs both, or its pods cannot reach the complex.
