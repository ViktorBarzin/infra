---
status: done
plan: true
---

# Subtitles that match the sound, with no tap in Stremio

Downloaded subtitles often belong to a different release, so they run early or late. Viktor wants to open a film in Stremio and get subtitles that match the speech, with nothing to choose.

## In numbers

```numbers
caption: measured 2026-11-28 on Undercover S6E2 (our server copy) and its only English subtitle on OpenSubtitles
rows:
  - {label: English subtitle offset on our copy, before: "9.9 s late", after: "0 s"}
  - {label: "Time to sync (whole episode, then a 10-minute sample; same result to 0.01 s)", before: "51 s", after: "10 s"}
  - {label: Taps to get synced subtitles, before: "manual delay in the player", after: "0"}
```

## The system, with the change on it

```topology
caption: when Stremio asks for subtitles, the library addon finds the playing file, listens to 10 minutes of it and returns English (synced) first
direction: LR
groups:
  - {id: dev, label: Stremio devices}
  - {id: k8s, label: Sofia cluster}
  - {id: ext, label: Outside}
nodes:
  - {id: proj, label: London projector and tablet (shared account), group: dev, state: same}
  - {id: lib, label: library addon, note: "new subtitles resource, sync worker, ffmpeg and ffsubsync", group: k8s, state: changed, risk: medium}
  - {id: img, label: stremio-library image, note: "Python, ffmpeg, ffsubsync; built by GitHub Actions", group: k8s, state: new, risk: low}
  - {id: nfs, label: NFS downloads/stremio, note: saved copies, group: k8s, state: same}
  - {id: aio, label: AIOStreams, note: plays Real-Debrid through the Sofia proxy, group: k8s, state: same}
  - {id: rd, label: Real-Debrid, group: ext, state: same}
  - {id: os, label: OpenSubtitles v3 (strem.io), group: ext, state: same}
edges:
  - {from: proj, to: lib, state: new, label: "subtitles request (film id, file size, file name)"}
  - {from: lib, to: os, state: new, label: English subtitles}
  - {from: lib, to: rd, state: new, label: "downloads list, first 10 minutes of the file"}
  - {from: lib, to: nfs, state: same, label: first 10 minutes of a saved copy}
  - {from: proj, to: aio, state: same, label: video}
  - {from: aio, to: rd, state: same}
  - {from: img, to: lib, state: new}
checks:
  - {node: lib, text: "unit tests: file match by size, sync result cached, original served when the sync fails", status: passed}
  - {node: proj, text: "Undercover S6E2 from our server shows the synced lines in time on a Stremio TV (emo's BRAVIA; the projector was off the network)", status: passed}
  - {node: proj, text: "automatic selection of English (synced): the TV app puts OpenSubtitles v3 first, so it is a pick by hand", status: failed}
  - {node: rd, text: a Real-Debrid file found by size and synced on a device, status: open}
left_out:
  - emo's account (his TV has automatic subtitle selection off)
  - streams from P2P via Sofia (the addon cannot read their file yet)
  - Bulgarian subtitles
  - hosted sync addons such as Subtitle Sync (they compare subtitles with subtitles, not with the sound, and need an OpenSubtitles login)
```

## Decisions

```decision
- question: What does the sync compare the subtitle with?
  options:
    - {name: "The sound of the playing file (ffsubsync)", chosen: true}
    - {name: "Other subtitles of the same film", note: "Undercover has one English subtitle, so there is nothing to compare with"}
  why: it works when only one subtitle exists
- question: How much sound does the sync read?
  options:
    - {name: "The first 10 minutes", chosen: true}
    - {name: The whole file, note: "51 s, too slow for the start of a film"}
  why: the result was the same to 0.01 s and takes 10 s
- question: Where does the sync run?
  options:
    - {name: "In the library addon, on a new image with ffmpeg and ffsubsync", chosen: true}
    - {name: A separate service, note: a second service for the same request}
  why: the addon already knows the saved copies and holds the Real-Debrid key
- question: How does the addon find the playing file?
  options:
    - {name: "By file size: a saved copy first, then the Real-Debrid downloads list", chosen: true}
    - {name: Through the AIOStreams proxy, note: "its guard allows two streams at once, and the sync read would take one"}
  why: Stremio sends the file size, and the Real-Debrid read leaves from the same Sofia address as the video
- question: What happens to the other subtitles?
  options:
    - {name: "They stay in the list below English (synced)", chosen: true}
    - {name: Hide them, note: no way back when a sync is wrong}
  why: a wrong sync is one tap from the original
```

When Stremio asks for subtitles, the addon starts the sync and answers at once with a link to "English (synced)". That link waits for the sync, at most 30 seconds. A sync that fails, or a file the addon cannot find, gives the original subtitle on the same link. The addon keeps each result, so the second play starts with no wait.

The device check on emo's TV showed that the Stremio TV app lists OpenSubtitles v3 first in the English group, whatever the addon order. Automatic selection therefore picks OpenSubtitles. Viktor chose to keep every subtitle source, so the synced track is one pick by hand: English, then Our server.

## Order of work

```timeline
caption: every step can be undone by a revert and an apply
steps:
  - {when: step 1, what: "images/stremio-library and its GitHub Actions build", rollback: revert}
  - {when: step 2, what: "subtitles resource, file match, sync worker, cache, tests; library on the new image", rollback: revert and apply stacks/stremio}
  - {when: step 3, what: "refresh the Our server manifest (1.2.0) on the shared account; it already sits above the subtitle addons", rollback: none needed}
  - {when: step 4, what: "device checks on the projector", rollback: none needed}
```

## Configuration

```config
- {key: library image, where: stacks/stremio/library.tf, old: "python:3.15.2-alpine", new: "ghcr.io/viktorbarzin/stremio-library"}
- {key: viktor manifest resources, where: stacks/stremio/files/library.py, old: "stream, catalog", new: "stream, catalog, subtitles"}
- {key: Our server manifest, where: shared stremio@ addon collection, old: "1.1.0, catalog and stream", new: "1.2.0, with subtitles"}
```

## Commands

```sh
cd stacks/stremio/files && python3 -m unittest test_library test_saves test_subtitles
homelab tf plan stremio
homelab tf apply stremio
```
