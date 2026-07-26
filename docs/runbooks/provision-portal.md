# Runbook: reprovision the London Meta Portal+ after a factory reset

**When to use:** the London Portal+ blinked **"Erasing"** / factory-reset itself
(it has done this before — an OTA colliding with a sideload-modified device), or
you have a fresh unit, and you need the kitchen-appliance setup back: the Immich
photo frame + Spotify + Home Assistant + the VirtualSoftKeys nav bar.

One command does the whole device side: **`infra/scripts/provision-portal.sh`**.

> Sofia's Portals (Emo Mini `192.168.1.104`, Office `192.168.1.149`) are a
> separate job — they were fully backed up to the NAS on 2026-07-26 and are on
> the older exploit toolkit. This runbook is **London only**.

## Nothing durable lives on the Portal

A wipe destroys no irreplaceable data — the device is a set of thin clients:

| Thing | Where it actually lives (survives a wipe) |
|---|---|
| The photos | Immich in-cluster (`immich` ns) → Synology `Viki/nfs/immich` offsite |
| Frame look (albums, interval, weather) | `infra/stacks/immich/frame.tf` + Vault (`frame_api_key`) |
| The frame APK | `portal-immich-frame` — one-command rebuild (`scripts/build-apk.sh`) |
| Frame signing key (for in-place `install -r`) | Vault `secret/portal-immich-frame` (`debug_keystore_b64`) |
| Spotify / HA content | your personal Spotify & Home Assistant accounts (cloud / `ha-*`) |

"Reprovision" therefore means **re-install from source, not recover device state.**

## The apps

| App | Package | Source | Notes |
|---|---|---|---|
| Immich frame | `me.viktorbarzin.portalframe` | built from source | thin WebView → `highlights-immich.viktorbarzin.me` (LAN-gated) |
| Spotify | `com.spotify.music` | apk-pure via apkeep, **latest** | split APK → `install-multiple` |
| VirtualSoftKeys | `tw.com.daxia.virtualsoftkeys` | F-Droid | floating Back/Home bar — the **only** way out of a fullscreen app |
| Home Assistant | `io.homeassistant.companion.android.minimal` | F-Droid | dashboards only; personal account |

## Flow

```mermaid
flowchart TD
    subgraph human["HUMAN — on the device (cannot be automated)"]
        H1["OOBE + join HOME Wi-Fi<br/>(frame endpoint is LAN-gated)"] --> H2["Take the OTA<br/>(official dev-access rollout)"]
        H2 --> H3["Enable ADB: About > tap Build Number 7x<br/>> Developer options > USB debugging"]
        H3 --> H4["Plug into the Mac, tap Allow"]
    end
    H4 --> S0
    subgraph script["provision-portal.sh — from the devvm"]
        S0["Preflight: adb sees 'aloha'"] --> S1["Build frame APK<br/>(Dockerized Gradle)"]
        S1 --> S2["apkeep (Docker): Spotify xapk<br/>+ pick arm64/v7a + density + en splits"]
        S2 --> S3["curl F-Droid: VirtualSoftKeys + HA"]
        S3 --> S4["scp all APKs to the Mac"]
        S4 --> S5["adb install (frame, VSK, HA)<br/>+ install-multiple (Spotify)"]
        S5 --> S6["settings: APPEND VSK to a11y list,<br/>grant SYSTEM_ALERT_WINDOW,<br/>never-sleep, launch frame"]
    end
    S6 --> H5["HUMAN: log into Spotify + HA,<br/>eyeball the slideshow + VSK pills"]
    style human fill:#1f2937,color:#fff
    style script fill:#0f3d3e,color:#fff
    style H5 fill:#7c2d12,color:#fff
```

## Human prerequisites (do these first, on the Portal)

The script starts from an **ADB-ready device**. It cannot do these:

1. Run OOBE, sign in, join the **home Wi-Fi** (the frame endpoint is source-IP
   LAN-gated since 2026-07-04 — it must be on the home LAN / London tunnel).
2. **Take the OTA update** (the ~June-2026 rollout that exposes Meta's official
   developer access). Do **not** re-apply the old `portal-toolkit` /
   CVE-2024-31317 exploit — that is what got the device wiped; the native ADB
   path below is the sanctioned one.
3. **Enable ADB (official path):** Settings → About → tap **Build Number** 7× →
   back out → **Developer options** → **USB debugging**. Plug into the Mac and
   tap **Allow** on the Portal screen.

