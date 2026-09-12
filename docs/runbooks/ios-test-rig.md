# Runbook — iOS test rig

A personal iPhone, permanently cabled to the London MacBook, driven from the
devvm over the WireGuard tunnel. Sideloads and drives custom builds with a
free Apple ID, no paid Apple Developer Program membership.

## At a glance

| Component | Where | What |
|---|---|---|
| iPhone 13 Pro `00008110-001614D03442801E` | London, on the cable | the device under test, iOS 26.5.2 at setup |
| `me.viktorbarzin.appium` | Mac LaunchAgent | Appium 3.5.2 + `xcuitest`, bound to `127.0.0.1:4723` |
| `me.viktorbarzin.wda-resign` | Mac LaunchAgent, every 48h | rebuilds and reinstalls WebDriverAgent before its 7-day certificate lapses |
| `ios-rig-tunnel.service` | devvm, `systemd --user` | SSH tunnel carrying Appium 4723, WDA 8100, and usbmuxd on 5000 |
| `ios-rig-doctor.timer` | devvm, `systemd --user`, 6-hourly | checks every link, posts to Slack when degraded |
| `scripts/ios-rig/` | this repo | the whole rig, including the Mac bootstrap |

```
devvm (Sofia)  ──WireGuard──▶  MacBook (London)  ──USB──▶  iPhone 13 Pro
  ios-rig CLI                    Appium :4723 (loopback)      WebDriverAgent
  SSH tunnel                     usbmuxd (unix socket)
  doctor timer                   WDA re-sign LaunchAgent
```

## Constraints worth knowing before you touch it

**The phone cannot be wiped.** Activation Lock is held by a different Apple ID
than the one that signs the builds. Erase All Content and Settings would need
that account's password to reactivate, so "wipe and start over" is not
available as a recovery step. Everything below is written to be recoverable
without it.

**Free personal team limits.** Certificates last 7 days, at most 3 sideloaded
apps are installed at once, and at most 10 App IDs can be registered per week.
WebDriverAgent permanently occupies one of the 3 slots, leaving 2 for apps
under test. A free team also cannot sign push notifications, App Groups, Live
Activities, Wallet, HealthKit, iCloud or associated domains; builds needing
those install and run but lose the feature.

**The build host is a corporate machine.** It is DEP-enrolled and MDM-managed,
runs an internally packaged Xcode, and `xcode-select` points at
CommandLineTools. Changing that needs sudo we do not have, so every Xcode call
sets `DEVELOPER_DIR` explicitly instead. It is also a laptop: when it travels,
the rig stops, which is expected rather than a fault.

**Signing has to happen on the Mac.** Minting a free Apple ID certificate and
re-signing WebDriverAgent from Linux was investigated on 2026-09-12 and no
working path was found for iOS 26. Exporting a free-team P12 and profile as
files is an open issue upstream, `AltServer-Linux` has been unmaintained since
2022, and nested-framework signing fails on the `.xctrunner` shape that
WebDriverAgent has. If that changes, the re-sign job is the only piece that
would move.

## Normal operation

```sh
scripts/ios-rig/ios-rig doctor          # check every link in the chain
scripts/ios-rig/ios-rig screenshot /tmp/shot.png
scripts/ios-rig/ios-rig screenshot /tmp/shot.png --url https://example.com --tap 200,400
```

`doctor` is the first thing to run for any symptom. It reports each link
separately, so it distinguishes "the laptop is away" from "WebDriverAgent's
certificate expired".

## Rebuilding from nothing

```sh
scripts/ios-rig/bootstrap-mac.sh        # installs tooling and both LaunchAgents
systemctl --user enable --now ios-rig-tunnel.service ios-rig-doctor.timer
```

Three steps need a human holding the phone, because Apple requires physical
confirmation and no amount of tooling gets around it:

1. **Trust this computer**, plus the passcode, when pairing is initiated.
2. **Developer Mode**, in Settings, Privacy and Security. The device restarts,
   then asks for the passcode again.
3. **Trust the developer profile**, in Settings, General, VPN and Device
   Management, after the first signed build is installed.

## Symptoms

### `doctor` says `pairing-lockdown` failed with "user denied the trust dialog"

iOS caches a denial and then stops showing the dialog, so retrying pairing
achieves nothing. CoreDevice and libimobiledevice keep **separate** trust
records, so `devicectl` can report `paired` while this is broken.

On the phone: Settings, General, Transfer or Reset iPhone, Reset, **Reset
Location & Privacy**. Then unplug and replug the cable, and tap Trust.

### `doctor` says `developer-mode` is disabled

Settings, Privacy and Security, Developer Mode. The menu item only appears
after a developer tool has connected at least once, which pairing does. The
device restarts and asks for the passcode.

### `doctor` says `wda-installed` is missing, or sessions fail after about a week

The 7-day certificate lapsed and the 48-hour re-sign job has not run, usually
because the laptop was closed. On the Mac:

```sh
~/bin/ios-rig-resign-wda.sh
tail -40 /tmp/wda-resign.log
```

### `doctor` says `ssh` failed

The Mac roams between the Flint LAN `192.168.8.0/24` and the Hyperoptic guest
network `192.168.9.0/24`, and takes a new DHCP address each time.

```sh
scripts/ios-rig/ios-rig discover
```

Then set `IOS_RIG_MAC_HOST`, or update `scripts/ios-rig/rig.env`.

### Appium answers but sessions hang at WebDriverAgent launch

Usually the screen is locked. WebDriverAgent cannot start against a locked
device. Unlock it and retry. If it persists, re-run the re-sign script, since
an expired certificate presents the same way.

### iOS updated itself and something broke

The device tracks iOS updates by choice rather than being pinned, so this is
expected occasionally. `doctor` reports the current version on every run.
Check whether the Appium `xcuitest` driver and libimobiledevice support the
new version before spending time debugging, and update them first.

## Security notes

Appium listens on `127.0.0.1` only. It bound to `0.0.0.0` until 2026-09-12,
which exposed full device control to anyone on the shared guest network the
laptop sits on. usbmuxd is reached the same way, through SSH unix-socket
forwarding rather than a `socat` listener, so the rig adds no open port to a
machine on an untrusted network.
