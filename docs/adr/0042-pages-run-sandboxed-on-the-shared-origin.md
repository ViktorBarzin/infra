# ADR-0042: Pages run in a CSP sandbox on the shared origin, and public access is by unguessable link

- Status: accepted
- Date: 2026-11-12
- Related: `docs/plans/2026-11-12-pages-rich-content-design.md` (the design), `stacks/learn` (Caddy, the shell, the ingresses), `stacks/pages-publish` (`app/bundles.py`), ADR-0031 (per-host forward auth), ADR-0041 (Rybbit)

## Context

pages.viktorbarzin.me is now where agents on the devvm publish visual and interactive work: three.js viewers, slide decks, charts. That means scripts written by any user's agent, and libraries pulled from CDNs, run on the site. Every Space (`wizard/`, `emo/`, `shared/`, ...) is served from one origin, `https://pages.viktorbarzin.me`, behind one Authentik forward-auth cookie. A script on one page could therefore `fetch` any other Space with the reader's cookie and read it.

The usual answer is a separate content origin per Space (the githubusercontent pattern). Here that means one host and one Authentik application per Space, with a Caddy routing table for each, and a second public host for links. Viktor chose to keep one host.

Measured on 2026-11-12 (the design doc has the evidence):

- A document with an opaque origin sends no SameSite=Lax cookie on any of its own subresource requests, even to its own host. Its navigation does carry the cookie, including an iframe navigation made by an unsandboxed parent.
- Traefik's shared `csp-headers` middleware replaces whatever CSP a backend sends.
- The Rybbit script throws on its first `localStorage` read inside a sandbox, and Rybbit's API refuses `Origin: null`.

## Decision

1. **Every page is served under a CSP `sandbox` without `allow-same-origin`.** Page scripts run with an opaque origin: no cookies, no storage, and a `fetch` of another Space carries no cookie and gets the login redirect.
2. **A browser navigation gets a shell; the page loads in a frame on the same URL.** Caddy serves the shell (a fixed file from the learn ConfigMap, never from git) when `Sec-Fetch-Dest` is `document`, and the page from git, with the sandbox header, for every other request. The shell is the only document that runs as the real origin. It carries Rybbit, sets the title, and finds a Bundle's Bundle URL. `?raw` and `?print-pdf` skip it for printing.
3. **A multi-file Bundle is also served at an unguessable Bundle URL, `/c/<128-bit cap>/`,** because its relative files load inside the sandbox without the sign-in cookie. The cap rotates on every publish. Single-file pages have no Bundle URL and stay strictly behind Authentik.
4. **Public access is an unguessable link on the same host, `/p/<128-bit token>/`,** with no Authentik and no Turnstile, noindex and the anti-AI headers, and the same shell and sandbox. A link lives until it is revoked, and the page stays in its Space.
5. `/assets/` (the stylesheet and vendored libraries) is public and sends `Access-Control-Allow-Origin: *`. It is the one path outside the sandbox that pages load from.
6. The pages ingresses skip Traefik's shared CSP middleware (`ingress_factory` `skip_default_csp`), and Caddy sets `frame-ancestors` itself. The auth-free carve-outs strip client-sent `X-Authentik-*` headers.

## Consequences

- Isolation between Spaces no longer depends on page authors behaving. A Space's content is still readable by everyone the Caddy routing admits, as before.
- Anyone holding a Bundle URL can read that one Bundle without signing in. It appears only inside the gated shell's frame, and a viewer can still copy it ("open frame in new tab"). Republishing rotates it.
- Page scripts lose `localStorage`, `sessionStorage`, `IndexedDB`, cookies and service workers. Five legacy pages in `wizard/` that load files from a sibling directory, or call `localStorage` unguarded, are exempt by path in the Caddyfile until they are republished as Bundles. The four older public carve-outs (`/prep`, `/pe-summit-trip`, `/vietnam`, `/homelab`) keep their own handles and are not sandboxed yet.
- Rybbit counts the shell, not the page in the frame. Session replay shows the shell with an empty frame.
- A browser that sends no `Sec-Fetch-Dest` gets the raw page directly: still sandboxed, without analytics.
- Printing a page from the shell prints only the visible part of the frame; `?raw` prints the whole page.

## Alternatives considered

- **A separate content origin per Space.** The strongest isolation, and it keeps cookies working for subresources. Rejected by Viktor in the grilling session: one Authentik application and routing table per Space, and a second host for public links.
- **SameSite=None on the Authentik cookie**, so sandboxed subresources carry it. Safari blocks and Firefox partitions third-party cookies, so it would fail for most phones; it would also weaken CSRF protection for every request to the host.
- **Inlining every Bundle file into one HTML page.** Breaks agent-written `fetch("data.json")` and ES module imports, and grows a 25 MiB Bundle by a third.
- **Short-lived signed URLs from a small service.** Narrows the Bundle URL exposure to hours, at the cost of a dynamic component in front of every page. Left as the next step if the trade-off in decision 3 proves too loose.
