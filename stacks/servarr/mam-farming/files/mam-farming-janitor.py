"""
MAM farming janitor — H&R-aware cleanup.

Runs every 15 minutes independently of the grabber's ratio guard: stuck
torrents accumulate fastest precisely when the grabber is skipping. Never
deletes a torrent that's inside MAM's 72-hour Hit-and-Run window.

Set DRY_RUN=1 to log candidates without deleting (used for the first
24 hours after rollout to sanity-check the rules against live state).
"""
import json
import os
import sys
import time

import requests

QB_URL = "http://qbittorrent.servarr.svc.cluster.local"
PUSHGW = "http://prometheus-prometheus-pushgateway.monitoring:9091"

DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
HNR_SEED_SECONDS = int(os.environ.get("HNR_SEED_SECONDS", str(72 * 3600)))
NEVER_STARTED_AGE = int(os.environ.get("NEVER_STARTED_AGE", str(24 * 3600)))
STALLED_AGE = int(os.environ.get("STALLED_AGE", str(3 * 86400)))
SATISFIED_SEED_AGE = int(os.environ.get("SATISFIED_SEED_AGE", str(3 * 86400)))
SATISFIED_SEEDER_FLOOR = int(os.environ.get("SATISFIED_SEEDER_FLOOR", "5"))
GRACEFUL_SEED_AGE = int(os.environ.get("GRACEFUL_SEED_AGE", str(14 * 86400)))
ZERO_DEMAND_AGE = int(os.environ.get("ZERO_DEMAND_AGE", str(7 * 86400)))
UNREG_KEYWORDS = ("unregistered", "torrent not found", "info hash not authorized")

REASONS = (
    "never_started",
    "stalled_old",
    "satisfied_redundant",
    "graceful_retire",
    "zero_demand",
    "unregistered",
)


def classify(t, now, tracker_msg):
    age = now - int(t.get("added_on", 0) or 0)
    progress = float(t.get("progress", 0) or 0)
    downloaded = int(t.get("downloaded", 0) or 0)
    uploaded = int(t.get("uploaded", 0) or 0)
    seed_time = int(t.get("seeding_time", 0) or 0)
    state = t.get("state", "")
    num_complete = int(t.get("num_complete", 0) or 0)

    if tracker_msg and any(k in tracker_msg.lower() for k in UNREG_KEYWORDS):
        return "unregistered"

    if progress < 1.0:
        if age > NEVER_STARTED_AGE and downloaded == 0:
            return "never_started"
        if state == "stalledDL" and age > STALLED_AGE:
            return "stalled_old"
        return None

    if seed_time < HNR_SEED_SECONDS:
        return "hnr_window"

    if seed_time > GRACEFUL_SEED_AGE:
        return "graceful_retire"
    if (
        seed_time >= HNR_SEED_SECONDS
        and uploaded == 0
        and age > ZERO_DEMAND_AGE
    ):
        return "zero_demand"
    if seed_time > SATISFIED_SEED_AGE and num_complete > SATISFIED_SEEDER_FLOOR:
        return "satisfied_redundant"
    return None


def fetch_tracker_msg(hash_):
    try:
        resp = requests.get(
            f"{QB_URL}/api/v2/torrents/trackers",
            params={"hash": hash_},
            timeout=10,
        )
        trackers = resp.json() or []
    except Exception:
        return ""
    for tr in trackers:
        url = tr.get("url", "")
        if url.startswith("** ["):
            continue
        msg = tr.get("msg", "")
        if msg:
            return msg
    return ""


def push(metrics):
    try:
        requests.post(
            f"{PUSHGW}/metrics/job/mam-farming-janitor", data=metrics, timeout=10
        )
    except Exception as e:
        print(f"pushgateway error: {e}", file=sys.stderr)


def main():
    try:
        all_torrents = requests.get(
            f"{QB_URL}/api/v2/torrents/info", timeout=15
        ).json()
    except Exception as e:
        print(f"qBittorrent unreachable: {e}", file=sys.stderr)
        sys.exit(1)

    farming = [t for t in all_torrents if t.get("category") == "mam-farming"]
    now = int(time.time())

    deleted = {r: 0 for r in REASONS}
    preserved_hnr = 0
    skipped_active = 0
    delete_hashes = []

    # Only inspect tracker msg on torrents with a peer problem — avoids
    # hundreds of extra API calls when things are healthy.
    for t in farming:
        state = t.get("state", "")
        progress = float(t.get("progress", 0) or 0)
        tracker_msg = ""
        if progress < 1.0 and state in ("stalledDL", "metaDL", "missingFiles"):
            tracker_msg = fetch_tracker_msg(t["hash"])

        verdict = classify(t, now, tracker_msg)
        if verdict is None:
            skipped_active += 1
        elif verdict == "hnr_window":
            preserved_hnr += 1
        else:
            deleted[verdict] += 1
            delete_hashes.append((t["hash"], verdict, t.get("name", "")[:60]))

    for hash_, reason, name in delete_hashes:
        if DRY_RUN:
            print(f"[DRY_RUN] would delete ({reason}): {name}")
            continue
        try:
            requests.post(
                f"{QB_URL}/api/v2/torrents/delete",
                data={"hashes": hash_, "deleteFiles": "true"},
                timeout=20,
            )
            print(f"Deleted ({reason}): {name}")
        except Exception as e:
            print(f"Delete failed for {name}: {e}", file=sys.stderr)

    for reason in REASONS:
        push(
            f'mam_janitor_deleted_per_run{{reason="{reason}"}} '
            f"{deleted[reason] if not DRY_RUN else 0}\n"
            f'mam_janitor_dry_run_candidates{{reason="{reason}"}} '
            f"{deleted[reason] if DRY_RUN else 0}\n"
        )
    push(
        f"mam_janitor_preserved_hnr {preserved_hnr}\n"
        f"mam_janitor_skipped_active {skipped_active}\n"
        f"mam_janitor_dry_run {1 if DRY_RUN else 0}\n"
        f"mam_janitor_last_run_timestamp {now}\n"
    )

    total = sum(deleted.values())
    print(
        f"Done: deleted={total} preserved_hnr={preserved_hnr} "
        f"skipped_active={skipped_active} dry_run={DRY_RUN}"
    )
    print(f"  per reason: {deleted}")


if __name__ == "__main__":
    main()
