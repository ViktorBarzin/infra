#!/usr/bin/env python3
"""Watch Vault's database static roles and push each rotation to its consumers.

Vault rotates every static role in a Tuesday slot (stacks/vault). The old
password dies at once, and External Secrets only notices on its 15-minute poll,
so an app that opens a new connection in between fails to log in. This script
runs through the rotation hour, reads the role metadata every POLL_SECONDS and,
when a role's last_vault_rotation changes:

  1. force-syncs every ExternalSecret whose remoteRef key is
     static-creds/<role> (Reloader then restarts the app),
  2. waits until that ExternalSecret has refreshed after the rotation,
  3. runs the CronJobs named in its rotation.viktorbarzin.me/after-sync-cronjobs
     annotation, as `kubectl create job --from` would,
  4. pushes db_rotation_sync_lag_seconds and db_rotation_last_seen_timestamp
     per role to the Pushgateway.

It reads database/static-roles/* only, which returns metadata and never a
password. If it fails, the ExternalSecret poll still applies, so the worst case
is the behaviour from before it existed.

Stdlib only. Runbook: docs/runbooks/db-credential-rotation.md.
"""
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime

AFTER_SYNC_ANNOTATION = "rotation.viktorbarzin.me/after-sync-cronjobs"
FORCE_SYNC_ANNOTATION = "force-sync"
# ESO stamps refreshTime in whole seconds; wait this long past the rotation
# before asking for a sync, and require refreshTime to be later than
# rotation + 1s, so a stamp from before the rotation never counts.
SYNC_MARGIN = 1.5
REANNOTATE_SECONDS = 15
SYNC_TIMEOUT_SECONDS = 300
PUSH_JOB = "db-rotation-watcher"

_KEY_RE = re.compile(r"^/?(?:database/)?static-creds/([a-z0-9][a-z0-9-]*)$")
_DNS_LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


def log(msg: str) -> None:
    print(f"{datetime.now().astimezone().isoformat(timespec='seconds')} {msg}", flush=True)


# --- pure functions -----------------------------------------------------------

def role_from_key(key: str | None) -> str | None:
    """The static role an ExternalSecret remoteRef key points at, if any."""
    if not key:
        return None
    m = _KEY_RE.match(key.strip())
    return m.group(1) if m else None


def es_roles(es: dict) -> set[str]:
    spec = es.get("spec") or {}
    keys = [((d.get("remoteRef") or {}).get("key")) for d in (spec.get("data") or [])]
    keys += [((d.get("extract") or {}).get("key")) for d in (spec.get("dataFrom") or [])]
    return {r for r in (role_from_key(k) for k in keys) if r}


def es_key(es: dict) -> str:
    md = es.get("metadata") or {}
    return f"{md.get('namespace')}/{md.get('name')}"


def targets_for_role(items: list[dict], role: str) -> list[dict]:
    return sorted((e for e in items if role in es_roles(e)), key=es_key)


def parse_time(value: str | None) -> float | None:
    """RFC 3339 to epoch seconds. Vault writes nanoseconds, ESO whole seconds."""
    if not value:
        return None
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$", value.strip())
    if not m:
        return None
    base, frac, tz = m.groups()
    try:
        dt = datetime.fromisoformat(base + ("+00:00" if tz == "Z" else tz))
    except ValueError:
        return None
    if dt.year < 1970:  # Vault's zero time for a role that never rotated
        return None
    return dt.timestamp() + (float("0." + frac) if frac else 0.0)


def detect_rotations(prev: dict[str, str], cur: dict[str, str]) -> list[str]:
    """Roles whose last_vault_rotation changed. A role seen for the first time is a baseline."""
    return sorted(r for r, v in cur.items() if r in prev and prev[r] != v)


def recent_rotations(cur: dict[str, str], now: float, within: float) -> list[str]:
    """Roles that rotated in the last `within` seconds, picked up at start so a
    restarted watcher still finishes a rotation its previous pod saw."""
    out = []
    for role, value in cur.items():
        t = parse_time(value)
        if t is not None and 0 <= now - t < within:
            out.append(role)
    return sorted(out)


