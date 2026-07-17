# Cluster root-cause fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement task-by-task. Steps use `- [ ]` checkboxes.
> **Design doc (canonical):** `docs/plans/2026-07-17-cluster-root-cause-fixes-design.md` (published: plans.viktorbarzin.me).

**Goal:** Fix three systemic root causes at the platform level — real client IP at the edge, monitoring-path-equals-user-path, and CSI wedge auto-remediation — retiring the symptomatic patches.

**Architecture:** All changes are Terraform applied via `worktree → commit → push → CI apply`, verified against **live state** (curl / kubectl / logs), not just plan output. Three phases land in order: **Fix 1 first** (it removes the monitor-500s that Fix 2 depends on), then Fix 2, then Fix 3. Fix 1's fleet-wide step is gated on a blind adversarial-challenger review and a 3-stage rollout.

**Tech Stack:** Traefik v3 local (Yaegi/Go) plugins, `ingress_factory`/`anubis_instance` TF modules, gatus (mx2), Prometheus/Alertmanager rules, Uptime-Kuma socket.io sync, a Python reconciler embedded in `stacks/proxmox-csi/ghost-reconcile.tf`.

**Global conventions (every task):**
- Worktree: `git -C ~/code/infra worktree add .worktrees/<topic> -b wizard/<topic> origin/master` with the git-crypt filter-bypass flags on every git command; never edit encrypted files from the worktree.
- `terraform fmt` changed files; commit staging files by name; push `HEAD:master`; watch the CI pipeline (Woodpecker repo 82) or apply locally from the **main checkout** (`scripts/tg init -upgrade -reconfigure && scripts/tg apply --non-interactive`), never from a worktree (git-crypt tfvars read as ciphertext there).
- Claim presence before any apply touching shared infra: `~/code/scripts/presence claim <label> --purpose "..."`.

---

## File Structure

**Fix 1 — real client IP:**
- Create: `stacks/traefik/modules/traefik/real-ip-plugin/{go.mod,main.go,config.go}` — vendored Yaegi plugin (mirrors `sablier-plugin/`).
- Modify: `stacks/traefik/modules/traefik/main.tf:215` (`localPlugins` — register `realip`) + a new `Middleware` CR `real-ip` in `stacks/traefik/modules/traefik/middleware.tf`.
- Modify: `modules/kubernetes/ingress_factory/main.tf:399` (prepend `traefik-real-ip@kubernetescrd` to the default chain) — Stage B.
- Modify + delete: remove `drop-x-real-ip` middleware (`middleware.tf`), the `strip_x_real_ip` variable (`ingress_factory/main.tf`), and all `strip_x_real_ip = true` lines in `stacks/{blog,cyberchef,f1-stream,homepage,jsoncrack,kms,real-estate-crawler}/main.tf` — Stage C.

