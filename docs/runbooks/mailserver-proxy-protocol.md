# Mailserver PROXY protocol — research & decision

Last updated: 2026-04-18

## TL;DR

**MetalLB does not and will not inject PROXY protocol headers.** The original plan
(`/home/wizard/.claude/plans/let-s-work-on-linking-temporal-valiant.md`, task
`code-rtb`) assumed MetalLB could be configured to emit PROXY v1/v2 on behalf of
the `mailserver` LoadBalancer Service. That assumption is wrong at the product
level. MetalLB is a control-plane-only announcer (ARP/NDP for L2 mode, BGP for
L3 mode); it never touches the L4 payload.

As a result, there is no single Terraform change that can flip
`externalTrafficPolicy: Local` → `Cluster` on the `mailserver` Service while
preserving the real client IP for Postfix/postscreen and Dovecot. Three
alternative paths exist (see below); none is trivial.

## Environment (verified 2026-04-18)

- **MetalLB version**: `quay.io/metallb/controller:v0.15.3` /
  `quay.io/metallb/speaker:v0.15.3` (5 speakers).
- **Advertisement type**: L2Advertisement `default` bound to IPAddressPool
  `default` (10.0.20.200–10.0.20.220). No BGPAdvertisements.
- **Service**: `mailserver/mailserver` — type `LoadBalancer`, `loadBalancerIPs:
  10.0.20.202`, `externalTrafficPolicy: Local`,
  `healthCheckNodePort: 30234`, 5 ports (25, 465, 587, 993, 9166/dovecot-metrics).
- **Pod**: single replica today, RWO PVCs prevent horizontal scale without
  further work (`mailserver-data-encrypted`, `mailserver-letsencrypt-encrypted`).

## Why the original plan fails

### MetalLB never touches packets