def synced_after(es: dict, rotated_at: float) -> bool:
    status = es.get("status") or {}
    ready = any(c.get("type") == "Ready" and c.get("status") == "True"
                for c in (status.get("conditions") or []))
    refreshed = parse_time(status.get("refreshTime"))
    return ready and refreshed is not None and refreshed > rotated_at + 1


def after_sync_cronjobs(es: dict) -> list[str]:
    """CronJob names in the ExternalSecret's own namespace to run after it syncs."""
    raw = ((es.get("metadata") or {}).get("annotations") or {}).get(AFTER_SYNC_ANNOTATION, "")
    names = [n for n in re.split(r"[,\s]+", raw) if n]
    return [n for n in names if _DNS_LABEL_RE.match(n) and len(n) <= 52]


def job_name(cronjob: str, rotated_at: float) -> str:
    suffix = f"-rot-{int(rotated_at)}"
    return cronjob[: 63 - len(suffix)].rstrip("-") + suffix


def job_from_cronjob(cronjob: dict, name: str) -> dict:
    """The Job `kubectl create job <name> --from=cronjob/<cronjob>` would create."""
    md = cronjob["metadata"]
    tmpl = cronjob["spec"]["jobTemplate"]
    tmd = tmpl.get("metadata") or {}
    annotations = dict(tmd.get("annotations") or {})
    annotations["cronjob.kubernetes.io/instantiate"] = "manual"
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": name,
            "namespace": md["namespace"],
            "labels": dict(tmd.get("labels") or {}),
            "annotations": annotations,
            "ownerReferences": [{
                "apiVersion": "batch/v1", "kind": "CronJob", "name": md["name"],
                "uid": md["uid"], "controller": True,
            }],
        },
        "spec": tmpl["spec"],
    }


def metrics_text(values: dict[str, float]) -> str:
    out = []
    for name in sorted(values):
        v = values[name]
        text = str(int(v)) if float(v).is_integer() else repr(float(v))
        out.append(f"# TYPE {name} gauge\n{name} {text}\n")
    return "".join(out)


def push_url(base: str, role: str | None) -> str:
    url = f"{base.rstrip('/')}/metrics/job/{PUSH_JOB}"
    return url + (f"/role/{urllib.parse.quote(role, safe='')}" if role else "")


@dataclass
class Rotation:
    role: str
    rotated_at: float
    seen_at: float
    annotated_at: dict[str, float] = field(default_factory=dict)
    synced: dict[str, float] = field(default_factory=dict)

    def should_annotate(self, key: str, now: float) -> bool:
        if key in self.synced or now < self.rotated_at + SYNC_MARGIN:
            return False
        last = self.annotated_at.get(key)
        return last is None or now - last >= REANNOTATE_SECONDS

    def annotated(self, key: str, now: float) -> None:
        self.annotated_at[key] = now

    def lag(self) -> float:
        if self.synced:
            return max(self.synced.values()) - self.rotated_at
        return self.seen_at - self.rotated_at

    def timed_out(self, now: float) -> bool:
        return now - self.seen_at >= SYNC_TIMEOUT_SECONDS


# --- I/O ------------------------------------------------------------------------

def http(method: str, url: str, headers: dict | None = None, body: bytes | None = None,
         ctx: ssl.SSLContext | None = None, timeout: float = 10) -> tuple[int, dict | None]:
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw.strip() else None
        except ValueError:
            return e.code, {"raw": raw[:300].decode(errors="replace")}


SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def sa_token() -> str:
    with open(f"{SA_DIR}/token") as f:
        return f.read().strip()


