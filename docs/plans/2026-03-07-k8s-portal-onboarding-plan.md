# K8s Portal Onboarding Hub — Implementation Plan (v2)

## Goals
1. Fix broken kubeconfig/OIDC setup script (users can't connect)
2. Add markdown-driven onboarding hub for non-technical users
3. Complete contributor onboarding (git, PR workflow, Codex setup)

---

## Part 1: Fix Setup Script Bugs

### Bug 1 — Empty CA cert (CRITICAL)
**Root cause**: ConfigMap `k8s-portal-config` has `ca.crt = ""`. The kubeconfig gets empty `certificate-authority-data`, causing TLS failures.

**Fix**:
1. Extract K8s API CA cert: `kubectl get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}'`
2. Verify it matches the API server cert: `openssl s_client -connect 10.0.20.100:6443 -showcerts 2>/dev/null | openssl x509 -issuer -noout` — compare issuer with CA cert subject
3. Add `variable "k8s_ca_cert" { type = string }` to `main.tf`
4. Add the cert value to `config.tfvars` (it's public, not a secret)
5. Use in ConfigMap: `"ca.crt" = var.k8s_ca_cert`
6. Pass through `stacks/platform/main.tf` module call

**Double-base64 risk**: The Node.js code does `Buffer.from(caCert).toString('base64')` on the PEM text. This creates base64-of-PEM, which kubectl accepts (kubectl handles both base64(PEM) and base64(DER)). Verified: this is the standard kubeconfig format used by `kubectl config set-cluster --certificate-authority`.

### Bug 2 — Missing VPN prerequisite
**Root cause**: Kubeconfig points to `https://10.0.20.100:6443` (internal IP). No VPN = no connection.

**Fix**: Add VPN setup as step 0 in both:
- The existing homepage (`+page.svelte`) — prominent callout box
- The new onboarding page — full enrollment instructions

### Bug 3 — Headscale enrollment is admin-gated
**Fix**: Document the complete flow:
1. User installs Tailscale app
2. User runs `tailscale login --login-server https://headscale.viktorbarzin.me`
3. User sends the registration URL to Viktor (via Slack/email — provide contact)
4. Viktor approves on Headscale
5. User is now on the VPN

### Bug 4 — `kubectl get pods` vs `kubectl get namespaces`
**Fix**: Change homepage `+page.svelte` to say `kubectl get namespaces` (consistent with setup script).

### Bug 5 — Unused `openid` scope fix
**NOT a bug**: kubelogin always adds `openid` automatically. Remove from the plan. The real investigation is: verify Authentik's `kubernetes` OIDC provider returns `groups` claim in the ID token.

### Bug 6 — Heredoc quoting no-op
**Fix**: Remove the useless `escapedKubeconfig` replace on line 49 of `script/+server.ts` — the quoted heredoc delimiter makes it irrelevant.

### Files to Modify
- `stacks/platform/modules/k8s-portal/main.tf` — add `k8s_ca_cert` variable, update ConfigMap
- `stacks/platform/main.tf` — pass `k8s_ca_cert` to module
- `config.tfvars` — add the CA cert value
- `files/src/routes/setup/script/+server.ts` — remove useless quote escaping
- `files/src/routes/download/+server.ts` — same CA cert fix applies here (identical code)
- `files/src/routes/+page.svelte` — add VPN callout, fix verification command

---

## Part 2: Content System — Skip mdsvex, Use Direct Svelte

### Why NOT mdsvex
- Svelte 5.53.0 broke mdsvex (unresolved as of today)
- Requires pinning Svelte to <5.53, which conflicts with security updates
- Runes mode in layouts is broken in mdsvex
- The content is 5 small pages authored by one person — mdsvex is overkill
- Build complexity and image size increase for minimal benefit

### Alternative: Write content directly in Svelte components
Each content page is a Svelte component with inline HTML/text:
```svelte
<!-- src/routes/onboarding/+page.svelte -->
<article class="content">
  <h1>Getting Started</h1>
  <p>Welcome! Follow these steps...</p>
  ...
</article>
```

**Advantages**:
- Zero new dependencies
- Works with any Svelte 5 version
- Content is still just HTML/text in clearly named files
- Can add Svelte interactivity later (copy buttons, progress tracking)

**Trade-off**: Content edits require touching `.svelte` files instead of `.md`. For 5 pages maintained by one person (or an AI), this is fine. If content grows significantly, revisit mdsvex later when Svelte 5 compatibility is stable.

### Shared Content Styling
Create `src/lib/content.css` with the docs-style layout:
```css
.content { max-width: 768px; margin: 2rem auto; font-family: system-ui; line-height: 1.6; }
.content h1 { border-bottom: 1px solid #e0e0e0; padding-bottom: 0.5rem; }
.content pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; }
.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
.content .callout { background: #fff3cd; border-left: 4px solid #ffc107; padding: 1rem; margin: 1rem 0; }
.content .danger { background: #f8d7da; border-left: 4px solid #dc3545; }
```

---

## Part 3: Route Structure

```
src/routes/
├── +layout.svelte                  ← Nav bar (Home, Onboarding, Architecture, Services, Contributing, Troubleshooting)
├── +page.svelte                    ← Identity + VPN callout + Get Started (UPDATED)
├── onboarding/+page.svelte         ← Step-by-step guide
├── architecture/+page.svelte       ← How the cluster works
├── services/+page.svelte           ← Service catalog
├── contributing/+page.svelte       ← PR workflow
├── troubleshooting/+page.svelte    ← Common issues
├── setup/+page.svelte              ← Existing kubectl install
├── setup/script/+server.ts         ← Existing auto-setup (FIXED)
└── download/+server.ts             ← Existing kubeconfig download (FIXED)
```

### Navigation Layout (`+layout.svelte`)
Simple horizontal nav, active page highlighted:
```svelte
<nav>
  <a href="/">Home</a>
  <a href="/onboarding">Getting Started</a>
  <a href="/architecture">Architecture</a>
  <a href="/services">Services</a>
  <a href="/contributing">Contributing</a>
  <a href="/troubleshooting">Help</a>
</nav>
<slot />
```

---

## Part 4: Page Content

### `/onboarding` — Getting Started (non-technical, step-by-step)

**Step 0 — Join the VPN**
- "The cluster is on a private network. You need VPN access first."
- Install Tailscale: link to tailscale.com/download
- Run: `tailscale login --login-server https://headscale.viktorbarzin.me`
- "This will open a browser with a registration URL. Send that URL to Viktor via [Slack/email]. He'll approve your device within a few hours."
- "Once approved, you're connected! Test: `ping 10.0.20.100`"

**Step 1 — Log in to the portal**
- "Visit https://k8s-portal.viktorbarzin.me and sign in with your Authentik account"
- "If you don't have an account, ask Viktor to create one"

**Step 2 — Set up kubectl**
- macOS: `bash <(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=mac)`
- Linux: `bash <(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=linux)`
- Windows: "Use WSL2 and follow the Linux instructions"
- macOS prerequisite: "Requires Homebrew. Install it first if you don't have it: [link]"

**Step 3 — Verify access**
- Run: `kubectl get namespaces`
- "This will open a browser for you to log in. After login, you should see a list of namespaces."
- Show expected output example

**Step 4 — Clone the repo**
- `git clone https://github.com/ViktorBarzin/infra.git`

**Step 5 — Install your AI assistant (optional)**
- Install Codex: `npm install -g @openai/codex`
- "Codex reads AGENTS.md from the repo and knows how to work with the cluster"

**Step 6 — Your first change**
- Walk-through: create branch, edit a file, push, open PR, watch CI

### `/architecture` — How It Works
- Simplified: "Proxmox runs VMs → VMs form a K8s cluster → services run as pods"
- Storage, networking, DNS in plain English
- Tier system: "critical services restart first, optional services restart last"

### `/services` — What's Running
- Table: service name, URL, what it does
- Top services highlighted (Nextcloud, Grafana, Uptime Kuma, etc.)

### `/contributing` — How to Contribute
- Branch → edit → PR → review → CI applies
- "What you CAN change" vs "what needs Viktor's review"
- The NEVER list (kubectl apply, secrets in plaintext, NFS restart)

### `/troubleshooting` — Common Issues
- "Can't connect to the cluster" → VPN + KUBECONFIG
- "Permission denied on kubectl" → namespace access
- "Pod is crashing" → check logs
- "PR CI failed" → read Woodpecker logs
- "Need a new secret" → ask Viktor

---

## Part 5: Build & Deploy

1. Make code changes (bug fixes + new pages)
2. Build locally: `cd files && npm install && npm run dev` — verify all pages
3. Test kubeconfig: verify CA cert is present and valid
4. Build Docker image: `docker build -t viktorbarzin/k8s-portal:latest .`
5. Push to registry
6. `terragrunt apply` to deploy
7. End-to-end test on a fresh machine

---

## Implementation Order
1. Fix CA cert (immediate — unblocks setup script)
2. Fix homepage (VPN callout, correct verification command)
3. Remove useless heredoc escaping
4. Add nav layout
5. Create 5 content pages (onboarding, architecture, services, contributing, troubleshooting)
6. Build, push, deploy
7. End-to-end test
