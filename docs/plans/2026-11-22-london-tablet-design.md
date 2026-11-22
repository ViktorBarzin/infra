---
status: done
plan: true
---

# London tablet: remote adb and a Home Assistant app

Viktor wants Claude to operate the Xiaomi Pad 7 in the London flat from the devvm, and the tablet to open ha-london. The tablet stays a shared tablet for Viktor and Anca; Home Assistant is one app on it.

## In numbers

```numbers
caption: Measured on 2026-11-22 from the devvm, over the site-to-site tunnel
rows:
  - {label: Round trip from the devvm to the tablet, before: "-", after: "80-200 ms"}
  - {label: Time until wireless debugging is on again after a switch-off, before: "never", after: "under 25 s"}
  - {label: Time for android-adb to connect when port 5555 is open, before: "-", after: "4.5 s"}
  - {label: Time for android-adb to scan for the port after a restart, before: "-", after: "about 30 s"}
  - {label: Trackers on person.viktorbarzin from the tablet, before: "0", after: "0"}
```

## The system, with the change on it

```topology
caption: The devvm reaches the tablet with adb over the tunnel; the tablet reaches ha-london like a phone
direction: LR
groups:
  - {id: sofia, label: Sofia}
  - {id: london, label: London flat, 192.168.8.0/24}
nodes:
  - {id: devvm, label: devvm, note: "android-adb london-tablet", group: sofia, state: changed}
  - {id: flint, label: Flint2 router, note: "tunnel end; Sofia may open connections to every role", group: london, state: same}
  - {id: tablet, label: Xiaomi Pad 7, note: "192.168.8.188; HyperOS 3, Android 16", group: london, state: new}
  - {id: automate, label: Automate flow, note: "Keep wireless ADB on", group: london, state: new}
  - {id: ha, label: ha-london, note: "Companion app signed in as viktorbarzin", group: london, state: changed}
  - {id: milka, label: Milka's phone, note: "android-adb milka", scope: out}
edges:
  - {from: devvm, to: flint, state: same, label: WireGuard}
  - {from: flint, to: tablet, state: new, label: "adb, TLS"}
  - {from: automate, to: tablet, state: new, label: "adb_wifi_enabled = 1, every minute"}
  - {from: tablet, to: ha, state: new, label: "Companion app"}
  - {from: devvm, to: milka, state: changed, label: "same command, same key"}
checks:
  - {node: devvm, text: "android-adb london-tablet printed 192.168.8.188:5555 as wizard and as emo", status: passed}
  - {node: automate, text: "adb_wifi_enabled set to 0 over adb; the flow set it to 1 within 25 s and adb connected again", status: passed}
  - {node: ha, text: "ha-london has notify.mobile_app_london_tablet and battery sensors; person.viktorbarzin does not list device_tracker.london_tablet", status: passed}
  - {node: tablet, text: "The Home dashboard renders in portrait and landscape, screenshots over adb", status: passed}
left_out:
  - RustDesk on the tablet. adb gives screenshots, taps, typing and installs, and nobody needs to watch the screen live.
  - A kiosk mode or a screen that stays on. The tablet is shared.
  - A tablet-specific dashboard. The existing Home dashboard fits the 11-inch screen.
```

## Decisions

```decision
- question: What is the tablet for?
  options:
    - {name: A dedicated Home Assistant panel, note: "locks out other use"}
    - {name: A shared tablet with the Home Assistant app on it, chosen: true}
  why: Viktor and Anca also use it for other things.
- question: How does Claude reach it?
  options:
    - {name: "Wireless debugging, kept on by an Automate flow", chosen: true}
    - {name: "adb and RustDesk", note: "one more app and a password for live viewing nobody asked for"}
  why: The same method works on Milka's phone since 2026-10-10.
- question: Which helper command?
  options:
    - {name: "milka-adb with an IP argument", note: "the name says Milka"}
    - {name: "android-adb <device>, milka-adb removed", chosen: true}
  why: One command for every family Android device, with a device list in the script.
- question: Which adb key?
  options:
    - {name: "The shared key that Milka's phone trusts", chosen: true}
    - {name: "A new key for wizard only", note: "a second pairing at the tablet"}
  why: Viktor prefers one key; emo can reach the tablet too.
- question: Which Home Assistant account?
  options:
    - {name: "Viktor's account, location off", chosen: true}
    - {name: "A new non-admin user", note: "not chosen"}
  why: Viktor's choice. Location stays off, so the tablet does not change his presence.
- question: How does Claude get past the lock screen?
  options:
    - {name: "The PIN in Vault secret/london-tablet; unlock for a session, lock after", chosen: true}
    - {name: "No PIN", note: "anyone who picks up the tablet gets in, with the Google account on it"}
  why: Auto-lock stays as it is.
```

## How it works

HyperOS switched wireless debugging off about ten minutes after the screen went to sleep. The adb connection then closed. The Automate flow sets `adb_wifi_enabled` to 1, waits one minute (inexact, no wake-up), and repeats. Automate holds `WRITE_SECURE_SETTINGS`, the HyperOS autostart permission, and an exemption from battery optimisation. It starts at boot through its "Run on system startup" setting.

adb works while the tablet sleeps and is locked: shell commands, installs, settings and screenshots. Taps inside apps need an unlocked screen. Unlock it with the PIN, do the work, then press power to lock it again.

After a restart, nothing runs until someone unlocks the tablet once by hand. The connect port also changes after a restart, so `android-adb` scans ports 30000-50000 for it.

When the Companion app signed in, ha-london added `device_tracker.london_tablet` to `person.viktorbarzin` by itself. A `person/update` call over the WebSocket API removed it again. Do the same after you sign the app in again.

## Configuration

```config
- {key: android-adb, where: "playbooks/files/devvm/android-adb, /usr/local/bin", old: "milka-adb", new: "android-adb milka|london-tablet [ip]"}
- {key: milka-help, where: playbooks/files/devvm/milka-help, old: "milka-adb", new: "android-adb milka"}
- {key: adb key, where: "~/.android/milka-adbkey (wizard and emo)", old: "Milka's phone", new: "Milka's phone and the London tablet"}
- {key: tablet PIN, where: "Vault secret/london-tablet, field pin", old: "-", new: "6 digits"}
- {key: Automate flow, where: tablet, old: "-", new: "Keep wireless ADB on: set Global adb_wifi_enabled 1, delay 60 s inexact"}
- {key: Companion app, where: tablet, old: "not signed in", new: "ha-london as viktorbarzin, device name London tablet, location denied"}
```

## Commands

```sh
export ADB_SERVER_SOCKET=tcp:localhost:5039 ADB_VENDOR_KEYS=$HOME/.android/milka-adbkey
D=$(android-adb london-tablet)
adb -s "$D" shell input keyevent KEYCODE_WAKEUP
adb -s "$D" shell wm dismiss-keyguard
adb -s "$D" shell input text "$(vault kv get -field=pin secret/london-tablet)"
adb -s "$D" shell input keyevent 66
adb -s "$D" exec-out screencap -p > shot.png
adb -s "$D" shell input keyevent KEYCODE_POWER
```
