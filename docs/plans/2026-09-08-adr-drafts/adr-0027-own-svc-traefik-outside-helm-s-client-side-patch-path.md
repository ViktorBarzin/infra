# ADR-0027: Own `svc/traefik` outside helm's client-side patch path

Date: 2026-09-08
Status: Proposed

## Context

`Service.spec.ports` carries `x-kubernetes-patch-merge-key: port` and
`x-kubernetes-patch-strategy: merge`, so a client-side strategic merge keys the
port list on the port number alone. `svc/traefik` declares `websecure` at
443/TCP with `targetPort: websecure` and `websecure-http3` at 443/UDP with
`targetPort: 8443`. The two entries fold into one and the UDP entry's
`targetPort` wins.

The consequence is measured, three times in nine days:

| helm revision | date | probes down |
|---|---|---|
| 72 | 2026-08-31 | 3 min (11:19 to 11:22) |
| 75 | 2026-09-01 | **169 min** (07:47 to 10:36), all 196 Ingresses |
| 76 | 2026-09-03 | 1 min (04:56 to 04:57) |

The chart is pinned at `40.2.0` and `atomic = true` is set, so neither pinning
nor helm's own rollback prevented it: the chart rendered the Service correctly
every time and the fold happened at apply. Helm's readiness gate for a Service
checks ClusterIP presence and LoadBalancer ingress, and MetalLB kept the IP
throughout, so the release reported success. Traefik's pods stayed Ready, so
`TraefikDown` could not fire, and the nightly `terragrunt plan` cannot see it
either, because a `helm_release` plan compares chart version and values rather
than rendered objects.

The collision is still armed. Verified 2026-09-08 04:52 UTC:

```
$ helm get manifest traefik -n traefik > t.yaml && kubectl diff -f t.yaml
     nodePort: 30703
     port: 443
     protocol: TCP
-    targetPort: websecure
+    targetPort: websecure-http3
```

One hunk, one field, on the Service carrying 194 of 196 Ingresses.

Server-side apply keys the same list on `["port", "protocol"]`, confirmed from
this cluster's own OpenAPI v3 schema, and `kubectl diff --server-side` against
the same manifest returns a named Conflict rather than folding the entry. But
helm 3.13.1 and the terraform helm provider have no server-side apply path
(SSA landed in helm 4), and the live Service's `managedFields` show
`terraform-provider-helm_v3.1.1_x5` with operation `Update`. So SSA is not
reachable while the object is rendered by the chart.

Ten other Services in the estate carry two entries on the same port number, and
all ten are harmless: they are written by the typed Terraform provider, which
sends a whole object, and in every case both entries share a `targetPort`.
`svc/traefik` is the only asymmetric one, and it is the one with the largest
blast radius in the cluster.

## Decision

Take TCP/443 and UDP/443 off the same merge key, so the fault becomes
impossible rather than fast to find. Either is acceptable and the choice is an
implementation detail:

- **(a)** Give HTTP/3 its own Service, or drop the QUIC entrypoint from the
  chart's Service and advertise `alt-svc` at the Cloudflare edge. The chart's
  own comment at `main.tf:255` already contemplates moving HTTP/3.
- **(b)** Declare the Service as a `kubernetes_manifest` with a `field_manager`
  and `force_conflicts = false`, so the apiserver keys on `(port, protocol)` and
  any future collision surfaces as an error at apply.

Land ADR-0028's post-apply readback for this Service first. A change to this
entrypoint has already taken HTTPS down once, and the readback is the thing that
reports it inside the same shell.

## Alternatives

- **Keep pinning and rely on `atomic`.** Rejected on measurement: revisions 72,
  75 and 76 were all applies of the pinned chart with `atomic = true`, and all
  three reached `deployed`.
- **Detect it faster and leave the fault in place.** `IngressAllTargetsUnreachable`
  already does this well, at `for: 2m`, backtested in its own rule comment over
  9,929 samples with zero isolated false positives. It is the right control and
  it is deployed. It reduces a 169-minute outage to roughly 3 minutes; it does
  not reduce it to zero, and it deliberately declines 1-minute episodes because
  at 1-minute scrape resolution one bad probe round is indistinguishable.
- **Move the whole helm estate to Flux's HelmRelease with `driftDetection`.**
  Flags this every reconcile interval, but corrects it via `helm upgrade`, which
  re-collides. Also two new controllers and a JSON-pointer ignore entry per
  Kyverno-stamped field, on an etcd already firing both of its own latency
  alerts.
- **Wait for helm 4 and server-side apply.** Correct in the long run and not a
  plan: the fault is armed now.

## Consequences

**Positive**
- Removes a fault with three recorded firings, rather than adding a detector for
  it. The only candidate in this study that does.
- The recovery patch stops being load-bearing. Today recovery needs a
  hand-written `kubectl patch --type=json`, because `port` is the merge key and a
  normal apply cannot address the entry.
- `helm get manifest | kubectl diff -f -` returning empty becomes a check anyone
  can run, and a re-run baseline.

**Negative**
- Option (a) touches the static entrypoint configuration of the ingress for the
  whole estate. That is the same surface that produced the incident, so it needs
  the readback in place and a low-traffic window.
- Option (b) moves one object out of the chart, so a chart upgrade that changes
  the Service shape needs the manifest updated by hand. This is a small
  duplication and it should be written down next to the resource.
- Neither option addresses the other ten same-port Services. They are safe today
  by accident rather than by design, so a lint asserting that same-port entries
  share a `targetPort` is a reasonable follow-up.