class Kube:
    def __init__(self) -> None:
        # The address kubelet injects, not kubernetes.default.svc: Kyverno sets
        # ndots:2 (see stacks/phpipam/files/phpipam_import.py).
        self.base = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"
        self.ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")

    def call(self, method: str, path: str, body: dict | None = None,
             content_type: str = "application/json") -> tuple[int, dict | None]:
        headers = {"Authorization": f"Bearer {sa_token()}", "Accept": "application/json"}
        data = None
        if body is not None:
            headers["Content-Type"] = content_type
            data = json.dumps(body).encode()
        return http(method, self.base + path, headers, data, self.ctx)

    def list_externalsecrets(self) -> list[dict]:
        code, body = self.call("GET", "/apis/external-secrets.io/v1/externalsecrets")
        if code != 200:
            raise RuntimeError(f"list externalsecrets: HTTP {code} {body}")
        return body.get("items") or []

    def force_sync(self, ns: str, name: str, now: float) -> None:
        patch = {"metadata": {"annotations": {FORCE_SYNC_ANNOTATION: str(int(now))}}}
        code, body = self.call("PATCH", f"/apis/external-secrets.io/v1/namespaces/{ns}/externalsecrets/{name}",
                               patch, "application/merge-patch+json")
        if code != 200:
            raise RuntimeError(f"force-sync {ns}/{name}: HTTP {code} {body}")

    def run_cronjob(self, ns: str, cronjob: str, name: str) -> str:
        code, cj = self.call("GET", f"/apis/batch/v1/namespaces/{ns}/cronjobs/{cronjob}")
        if code != 200:
            raise RuntimeError(f"get cronjob {ns}/{cronjob}: HTTP {code} {cj}")
        code, body = self.call("POST", f"/apis/batch/v1/namespaces/{ns}/jobs", job_from_cronjob(cj, name))
        if code == 409:
            return "already exists"
        if code != 201:
            raise RuntimeError(f"create job {ns}/{name}: HTTP {code} {body}")
        return "created"


class Vault:
    def __init__(self, addr: str, auth_mount: str, role: str) -> None:
        self.addr, self.auth_mount, self.role = addr.rstrip("/"), auth_mount, role
        self.token = ""

    def login(self) -> None:
        body = json.dumps({"role": self.role, "jwt": sa_token()}).encode()
        code, resp = http("POST", f"{self.addr}/v1/auth/{self.auth_mount}/login",
                          {"Content-Type": "application/json"}, body)
        if code != 200:
            raise RuntimeError(f"vault login: HTTP {code} {resp}")
        self.token = resp["auth"]["client_token"]

    def get(self, path: str) -> dict:
        for attempt in (1, 2):
            code, body = http("GET", f"{self.addr}/v1/{path}", {"X-Vault-Token": self.token})
            if code == 403 and attempt == 1:
                self.login()
                continue
            if code != 200:
                raise RuntimeError(f"vault GET {path}: HTTP {code} {body}")
            return body["data"]
        raise AssertionError("unreachable")

    def static_roles(self) -> dict[str, str]:
        """role -> last_vault_rotation. A role whose read fails is left out this tick."""
        out = {}
        for role in self.get("database/static-roles?list=true").get("keys") or []:
            try:
                out[role] = self.get(f"database/static-roles/{role}").get("last_vault_rotation") or ""
            except RuntimeError as e:
                log(f"WARN read {role}: {e}")
        return out


def push(base: str, role: str | None, values: dict[str, float]) -> None:
    try:
        code, body = http("POST", push_url(base, role), {"Content-Type": "text/plain"},
                          metrics_text(values).encode())
        if code not in (200, 202):
            log(f"WARN pushgateway {role}: HTTP {code} {body}")
    except (urllib.error.URLError, OSError) as e:
        log(f"WARN pushgateway {role}: {e}")