> *"MetalLB is controlplane only, making it part of the dataplane means we
> would be responsible for the performance of the system, so more bugs to
> fight, I personally don't see that happening."*
> — MetalLB maintainer `champtar`, 2021-01-06
> (issue [#797 — Feature Request: Supporting Proxy Protocol v2](https://github.com/metallb/metallb/issues/797))

Issue #797 is closed as "won't implement". Repeat asks in 2022–2023 got the
same answer. The v0.15.3 API surface confirms this: no
`proxyProtocol`/`haproxy`/`protocol: proxy` field exists on `IPAddressPool`,
`L2Advertisement`, `BGPAdvertisement`, or as a Service annotation.

Only managed-cloud LBs (AWS NLB, Azure LB, OCI, DO, OVH, Scaleway, etc.) offer
PROXY protocol as a tick-box. MetalLB's equivalents are:

| MetalLB feature | Does it preserve client IP? | Comment |
|---|---|---|
| `externalTrafficPolicy: Local` (current) | Yes, via iptables DNAT on the speaker node | Forces pod↔speaker colocation on L2 mode. This is the pain we wanted to avoid. |
| `externalTrafficPolicy: Cluster` | No — kube-proxy SNATs to the node IP | The problem we would re-introduce if we flipped without PROXY injection. |
| PROXY protocol injection | N/A — not implemented | Dead end. |

### The `Local` trap is real, but narrower than it seems

Today's `Local` policy means the ARP announcer node must also host the mailserver
pod. MetalLB always picks a single speaker to advertise the VIP (leader
election per IP), so in practice exactly one node matters at any moment. A pod
rescheduled to a different node silently drops inbound SMTP/IMAP until a GARP
flip or node cordon.

The only pods on our cluster that see this same class of risk are Traefik
(3 replicas + PDB `minAvailable=2`, so 2 of 3 nodes always have a pod) and
mailserver (1 replica). Traefik survives because the pods outnumber the nodes
that could be the speaker at once; the mailserver cannot.

## Alternative paths (ranked by effort)

### Option A — Pin the mailserver pod to a specific node (SIMPLEST)

Add `nodeSelector` on the mailserver Deployment pointing at a label that's also
stamped on the MetalLB speaker we want to advertise the VIP from, and use
MetalLB's [node selector](https://metallb.io/configuration/_advanced_l2_configuration/#specify-network-interfaces-that-lb-ip-can-be-announced-from)
on `L2Advertisement.spec.nodeSelectors` to pin the announcer to the same node.

Trade-offs:

- Zero changes to Postfix/Dovecot configs.
- Keeps `externalTrafficPolicy: Local` — real client IP keeps arriving.
- Loses HA (the whole point of the MetalLB layer) but reflects reality — one
  replica, one PVC, no HA today anyway.
- Drain of that node requires a planned cutover, but that's no worse than
  today's silent failure mode.

Implementation (~10 lines of Terraform):

```hcl
# In stacks/mailserver/modules/mailserver/main.tf, on the Deployment:
node_selector = { "viktorbarzin.me/mailserver-anchor" = "true" }

# In stacks/platform (or wherever the MetalLB CRs live):
resource "kubernetes_manifest" "mailserver_l2ad" {
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata   = { name = "mailserver", namespace = "metallb-system" }
    spec = {
      ipAddressPools = ["default"]
      nodeSelectors  = [{ matchLabels = { "viktorbarzin.me/mailserver-anchor" = "true" } }]
    }
  }
}
```

Plus a node label via `kubectl label node k8s-node3 viktorbarzin.me/mailserver-anchor=true`.

**Recommendation: this is the shortest path to eliminating the silent-drop
failure mode** without taking on a new proxy tier.

### Option B — Put a HAProxy sidecar in front of Postfix/Dovecot

Stand up an in-cluster HAProxy with PROXY v2 enabled on the frontend and
`send-proxy-v2` on the backend to `mailserver:25/465/587/993`. Expose HAProxy
via a new MetalLB Service with `externalTrafficPolicy: Cluster` + kube-proxy
DSR workaround (still loses client IP at that layer), or run HAProxy on the
host-network of the same node (back to Option A's colocation).

Trade-offs:

- Introduces one more network hop and TLS-termination decision for every
  SMTP connect.
- HAProxy needs its own cert rotation (or `tls-passthrough`) — adds moving
  parts to an already crowded mailserver module.
- Doesn't actually solve the colocation problem on its own — HAProxy itself
  needs to receive the client IP, so we are back to externalTrafficPolicy
  constraints for HAProxy.

**Recommendation: avoid unless we also get HA for mailserver itself, which
needs RWX storage + DB split-brain work — out of scope.**

### Option C — Replace MetalLB with a different LB for this Service

Candidates: [kube-vip](https://kube-vip.io/) (supports eBPF-based DSR but not
PROXY injection either), [Cilium LB](https://docs.cilium.io/en/stable/network/lb-ipam/)
(preserves client IP via DSR in hybrid mode), or a dedicated HAProxy running on
pfSense and NAT-forwarding 25/465/587/993 with PROXY headers to a
ClusterIP-exposed mailserver. Cilium requires a CNI migration (we run Calico
today); pfSense HAProxy is genuinely feasible but belongs in a different bd
task.

**Recommendation: track as P3 follow-up under a new bd task if Option A proves
insufficient.**

## Decision

Do nothing in this session beyond this runbook + the bd note. The `code-rtb`
task as written is not executable — MetalLB cannot inject PROXY headers, and
the Postfix/Dovecot config changes the plan proposed would not receive the
header they expect, they would hang waiting for it and then timeout (5s per
connection).

Follow-up work filed as bd child tasks (if user wants to pursue):

- **Option A — pin mailserver + L2Advertisement nodeSelectors** (new bd task)
- **Option C — HAProxy on pfSense with PROXY v2 to a ClusterIP** (new bd task)

## References

- [MetalLB issue #797 — Feature Request: Supporting Proxy Protocol v2](https://github.com/metallb/metallb/issues/797) (closed, won't implement)
- [MetalLB PR #796 — Source IP Preservation discussion](https://github.com/metallb/metallb/issues/796)
- Postfix [postscreen_upstream_proxy_protocol](https://www.postfix.org/postconf.5.html#postscreen_upstream_proxy_protocol) — expects the PROXY header *on every incoming connection*; if absent, postscreen drops after `postscreen_upstream_proxy_timeout`.
- Dovecot [haproxy_trusted_networks](https://doc.dovecot.org/settings/core/#core_setting-haproxy_trusted_networks) — treats the header as mandatory for listed source networks.
- Cluster state verified against: `kubectl -n metallb-system get pods`,
  `kubectl get ipaddresspools.metallb.io -A`,
  `kubectl get l2advertisements.metallb.io -A`,
  `kubectl get bgpadvertisements.metallb.io -A`,
  `kubectl -n mailserver get svc mailserver -o yaml`.