## Run it

From the devvm (both `infra` and `portal-immich-frame` are checked out under
`~/code`):

```sh
~/code/infra/scripts/provision-portal.sh
```

Idempotent — safe to re-run. Useful env overrides:

| var | default | purpose |
|---|---|---|
| `MAC` | `viktorbarzin@192.168.8.168` | USB host on the Portal's LAN |
| `RADB` | `/Users/viktorbarzin/Library/Android/sdk/platform-tools/adb` | adb path on the Mac |
| `FRAME_REPO` | `$HOME/code/portal-immich-frame` | frame source for the build |
| `FRAME_URL` | *(build default = London)* | override to point the frame elsewhere |
| `NO_BUILD` | *(unset)* | `1` reuses an already-built frame APK |

## What it does (matches the script sections)

0. **Preflight** — confirms an authorized `aloha` device over adb.
1. **Build** the frame APK via the frame repo's Dockerized Gradle.
2. **apkeep** (containerized) fetches the latest Spotify `.xapk` from apk-pure,
   unzips it, and **dynamically selects** base + best ABI (arm64-v8a preferred,
   else armeabi-v7a — the Portal+ abilist includes 32-bit) + one density split +
   English. (apk-pure serves different variants over time, so the choice is not
   hard-coded.)
3. **curl** fetches VirtualSoftKeys + HA from **F-Droid's** stable
   `api/v1 + repo` URLs. (apkeep's own F-Droid index parser is broken in v1.0.0;
   the direct URLs are the durable path anyway.)
4. **scp** all APKs to the Mac.
5. **install** frame / VSK / HA, `install-multiple` for Spotify's splits.
6. **Appliance settings** (see below) and launch the frame.

## Appliance settings applied

- **VirtualSoftKeys accessibility bind — APPENDED, never replaced.** The script
  reads `secure enabled_accessibility_services` and appends
  `tw.com.daxia.virtualsoftkeys/…ServiceFloating`. **Critical:** the Portal's own
  `com.facebook.alohaservices.presence/…` and `…system.device/…` services must
  stay in that list — they drive presence detection and screen-on. Clobbering
  the list breaks the frame's wake behaviour.
- **`SYSTEM_ALERT_WINDOW = allow`** for VSK (its floating pills are an overlay).
- **Never-sleep:** `system screen_off_timeout = 2147483647`, `secure
  screensaver_enabled = 0`. The Portal+ is an always-mains LCD (no burn-in), and
  the frame also holds `FLAG_KEEP_SCREEN_ON` while foreground.

## Verify

The script prints the installed packages + the resumed activity. The rest is
**by eye** — `adb screencap` is black for the frame's hardware WebView surface:

- Immich highlights slideshow is showing.
- VirtualSoftKeys Back/Home pills appear (test Back exits an app to the launcher).
- Open **Spotify** and **Home Assistant** and log in (personal accounts).

## Troubleshooting

- **Spotify won't install (`INSTALL_FAILED_*`)** — the xapk variant apk-pure
  served lacks a split the device needs, or a required split was skipped. Re-run
  (apk-pure may serve a different variant), or inspect
  `/dev/shm/portal-provision.*/spotify/` for the available `config.*` splits.
- **"always-latest" Spotify risk** — a future Spotify may drop Android-9 / API-28
  support and refuse to install or launch. If that happens, pin an older build:
  `apkeep -a com.spotify.music@<version>` (list with `apkeep -a com.spotify.music -l`).
- **F-Droid fetch fails** — check `https://f-droid.org/api/v1/packages/<pkg>`
  returns a `suggestedVersionCode`; the APK is then `…/repo/<pkg>_<vc>.apk`.
- **Mac SSH bridge dead** (ping OK but port 22 times out) — the Mac slept or the
  VPN rerouted; wake it / check VPN. `caffeinate` mitigates sleep, not VPN.
- **Frame installs but the icon is blank/missing in the Apps grid** — launcher
  icon gotcha; see `portal-immich-frame` (needs an opaque legacy PNG at all
  densities, `versionCode` bump to refresh the launcher cache).

## Related

- Frame build / signing-key restore details: `portal-immich-frame/docs/runbooks/reprovision-after-factory-reset.md`
- Spec + rationale (grilling output): `https://plans.viktorbarzin.me/2026-07-26-portal-reprovision-spec.html`
- Server-side frame config: `infra/stacks/immich/frame.tf`
