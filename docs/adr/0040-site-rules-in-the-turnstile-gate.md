# ADR-0040: Site rules in the Turnstile gate, starting with Forgejo's cold filter open

- Status: accepted
- Date: 2026-11-09
- Related: `stacks/turnstile-gate/files/{gate.py,forgejo_rules.py}`, `docs/plans/2026-10-16-turnstile-sitewide-design.md`, `docs/runbooks/forgejo-crawl.md`, alerts `ForgejoFilterCrawlReachingBackend` and `ForgejoExternalClientSurge` (`stacks/monitoring/modules/monitoring/loki.tf`)

## Context

From 2026-11-01 a crawler walked the issue and pull request filter combinations of `viktor/infra` on Forgejo: every combination of labels, milestone, project, assignee and poster, an effectively unbounded set of URLs. It ran a real browser on a residential and hosting proxy pool and used each IP for one page. On 2026-11-08 the median crawler IP lived 16 s and made 11 requests, and 1 of 1,113 fetched a second filter page.

The Turnstile gate and Anubis slowed it but did not stop it. Turnstile scores browser and network signals rather than presenting a puzzle, and a scripted Chrome on a home-ISP address passes some of the time: on 2026-11-08 it submitted 220 accepted and 256 rejected tokens in 12 h. When Turnstile did not complete, the page's fallback sent it to Anubis, whose proof of work it solved in about 3 s. The pass and fallback cookies are bound to the client's network, which works as designed and has no effect on a client that never returns. Banning addresses has nothing to act on for the same reason.

Two personas shared the work, both opening a filtered list as the first request from a fresh IP:

| | Persona A | Persona B |
|---|---|---|
| User agent | Linux Chrome/157 | Mac Chrome/142 |
| Referer | `https://www.google.com/` on every request | none |
| IPs on 2026-11-08 | 2,830 | 2,976 |
| Outcome | about 1 visit in 4 got a real page (1,526 pages) | stopped at the challenge |

No outside visitor opened a filtered list without arriving from a Forgejo page that day.

Forgejo cannot help on its own side: `[service] REQUIRE_SIGNIN_VIEW` is all or nothing, and the requirement is that anyone can keep reading the code, issues and pull requests.

## Decision

1. **The gate gains site rules**: refusals that use one site's own URL knowledge and run before any challenge. A site opts in through its middleware (`/auth?variant=strict&site=<name>`, set by `ingress_factory`'s `turnstile_site`). A site that does not opt in is never affected, and the gate never infers a site from the hostname.
2. **Each site's rules live in their own module.** Forgejo's are in `forgejo_rules.py`, with their own tests. `gate.py` holds only the registry (`SITE_RULES`) and the point in `decide()` where rules run.
3. **The first rule is Forgejo's cold filter open.** A request for `/<owner>/<repo>/issues` or `/pulls` with a filter set (labels non-empty, or milestone, project, assignee or poster other than `""` or `0`) whose Referer is not one of our sites is refused with a 403 page. The page links to the unfiltered list and back to the same view; either click carries our Referer and continues to the normal check.
4. **Where the rule runs.** After a valid pass cookie, the global `open` switch, non-GET methods and trusted networks, and before the fallback cookie and every user-agent and Accept shortcut. It stays on under the global `anubis` switch, because it does not depend on Turnstile.
5. **"Our sites" means any host under the gate's domain**, not Forgejo alone. A visitor who clicks a filter, takes the Anubis fallback and passes returns with an `anubis.viktorbarzin.me` Referer, and must not be refused at that point.
6. **Refusals are logged as `event: refused`** with `reason: forgejo-cold-filter`, separately from challenges.

## Why this is Forgejo-specific, and what it rests on

The rule depends on two facts about Forgejo, checked against Forgejo 17 on 2026-11-09:

- Forgejo renders every list link with the filters at their defaults, so a person reaches a filtered list only by choosing a filter on a Forgejo page.
- Forgejo pages carry `<meta name="referrer" content="same-origin">`, so that click always sends a Forgejo Referer.

If a Forgejo upgrade changes either, the rule either refuses people (a stricter referrer policy) or stops matching (renamed parameters). The tests in `test_forgejo_rules.py` pin both assumptions, and an upgrade should re-check them against a live page.

## Consequences

- Replayed against 2026-11-08, every one of persona A's 1,526 served pages would have been refused at its first request. Persona B was already stopped and stays stopped.
- A person who opens a filtered link pasted from outside our sites, with no pass cookie, sees the refusal page and is one click from the view. Visitors holding a pass cookie, and the home network and tailnet, are not affected.
- The rule is evaded by sending one of our hostnames as the Referer. A crawler that does that is back to solving Turnstile or Anubis on every page, as before this change, and `ForgejoFilterCrawlReachingBackend` reports it.
- The gate now carries site knowledge. Keeping it in per-site modules behind an explicit opt-in is what stops that knowledge spreading into the shared path.

## Retiring it

Remove the rule when the refusal count (`{namespace="turnstile-gate",container="gate"} |= "\"event\": \"refused\""`) has been zero for 30 days, or when Forgejo gains a way to restrict filtered views to signed-in users.

## Open questions

- Whether the crawler adapts by forging an internal Referer, and how quickly.
- Whether other Forgejo views with unbounded query combinations (commit graphs with filters, code search) deserve the same treatment. None was crawled this way at the time of writing.