def advance(rot: Rotation, items: list[dict], kube: Kube, pushgw: str, now: float) -> bool:
    """One tick of work on a rotation. True when it is finished."""
    targets = targets_for_role(items, rot.role)
    for es in targets:
        key = es_key(es)
        ns, name = key.split("/", 1)
        if key in rot.synced:
            continue
        if synced_after(es, rot.rotated_at):
            rot.synced[key] = parse_time(es["status"]["refreshTime"])
            log(f"{rot.role}: {key} synced {rot.synced[key] - rot.rotated_at:.0f}s after rotation")
            for cj in after_sync_cronjobs(es):
                try:
                    result = kube.run_cronjob(ns, cj, job_name(cj, rot.rotated_at))
                    log(f"{rot.role}: follow-up job {ns}/{job_name(cj, rot.rotated_at)} {result}")
                except (RuntimeError, urllib.error.URLError, OSError) as e:
                    log(f"ERROR {rot.role}: follow-up {ns}/{cj}: {e}")
        elif rot.should_annotate(key, now):
            try:
                kube.force_sync(ns, name, now)
                rot.annotated(key, now)
                log(f"{rot.role}: force-sync {key}")
            except (RuntimeError, urllib.error.URLError, OSError) as e:
                log(f"ERROR {rot.role}: {e}")
    if len(rot.synced) == len(targets):
        if not targets:
            log(f"{rot.role}: no ExternalSecret references it")
        push(pushgw, rot.role, {"db_rotation_sync_lag_seconds": round(rot.lag(), 3),
                                "db_rotation_last_seen_timestamp": round(rot.seen_at)})
        log(f"{rot.role}: done, lag {rot.lag():.1f}s")
        return True
    if rot.timed_out(now):
        missing = sorted(es_key(e) for e in targets if es_key(e) not in rot.synced)
        log(f"ERROR {rot.role}: not synced after {SYNC_TIMEOUT_SECONDS}s: {', '.join(missing)}")
        push(pushgw, rot.role, {"db_rotation_sync_lag_seconds": round(now - rot.rotated_at, 3),
                                "db_rotation_last_seen_timestamp": round(rot.seen_at)})
        return True
    return False


def main() -> int:
    poll = float(os.environ.get("POLL_SECONDS", "5"))
    run_seconds = float(os.environ.get("RUN_SECONDS", "3900"))
    pushgw = os.environ.get("PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091")
    vault = Vault(os.environ.get("VAULT_ADDR", "http://vault-active.vault.svc.cluster.local:8200"),
                  os.environ.get("VAULT_AUTH_MOUNT", "kubernetes"),
                  os.environ.get("VAULT_ROLE", "db-rotation-watcher"))
    kube = Kube()
    vault.login()

    start = time.time()
    deadline = start + run_seconds
    prev = vault.static_roles()
    active: dict[str, Rotation] = {}
    for role in recent_rotations(prev, start, SYNC_TIMEOUT_SECONDS):
        active[role] = Rotation(role, parse_time(prev[role]), start)
        log(f"{role}: rotated {start - active[role].rotated_at:.0f}s before start, finishing it")
    push(pushgw, None, {"db_rotation_watcher_last_start_timestamp": round(start)})
    log(f"watching {len(prev)} roles every {poll:g}s for {run_seconds:g}s")

    while time.time() < deadline:
        tick = time.time()
        try:
            cur = vault.static_roles()
        except (RuntimeError, urllib.error.URLError, OSError) as e:
            log(f"WARN vault: {e}")
            cur = {}
        now = time.time()
        for role in detect_rotations(prev, cur):
            rotated_at = parse_time(cur[role]) or now
            active[role] = Rotation(role, rotated_at, now)
            log(f"{role}: rotated at {cur[role]}, seen {now - rotated_at:.1f}s later")
        prev.update(cur)

        if active:
            try:
                items = kube.list_externalsecrets()
            except (RuntimeError, urllib.error.URLError, OSError) as e:
                log(f"WARN {e}")
                items = None
            if items is not None:
                for role, rot in list(active.items()):
                    if advance(rot, items, kube, pushgw, time.time()):
                        del active[role]
        time.sleep(max(0.0, tick + poll - time.time()))

    for role, rot in active.items():
        log(f"ERROR {role}: run ended before its ExternalSecrets synced")
        push(pushgw, role, {"db_rotation_sync_lag_seconds": round(time.time() - rot.rotated_at, 3),
                            "db_rotation_last_seen_timestamp": round(rot.seen_at)})
    log("run finished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