**Fix 2 — monitoring = user path:**
- Modify: `stacks/backup-mx/` gatus config (mx2) — add user-facing non-Anubis probes with content assertions.
- Modify: `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` — Anubis `:9090` scrape job + `AnubisNotValidating` alert (infra#78).
- Modify: `stacks/uptime-kuma/modules/uptime-kuma/main.tf` — rename the in-cluster "[External]" monitors' prefix to reflect internal-reachability.

**Fix 3 — CSI wedge:**
- Modify: `stacks/proxmox-csi/ghost-reconcile.tf` — extend the embedded Python with `find_wedged()` + `remediate_wedged()`, gated by a `WEDGE_DRY_RUN` env.

---

## Phase 1 — Fix 1: Real client IP at the edge

### Task 1.1: Vendor the `real-ip` Traefik plugin

**Files:**
- Create: `stacks/traefik/modules/traefik/real-ip-plugin/go.mod`
- Create: `stacks/traefik/modules/traefik/real-ip-plugin/main.go`
- Create: `stacks/traefik/modules/traefik/real-ip-plugin/config.go`
- Reference: `stacks/traefik/modules/traefik/sablier-plugin/` (structure to mirror)

- [ ] **Step 1: Read the sablier plugin to mirror its module path + `.traefik.yml`/manifest convention**

Run: `cat stacks/traefik/modules/traefik/sablier-plugin/go.mod stacks/traefik/modules/traefik/sablier-plugin/.traefik.yml 2>/dev/null`
Expected: shows the `module` path and `import` string Traefik's `localPlugins` expects.

- [ ] **Step 2: Write the plugin (`main.go`)** — rewrite `X-Real-Ip` from the true client, precedence `CF-Connecting-IP` → first public XFF entry → leave existing.

```go
package real_ip_plugin

import (
	"context"
	"net"
	"net/http"
	"strings"
)

type Config struct{}

func CreateConfig() *Config { return &Config{} }

type RealIP struct {
	next http.Handler
	name string
}

func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	return &RealIP{next: next, name: name}, nil
}

func isPublic(ip string) bool {
	p := net.ParseIP(strings.TrimSpace(ip))
	if p == nil {
		return false
	}
	// reject loopback, RFC1918, link-local, and CGNAT 100.64/10
	if p.IsLoopback() || p.IsPrivate() || p.IsLinkLocalUnicast() {
		return false
	}
	if p4 := p.To4(); p4 != nil && p4[0] == 100 && p4[1]&0xC0 == 64 {
		return false
	}
	return true
}

func (r *RealIP) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if cf := strings.TrimSpace(req.Header.Get("Cf-Connecting-Ip")); cf != "" {
		req.Header.Set("X-Real-Ip", cf)
	} else if xff := req.Header.Get("X-Forwarded-For"); xff != "" {
		for _, part := range strings.Split(xff, ",") {
			if isPublic(part) {
				req.Header.Set("X-Real-Ip", strings.TrimSpace(part))
				break
			}
		}
	}
	// else: leave the existing X-Real-Ip (the real peer on the direct/in-cluster path)
	r.next.ServeHTTP(rw, req)
}
```

- [ ] **Step 3: Write `config.go`** (if the sablier plugin splits Config out; otherwise fold into main.go and skip). Match sablier's split exactly.

- [ ] **Step 4: Write `go.mod`** with the module path matching the `import` you'll register in `localPlugins` (mirror sablier's `go.mod` module line, e.g. `module github.com/viktorbarzin/real-ip-plugin`).

- [ ] **Step 5: Vet the plugin compiles under Yaegi's constraints** (no CGO, stdlib only — the above uses only `net`/`net/http`/`strings`/`context`, all Yaegi-safe).

Run: `cd stacks/traefik/modules/traefik/real-ip-plugin && go vet ./... && go build ./...`
Expected: no errors.

- [ ] **Step 6: Unit-test the precedence logic**

Create `stacks/traefik/modules/traefik/real-ip-plugin/main_test.go`:

```go
package real_ip_plugin

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func serve(h http.Header) string {
	req := httptest.NewRequest("GET", "/", nil)
	req.Header = h
	var got string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { got = r.Header.Get("X-Real-Ip") })
	rp, _ := New(nil, next, CreateConfig(), "t")
	rp.ServeHTTP(httptest.NewRecorder(), req)
	return got
}

func TestCFWins(t *testing.T) {
	if serve(http.Header{"Cf-Connecting-Ip": {"203.0.113.5"}, "X-Forwarded-For": {"198.51.100.9"}, "X-Real-Ip": {"10.10.1.1"}}) != "203.0.113.5" {
		t.Fatal("CF-Connecting-IP must win")
	}
}
func TestXFFPublicFallback(t *testing.T) {
	if serve(http.Header{"X-Forwarded-For": {"10.10.1.1, 203.0.113.7"}, "X-Real-Ip": {"10.10.1.1"}}) != "203.0.113.7" {
		t.Fatal("first public XFF entry must win over private")
	}
}
func TestHeaderlessLeavesPeer(t *testing.T) {
	if serve(http.Header{"X-Real-Ip": {"10.10.9.9"}}) != "10.10.9.9" {
		t.Fatal("no CF/XFF must leave the existing X-Real-Ip (non-empty)")
	}
}
```

