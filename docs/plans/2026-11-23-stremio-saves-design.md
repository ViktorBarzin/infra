---
status: executing
plan: true
---

# Save films and episodes in Stremio to watch later

Viktor wants to tick a film, an episode or a season in Stremio and find it ready later, with English subtitles. Real-Debrid refuses many releases, such as all of Undercover season 6, so the "Our server" addon gets Save rows, a downloader and a cleanup.

## In numbers

```numbers
caption: measured 2026-11-23 on the servarr NFS share and in qBittorrent
rows:
  - {label: Undercover S6 episodes playable in Stremio, before: "2 of 7 (Real-Debrid)", after: "7 of 7, and E8 to E12 as they air"}
  - {label: Free space on the downloads share, before: "557 GB of 4 TB", after: "at least 257 GB (300 GB cap)", better: false}
  - {label: Saved videos in the nightly backup, before: "15 GB", after: "0 GB"}
  - {label: Stremio logins stored for this, before: "0", after: "0"}
```

## The system, with the change on it

```topology
caption: a Save row starts a copy on Real-Debrid or on our server; the Saved row plays it through Sofia
direction: LR
groups:
  - {id: dev, label: Stremio devices}
  - {id: k8s, label: Sofia cluster}
  - {id: ext, label: Outside}
nodes:
  - {id: proj, label: London projector and tablet (shared account), group: dev, state: same}
  - {id: tv, label: "emo's TV (his account, Sofia LAN)", group: dev, state: same}
  - {id: lib, label: library addon, note: "Save rows, Saved rows, Home list, downloader, cleanup", group: k8s, state: changed, risk: medium}
  - {id: db, label: SQLite saves database, note: "own volume, backed up", group: k8s, state: new, risk: low}
  - {id: aio, label: AIOStreams, note: "finds releases (base config, emo's sofia variant)", group: k8s, state: same}
  - {id: qb, label: qBittorrent, note: "category stremio, ratio 1", group: k8s, state: changed, risk: low}
  - {id: nfs, label: NFS downloads/stremio, note: never backed up, group: k8s, state: same}
  - {id: rd, label: Real-Debrid, group: ext, state: same}
  - {id: subs, label: OpenSubtitles, group: ext, state: same, scope: out}
edges:
  - {from: proj, to: lib, state: changed, label: rows and video (DNS-only host)}
  - {from: tv, to: lib, state: new, label: rows and video (internal host)}
  - {from: lib, to: db, state: new}
  - {from: lib, to: aio, state: new, label: release search}
  - {from: lib, to: rd, state: new, label: "add magnet, play link"}
  - {from: lib, to: qb, state: new, label: add torrent when RD refuses}
  - {from: qb, to: nfs, state: same}
  - {from: lib, to: nfs, state: same, label: read files}
  - {from: proj, to: subs, state: same}
checks:
  - {node: lib, text: "unit tests for picking, states, watched and cleanup; a save of a new film on the projector plays with English subtitles", status: open}
  - {node: tv, text: emo's TV shows Bulgarian rows and plays a saved file over the internal host, status: open}
  - {node: qb, text: a finished torrent stops at ratio 1, status: open}
  - {node: rd, text: a release Real-Debrid accepts plays from the Saved row through Sofia, status: open}
left_out:
  - re-seeding renamed copies so that Real-Debrid accepts them (gets around its copyright filter)
  - Sonarr (a new service, and no Prowlarr indexer carries these releases)
  - a separate web page for ticking (Stremio rows cover it)
  - reading watched flags from the Stremio accounts (needs both logins in Vault)
```

## Decisions

```decision
- question: Where does a viewer tick what to save?
  options:
    - {name: Rows in Stremio on each film and episode, chosen: true}
    - {name: A web page with checklists, note: a new app to open}
  why: no new app; it works on the projector, the tablet and the web
- question: Where does a copy go?
  options:
    - {name: "Real-Debrid first, our server when it refuses or finds no seeders", chosen: true}
    - {name: Always our server, note: disk and Sofia bandwidth for every save}
  why: Real-Debrid copies take no space here
- question: Which release is saved?
  options:
    - {name: "Automatic, 1080p first, largest up to 6 GB; Bulgarian audio first for emo", chosen: true}
    - {name: The viewer picks each time, note: more taps}
  why: one tap per save
- question: How does a viewer see progress?
  options:
    - {name: "The row shows Saving 45% or Saved, and a Saved list on Home", chosen: true}
    - {name: Phone notifications, note: not wanted}
  why: status where the viewer already looks
- question: What counts as watched?
  options:
    - {name: An account played past 90% of the copy through our row, chosen: true}
    - {name: The watched flag in each Stremio account, note: needs emo's login in Vault}
  why: no Stremio logins stored
- question: When does a copy go?
  options:
    - {name: "Server copies 7 days after all savers watched, plus a 300 GB cap, oldest unwatched first; Real-Debrid copies stay", chosen: true}
    - {name: Only by hand, note: the share fills up}
  why: nobody loses an episode they have not seen
- question: What if no copy is found?
  options:
    - {name: "Retry every 6 hours for 14 days, then No copy found and Try again", chosen: true}
    - {name: Retry forever, note: a dead save never says so}
  why: a followed episode starts its 14 days on its air date
- question: Where does the code live?
  options:
    - {name: "The existing Python library addon in stacks/stremio, with SQLite", chosen: true}
    - {name: A new TanStack Start app, note: a second service for the same rows}
  why: an existing app keeps its stack
```

A Save row and its Saved row share one link per episode. Until the copy is ready, that link plays a short clip that says "Saved" or "Saving 45%". After that, the same link plays the episode. Continue Watching opens the last row that was tapped, so this rule keeps it on the episode.

Each account installs its own manifest URL, `/<token>/a/<account>/manifest.json`. The URL tells the addon which account saves and which account watches. emo's rows use `stremio-library-lan.viktorbarzin.me`, because his TV finds no route to our public address from the Sofia LAN.

## Order of work

```timeline
caption: every step before the last can be undone by a revert and an apply
steps:
  - {when: done, what: "backup exclusion for downloads/stremio; Undercover E1 to E7 on our server", rollback: revert aaedb8e44}
  - {when: step 1, what: "saves database, Save rows, the clip, the downloader (Real-Debrid, then qBittorrent), tests", rollback: revert and apply stacks/stremio}
  - {when: step 2, what: "watched tracking, cleanup and the 300 GB cap, Saved list on Home", rollback: revert and apply}
  - {when: step 3, what: "internal host and Bulgarian labels for emo", rollback: revert and apply}
  - {when: step 4, what: "install the account manifests; import Undercover E1 to E7 as Viktor's follow of season 6", rollback: remove the addon from each account}
  - {when: step 5, what: "the first cleanup run deletes files", ponr: true}
```

## Configuration

```config
- {key: Real-Debrid API key, where: Vault secret/stremio rd_api_key (ExternalSecret into stremio/library), old: "only in the AIOStreams user config", new: "also in Vault"}
- {key: share limit of category stremio, where: qBittorrent, old: "none", new: "ratio 1"}
- {key: stremio-library-lan.viktorbarzin.me, where: stacks/stremio/library.tf, old: "none", new: "dns_type internal, home LANs only"}
- {key: library addon on emo's account, where: emostremio@ addon collection, old: "none", new: "/<token>/a/emo/manifest.json"}
```

## Commands

```sh
cd stacks/stremio/files && python3 -m unittest test_library test_saves
homelab tf plan stremio
homelab tf apply stremio
```
