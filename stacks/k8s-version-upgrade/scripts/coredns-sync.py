#!/usr/bin/env python3
"""Move CoreDNS to the version kubeadm ships for a Kubernetes release.

Called by upgrade-step.sh (postflight) after every node is on the target
release. CoreDNS is kubeadm-created but kubeadm's own addon phase is skipped
(scripts/update_k8s.sh): it would replace the custom Corefile that the
technitium stack owns. So the chain only sets the image, and only forward.

  coredns-sync.py --kubeadm-image registry.k8s.io/coredns/coredns:v1.13.1
  kubeadm config images list --kubernetes-version vX.Y.Z | coredns-sync.py --images-list -

Steps: DNS check against every CoreDNS pod; if the live tag is older than
kubeadm's, `kubectl set image`, wait for the rollout, DNS check again. A failed
rollout or check is rolled back with `kubectl rollout undo`.

The last stdout line is `result=<r> live=<image> kubeadm=<image>`, where r is
one of unchanged, newer, unknown, upgraded, rolled-back, dns-broken-before,
rollback-failed. Exit 0 for the first four, 1 otherwise.
"""
import argparse
import json
import random
import re
import socket
import struct
import subprocess
import sys
import time

NS = "kube-system"
DEPLOY = "coredns"
CONTAINER = "coredns"
POD_SELECTOR = "k8s-app=kube-dns"
CHECK_NAME = "kubernetes.default.svc.cluster.local"
ROLLOUT_TIMEOUT = "300s"

_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


def _tag(image: str):
    """Version tuple from an image reference, or None if the tag is not X.Y.Z."""
    ref = image.split("@", 1)[0]
    last = ref.rsplit("/", 1)[-1]
    if ":" not in last:
        return None
    m = _TAG.match(last.rsplit(":", 1)[1])
    return tuple(int(x) for x in m.groups()) if m else None


def decide(live: str, kubeadm: str) -> str:
    """upgrade | unchanged | newer | unknown. Never proposes a downgrade."""
    have, want = _tag(live), _tag(kubeadm)
    if have is None or want is None:
        return "unknown"
    if have < want:
        return "upgrade"
    return "unchanged" if have == want else "newer"


def coredns_from_images_list(listing: str) -> str:
    for line in listing.splitlines():
        line = line.strip()
        if line.split("@")[0].rsplit("/", 1)[-1].startswith("coredns:"):
            return line
    raise ValueError("no coredns image in kubeadm's images list")


def build_query(name: str, qid: int) -> bytes:
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    labels = b"".join(bytes([len(p)]) + p.encode() for p in name.split("."))
    return header + labels + b"\x00" + struct.pack(">HH", 1, 1)


def parse_answer(query: bytes, reply: bytes) -> bool:
    """True when the reply answers this query with NOERROR and >=1 record."""
    if len(reply) < 12:
        return False
    rid, flags, _, ancount = struct.unpack(">HHHH", reply[:8])
    return rid == struct.unpack(">H", query[:2])[0] and flags & 0xF == 0 and ancount > 0


def resolves(ip: str, tries: int = 3) -> bool:
    for _ in range(tries):
        q = build_query(CHECK_NAME, random.randint(0, 0xFFFF))
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.settimeout(2)
                s.sendto(q, (ip, 53))
                if parse_answer(q, s.recvfrom(4096)[0]):
                    return True
        except OSError:
            pass
        time.sleep(1)
    return False


def kubectl(kc: str, *args: str) -> str:
    return subprocess.run([kc, *args], check=True, capture_output=True, text=True).stdout


def live_image(kc: str) -> str:
    return kubectl(kc, "-n", NS, "get", "deploy", DEPLOY, "-o",
                   f"jsonpath={{.spec.template.spec.containers[?(@.name==\"{CONTAINER}\")].image}}").strip()


def dns_ok(kc: str) -> tuple[bool, str]:
    """Query every Ready CoreDNS pod directly, so nodelocal-dns caching cannot hide a broken one."""
    pods = json.loads(kubectl(kc, "-n", NS, "get", "pods", "-l", POD_SELECTOR, "-o", "json"))["items"]
    ips = [p["status"].get("podIP") for p in pods
           if p.get("metadata", {}).get("deletionTimestamp") is None
           and any(c["type"] == "Ready" and c["status"] == "True"
                   for c in p["status"].get("conditions", []))]
    ips = [ip for ip in ips if ip]
    if not ips:
        return False, "no Ready CoreDNS pods"
    bad = [ip for ip in ips if not resolves(ip)]
    return not bad, f"{len(ips) - len(bad)}/{len(ips)} pods resolve {CHECK_NAME}" + (f", failing: {bad}" if bad else "")


def rollout_ok(kc: str) -> bool:
    try:
        kubectl(kc, "-n", NS, "rollout", "status", f"deploy/{DEPLOY}", f"--timeout={ROLLOUT_TIMEOUT}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"rollout status failed: {e.stderr.strip()}")
        return False


def sync(kc: str, kubeadm_image: str, dry_run: bool) -> str:
    live = live_image(kc)
    verdict = decide(live, kubeadm_image)
    print(f"CoreDNS live={live} kubeadm={kubeadm_image} decision={verdict}")
    if verdict != "upgrade":
        return verdict
    ok, detail = dns_ok(kc)
    print(f"DNS before: {detail}")
    if not ok:
        return "dns-broken-before"
    if dry_run:
        print("dry run: not changing the image")
        return "unchanged"
    kubectl(kc, "-n", NS, "set", "image", f"deploy/{DEPLOY}", f"{CONTAINER}={kubeadm_image}")
    if rollout_ok(kc):
        ok, detail = dns_ok(kc)
        print(f"DNS after: {detail}")
        if ok:
            return "upgraded"
    print("rolling back")
    kubectl(kc, "-n", NS, "rollout", "undo", f"deploy/{DEPLOY}")
    if rollout_ok(kc) and dns_ok(kc)[0]:
        return "rolled-back"
    return "rollback-failed"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--kubeadm-image")
    src.add_argument("--images-list", type=argparse.FileType("r"),
                     help="output of `kubeadm config images list` ('-' for stdin)")
    ap.add_argument("--kubectl", default="kubectl")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    want = a.kubeadm_image or coredns_from_images_list(a.images_list.read())
    result = sync(a.kubectl, want, a.dry_run)
    print(f"result={result} live={live_image(a.kubectl)} kubeadm={want}")
    return 0 if result in ("unchanged", "newer", "unknown", "upgraded") else 1


if __name__ == "__main__":
    sys.exit(main())