Run: `cd stacks/traefik/modules/traefik/real-ip-plugin && go test ./...`
Expected: PASS (3 tests). This test proves the headerless case never blanks `X-Real-Ip` — the property that closes the 500 hole.

- [ ] **Step 7: Register the plugin in `localPlugins`** — `stacks/traefik/modules/traefik/main.tf` around line 215, add a `realip` entry mirroring the sablier one (moduleName = the `go.mod` module path, path = `/plugins-local/src/<module>` per the vendored-mount convention sablier uses).

- [ ] **Step 8: Commit**

```bash
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false add stacks/traefik/modules/traefik/real-ip-plugin/ stacks/traefik/modules/traefik/main.tf
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false commit -m "traefik: vendor real-ip local plugin (not yet attached)"
```

### Task 1.2: Define the `real-ip` Middleware CR (not yet in the default chain)

**Files:** Modify `stacks/traefik/modules/traefik/middleware.tf`

- [ ] **Step 1: Add the Middleware CR** referencing the plugin (mirror how the sablier Middleware references `spec.plugin.sablier`):

```hcl
resource "kubernetes_manifest" "middleware_real_ip" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata   = { name = "real-ip", namespace = kubernetes_namespace.traefik.metadata[0].name }
    spec       = { plugin = { realip = {} } }
  }
  depends_on = [helm_release.traefik]
}
```

- [ ] **Step 2: Commit + push + apply the traefik stack**

```bash
git -c filter.git-crypt.smudge=cat ... add stacks/traefik/modules/traefik/middleware.tf
git ... commit -m "traefik: add real-ip Middleware CR (plugin wired, unattached)"
git ... push origin HEAD:master
```
Claim presence `stack:traefik` first. Watch CI apply (or apply locally from main checkout).

- [ ] **Step 3: Verify the plugin loads on the rolled Traefik pods**

Run: `kubectl -n traefik logs -l app.kubernetes.io/name=traefik | grep "Plugins loaded"`
Expected: the plugin list now includes `realip` alongside `api-token-middleware` and `sablier`. If any plugin fails to load, ALL plugins silently disable — STOP and fix before proceeding.

### Task 1.3: Stage A — attach to ONE Anubis site, verify, drop that site's strip

**Files:** Modify `stacks/kms/main.tf` (kms = non-proxied Anubis site; safe first target since a non-proxied site exercises the XFF-fallback path).

- [ ] **Step 1: Add `traefik-real-ip@kubernetescrd` to kms's `extra_middlewares`** (first in the list), keeping its existing middlewares.

- [ ] **Step 2: Commit + push + apply kms** (presence `service:kms`).

- [ ] **Step 3: Verify X-Real-Ip is corrected + no 500 on a headerless probe**

Run: header-less in-cluster probe through Traefik:
```bash
kubectl -n homepage exec deploy/homepage -- wget -qO /dev/null --header "Host: kms.viktorbarzin.me" https://10.0.20.203/ --no-check-certificate; echo "rc=$?"
```
Expected: `rc=0` (200 challenge), NOT 500. And a real WAN probe (`--resolve kms...:176.12.22.76`) still 200.
Run: `kubectl -n kms logs -l app=anubis-kms --since=3m | grep "check failed" | wc -l`
Expected: `0`.

- [ ] **Step 4: Remove `strip_x_real_ip = true` from kms** (the drop-x-real-ip middleware is now redundant there — real-ip supplies a valid X-Real-Ip). Commit + push + apply.

- [ ] **Step 5: Re-verify** Step 3 still holds (200, zero check-failed) with the strip gone. This proves real-ip alone is sufficient.

### Task 1.4: GATE — blind adversarial-challenger review before the fleet change

