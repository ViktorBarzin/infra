# ADR-0030: The automated repairer and the notification path sit outside the failure domain they serve

Date: 2026-09-08
Status: Proposed

## Context

On 2026-09-01 every one of 196 Ingresses refused connections for 169 minutes.
Detection worked. gatus on mx2, the offsite vantage ADR-0020 established for
exactly this, posted to Slack at 07:49:01Z, 2 minutes 42 seconds after the
break, with no send error. Five alert families fired 18 series, 14 of them
critical, by 07:52. The first human word arrived at 10:33:13Z. The repair then
took 3 minutes 12 seconds.

So the shape of the longest outage in the window is 2m42s of detection and
164m12s of nobody responding. That reorders every detection candidate in this
study, because a control that adds another red line to a stream nobody is
reading is not obviously positive: 17 to 26 alerts are firing at any given
sample right now, three to four of them critical.

Three measured contributors to the silence:

1. **The fixer agent could not run.** All 85 of its ticks over the window failed.
   `ntfy.viktorbarzin.me` and `claude-memory.viktorbarzin.me` both resolve to
   the MetalLB VIP `10.0.20.203` and both Ingresses are Cloudflare-proxied, so
   the agent's only channel to a human and its memory store were both behind the
   broken path. Note the Forgejo literals are already fine: CoreDNS pins
   `forgejo.viktorbarzin.me` to Traefik's ClusterIP in a hosts block, so that
   traffic never leaves the cluster.
2. **An autonomous subagent had the diagnosis 26 minutes early and dropped it.**
   At 10:07:06 it confirmed 443 REFUSED on the LB VIP and three hosts returning
   000, concluded "this is the devvm's path to the LB, not an outage", and
   returned a structured result about its assigned task that never mentioned the
   outage.
3. **The incident partly erased its own record.** The Claude session stream lost
   3h20m, the devvm journal lost 2h34m outright, and both CLI verbs the rules
   tell an agent to reach for first returned connection refused, because the
   telemetry ingest paths also ride the ingress they observe.

Nothing currently routes Alertmanager or gatus into the fixer agent. It
dispatches from a Forgejo issue labelled `broken`, which needs a human to notice
first, and filing that issue goes through the same Traefik.

One control did cover this and it is worth preserving. `CronJobFailingRepeatedly`
(shipped 2026-09-03) replayed over the window is continuously true for 188
minutes against a `for: 2h`, so on the next repeat it pages roughly 68 minutes
before the outage ends. Because functional probe coverage is 5 of 188 workloads,
the fixer tick is accidentally one of the few end-to-end probes in the estate,
running every 2 minutes over the whole Traefik-to-Forgejo chain.

## Decision

Treat response, not detection, as the binding constraint, and build the actor
path in this order. Each step is a prerequisite for the next.

1. **Move the fixer's outbound paths off the VIP.** Two `ntfy` and two
   `claude-memory` URL literals in `stacks/claude-agent-service/main.tf`. Leave
   the Forgejo API and clone literals where they are. Keep `FIXER_FORGEJO_WEB`
   on the public hostname, because it only builds human-facing links and an
   in-cluster URL there resolves from no phone.
2. **Replace the probe before silencing it.** Add a fixer-tick rule beside
   `CronJobFailingRepeatedly` at `for: 10m`, severity critical, so five missed
   ticks page. Roughly 8 lines in one `.tpl`.
3. **Escalate a total-outage critical by duration**, gated on an explicit
   `escalate=page` label on a handful of rules, with a named owner for the label
   list, and a second notification destination not served through Traefik.
4. **Only then**, dispatch a `broken` issue automatically on a total-outage
   critical, bound to an explicit allowlist of alertnames, with a dedupe key and
   an hourly cap.

Do not start at step 4.

## Alternatives

- **Add more detectors instead.** Rejected on the measurement above: the page
  existed and was correct. Widening probe coverage from 27 targets to 157 buys
  nothing on this incident, and `IngressAllTargetsUnreachable` already covers the
  class at `for: 2m`.
- **Move all of the fixer's Forgejo URLs in-cluster**, as originally proposed.
  Rejected: `forgejo.viktorbarzin.me` already resolves to Traefik's ClusterIP, so
  the change removes Traefik and six middlewares and nothing else. It also
  deletes the fixer tick's value as a functional probe, which is a net loss until
  step 2 exists.
- **Human on-call rota.** Out of scope for a one-person homelab, and the recorded
  evidence is that the human response was 3 minutes long once it started. The gap
  is the trigger, not the responder's speed.
- **Let the fixer act on any firing critical.** Rejected as the single highest
  risk in this study. A fix-forward agent acting on a wrong diagnosis mid-outage
  is a worse failure than a slow human, and the 2026-09-01 subagent transcript
  shows a confident wrong diagnosis is a realistic outcome.

## Consequences

**Positive**
- The one automated repairer in the estate stops being inside the failure domain
  it would be asked to repair.
- Steps 1 to 3 are independently useful and independently reversible. Nothing in
  them can act on production state.
- The 164-minute term becomes measurable: a synthetic critical held for 20
  minutes either produces a second notification on a non-Traefik path or it does
  not.

**Negative**
- Step 3 is the candidate most likely to make things worse if scoped loosely.
  The repo already moved warnings to an 8760h `repeat_interval` for exactly this
  reason. The `escalate=page` allowlist must be small, owned and reviewed, and
  the current firing-alert floor should be cleared before it is enabled.
- Step 4 gives an agent a trigger it does not have today. The allowlist, the
  dedupe key and the hourly cap are not optional, and the fixer drill should be
  on a schedule before it ships.
- Moving the telemetry ingest paths off the ingress is a larger separate piece
  of work. Each of the three surfaces needs its own dead-man signal before the
  path moves, not after, or a silent stream looks identical to a healthy one.