- [ ] **Step 1: Spawn 2 independent, blind challenger subagents** (per `planning.md` §2b) briefed to DISPROVE that adding `real-ip` to the **default `ingress_factory` chain** is safe fleet-wide. Each must verify against live data: (a) does any middleware upstream of real-ip in the chain need the original X-Real-Ip? (b) any backend that breaks if X-Real-Ip becomes the real client (rate-limiters, per-IP logic, logging)? (c) the x402 gateway + CrowdSec interaction; (d) non-proxied + IPv6 (HAProxy PROXY-v2) paths; (e) performance of a Yaegi plugin on every request.
- [ ] **Step 2: Reconcile findings.** Any unverified concern → verify or resolve before Stage B. Proceed only when both challengers agree it's safe (or their concerns are addressed). Do NOT present unvetted findings; surface real dissent to the user.

### Task 1.5: Stage B — move real-ip into the default chain (fleet-wide)

**Files:** Modify `modules/kubernetes/ingress_factory/main.tf:399` — prepend `"traefik-real-ip@kubernetescrd",` as the FIRST entry of the default middleware chain.

- [ ] **Step 1: Prepend the middleware** (ahead of retry/error-pages/rate-limit/csp/auth) + remove the kms-specific `extra_middlewares` real-ip entry from Task 1.3 (now covered by the default).
- [ ] **Step 2: Commit + push.** This is a global-file change → CI applies all platform + app stacks. Presence `infra:real-ip-fleet`. Watch to completion.
- [ ] **Step 3: Verify a representative sample** — anubis proxied (home), anubis non-proxied (f1), a normal app (e.g. forgejo), and an in-cluster headerless probe:

```bash
for h in home.viktorbarzin.me f1.viktorbarzin.me forgejo.viktorbarzin.me; do
  CFIP=$(dig +short @1.1.1.1 $h | head -1); curl -sS --max-time 15 --resolve $h:443:$CFIP -A "Mozilla/5.0 Chrome/150" -o /dev/null -w "$h %{http_code}\n" https://$h/; done
```
Expected: all 200/302/307 (healthy), none 5xx. Anubis pods show `x-real-ip` = real client (not a `10.10.x` pod IP) in logs.

### Task 1.6: Stage C — remove the strip machinery everywhere

**Files:** Modify `stacks/{blog,cyberchef,f1-stream,homepage,jsoncrack,real-estate-crawler}/main.tf` (kms already done in 1.3); Modify `stacks/traefik/modules/traefik/middleware.tf` (delete `middleware_drop_x_real_ip`); Modify `modules/kubernetes/ingress_factory/main.tf` (delete the `strip_x_real_ip` variable + its use).

- [ ] **Step 1: Remove every `strip_x_real_ip = true`** from the 6 remaining anubis stacks.
- [ ] **Step 2: Delete the `drop-x-real-ip` Middleware resource + the `strip_x_real_ip` variable + the conditional in the chain.**
- [ ] **Step 3: `grep -rn "strip_x_real_ip\|drop-x-real-ip" stacks/ modules/`** → expected: zero matches.
- [ ] **Step 4: Commit + push + apply.** Verify the sample from 1.5 Step 3 still all-green (no strip, real-ip carrying the client).
- [ ] **Step 5: Update docs** — `.claude/CLAUDE.md` Anubis bullet + `docs/architecture/networking.md`: X-Real-Ip is now corrected platform-wide by the `real-ip` default middleware; the per-app strip is retired. Commit in the same push.

---

## Phase 2 — Fix 2: Monitoring path = user path

### Task 2.1: gatus (mx2) probes for user-facing non-Anubis sites

**Files:** Modify the gatus config in `stacks/backup-mx/` (the mx2 gatus endpoints list, ADR-0020).

- [ ] **Step 1: Identify the user-facing non-Anubis sites to add** (e.g. immich, nextcloud, grafana, actualbudget — the ones a real outage would hurt). List them; exclude Anubis-gated (handled in 2.2) and internal-only.
- [ ] **Step 2: Add a gatus endpoint per site** with a content assertion on stable app markup, e.g.:

```yaml
- name: nextcloud
  url: "https://nextcloud.viktorbarzin.me/status.php"
  conditions:
    - "[STATUS] == 200"
    - "[BODY] == pat(*installed*true*)"
```
(Pick a real marker per app; for SPA apps assert a known static string in the shell.)

- [ ] **Step 3: Apply mx2 config** (per the backup-mx deploy path) + verify at `status.viktorbarzin.me` the new probes report and a deliberately-wrong assertion goes red.

### Task 2.2: Anubis validated/issued ratio alert (infra#78)

**Files:** Modify `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (scrape job + alert rule).

- [ ] **Step 1: Add a scrape job** for the anubis pods' `:9090` metrics across the 7 namespaces (annotation-based or `extraScrapeConfigs`), keeping `anubis_challenges_issued`, `anubis_challenges_validated`, `anubis_proxied_requests_total`.
- [ ] **Step 2: Add the alert:**

```yaml
- alert: AnubisNotValidating
  expr: |
    sum(rate(anubis_challenges_issued[30m])) > 0.02
    and sum(rate(anubis_challenges_validated[30m])) < 0.001
  for: 30m
  labels: { severity: warning }
  annotations:
    summary: "Anubis issuing challenges but ~none validate — PoW-gated sites likely serving challenge-to-everyone (blank pages)"
```
(0.02/s issued ≈ above the monitor-probe baseline; tune from live `rate()`.)

- [ ] **Step 3: Commit + push + apply monitoring.** Verify the scrape targets are UP (`/api/v1/targets`) and the rule loads (`/api/v1/rules`).

### Task 2.3: Reclassify the in-cluster "[External]" monitors

**Files:** Modify `stacks/uptime-kuma/modules/uptime-kuma/main.tf` (the `PREFIX` used by external-monitor-sync).

- [ ] **Step 1: Rename the monitor prefix** from `[External] ` to `[Internal-path] ` (or similar) in the sync script, so these in-cluster (split-horizon → internal LB) probes are not mistaken for external-path truth. Update the healthcheck's classification if it keys on the prefix.
- [ ] **Step 2: Apply + verify** the sync renames existing monitors (or creates renamed + deletes old) and the cluster-health check reads them as internal.
- [ ] **Step 3: Confirm Fix 1 already removed the 500s** these probes caused (anubis logs: zero `check failed` from Uptime-Kuma UA) — no separate action, just verify.

---

## Phase 3 — Fix 3: CSI wedge auto-remediation

### Task 3.1: Extend `ghost-reconcile` with a dry-run wedge pass

**Files:** Modify `stacks/proxmox-csi/ghost-reconcile.tf` (the embedded Python + a `WEDGE_DRY_RUN` env var, default `"true"`).

- [ ] **Step 1: Read the current script** (`attached()`, `find_ghosts()`, the k8s + pve helpers, the safety pattern: `vm-9999-pvc-*` only, 60s re-confirm, per-run cap).

Run: `sed -n '70,200p' stacks/proxmox-csi/ghost-reconcile.tf`

- [ ] **Step 2: Add `find_wedged()`** — scan pods for the wedge signature (k8s-native, no Proxmox call needed):

```python
def find_wedged():
    # pods stuck Init/ContainerCreating with a FailedMount 'device ... not found'
    # event older than THRESHOLD_S, mapped to their PV's VolumeAttachment.
    pods = k8s("/api/v1/pods?fieldSelector=status.phase=Pending")["items"]
    wedged = []
    for p in pods:
        ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
        ev = k8s(f"/api/v1/namespaces/{ns}/events?fieldSelector=involvedObject.name={name}")["items"]
        if not any(e.get("reason") == "FailedMount" and "device" in e.get("message","")
                   and "not found" in e.get("message","") for e in ev):
            continue
        # age gate: only if the FailedMount has persisted past THRESHOLD_S
        # (reuse the same clock the ghost pass uses)
        wedged.append((ns, name, pvc_to_va(p)))
    return [w for w in wedged if w[2]]
```
(`pvc_to_va` resolves the pod's PVC → PV → VolumeAttachment name on that node; reuse existing helpers.)

- [ ] **Step 3: Add `remediate_wedged()`** — guarded delete of the VA:

```python
def remediate_wedged(wedged, dry_run, cap):
    acted = 0
    for ns, name, va in wedged:
        if acted >= cap: break
        time.sleep(60)  # re-confirm; skip if the pod recovered on its own
        if pod_recovered(ns, name):  # phase Running or gone
            continue
        if dry_run:
            print(f"[wedge] WOULD delete VolumeAttachment {va} for {ns}/{name}")
        else:
            k8s(f"/apis/storage.k8s.io/v1/volumeattachments/{va}", method="DELETE")
            print(f"[wedge] deleted VolumeAttachment {va} for {ns}/{name}")
        acted += 1
    return acted
```

- [ ] **Step 4: Wire into `main`** — call the wedge pass after the ghost pass, reading `WEDGE_DRY_RUN` (default `"true"`) and the existing per-run cap. Emit a `csi_wedge_remediated` / log line consumable by an alert.
- [ ] **Step 5: Extract + unit-test the detection** locally (copy the script body to a tmp file, feed fixture k8s JSON for a wedged pod and a healthy pod) — assert `find_wedged()` returns only the wedged one, and `remediate_wedged(..., dry_run=True)` deletes nothing.

Run: `python3 /tmp/test_wedge.py`
Expected: PASS.

- [ ] **Step 6: Commit + push + apply** (presence `stack:proxmox-csi`). `WEDGE_DRY_RUN=true`.
- [ ] **Step 7: Observe dry-run** — over the next window (or by injecting a wedge on a throwaway PVC), confirm the job logs the correct `WOULD delete` for a genuinely-stuck pod and NOTHING for healthy in-use volumes.

Run: `kubectl -n proxmox-csi logs job/<latest csi-ghost-reconcile run> | grep wedge`
Expected: correct `WOULD delete` lines only.

### Task 3.2: Flip wedge remediation to live + alert

**Files:** Modify `stacks/proxmox-csi/ghost-reconcile.tf` (`WEDGE_DRY_RUN=false`); Modify `stacks/monitoring/.../prometheus_chart_values.tpl` (a `CSIVolumeWedged` alert so the event is visible even after auto-heal).

- [ ] **Step 1: Set `WEDGE_DRY_RUN=false`.** Commit + push + apply.
- [ ] **Step 2: Add `CSIVolumeWedged` alert** (fires on the wedge signature / a `csi_wedge_detected` pushgateway gauge, so a human sees it even though it auto-heals). Commit in the same push.
- [ ] **Step 3: Live-fire verify** — inject a wedge (detach a scsiN from a throwaway pod's VM via the CSI token, or replay the known signature) and confirm the job deletes the VA and the pod recovers within one reconcile cycle; confirm a healthy in-use volume is never touched.
- [ ] **Step 4: Update docs** — `.claude/CLAUDE.md` + the CSI runbook: the wedge class is now auto-remediated; describe the guard + how to disable (`WEDGE_DRY_RUN=true`).

---

## Self-Review

- **Spec coverage:** Fix 1 (plugin 1.1, CR 1.2, stages A/B/C 1.3/1.5/1.6, review gate 1.4) ✓; Fix 2 (gatus 2.1, infra#78 2.2, reclassify 2.3) ✓; Fix 3 (dry-run 3.1, live+alert 3.2) ✓. Cross-cutting "Fix 1 removes monitor-500s" verified in 2.3 Step 3 ✓. Deferred safer-defaults class correctly absent ✓.
- **Ordering:** Fix 1 before Fix 2 (1.6 lands before 2.3) ✓; review gate (1.4) before the fleet change (1.5) ✓; Fix 3 dry-run (3.1) before live (3.2) ✓.
- **Placeholders:** plugin, tests, alert exprs, and reconciler functions are concrete. The gatus per-site markers (2.1 Step 2) and the exact `localPlugins` moduleName (1.1 Step 7) are read-from-live-then-fill, flagged as such, not TBD.
- **Consistency:** middleware name `traefik-real-ip@kubernetescrd` and the `real-ip` CR / `realip` plugin key are used consistently across 1.2/1.3/1.5/1.6.
