# t3code per-user auto-provisioning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An onboarded Authentik user who opens `t3.viktorbarzin.me` lands straight in their own t3 workspace — instance auto-provisioned, t3 session auto-minted+injected, file access bounded to their OS uid.

**Architecture:** Per-user `t3 serve` instances via a `t3-serve@<osuser>` systemd template (`User=%i` = OS-enforced file perms). A devvm reconcile turns `/etc/ttyd-user-map` entries into running instances. A small devvm dispatch+auto-pair service (behind Traefik+Authentik) routes `X-authentik-username` to the user's instance and, on first visit, mints + injects t3's session cookie. `stacks/t3code` shrinks to ingress + Endpoints → that service.

**Tech Stack:** systemd templates, bash (reconcile), Go (dispatch service — single static binary, native WS proxy), Traefik/Authentik, Terraform/Terragrunt.

**Spec:** `infra/docs/plans/2026-06-01-t3-auto-provision-design.md`

**Conventions:** devvm host artifacts are versioned under `infra/scripts/` and deployed via `scp` (same as `apply-mbps-caps.{sh,service,timer}`); they are NOT Terraform-managed (like the existing `t3-serve` / terminal-lobby). Only the K8s edge is in `stacks/t3code`. Claim presence (`host:devvm`, `stack:t3code`) before mutating. Verify each task before committing.

---

## Task 1: Discover the t3 web-auth contract (spike — blocks the dispatch service)

The auto-pair step must speak t3's exact session protocol. Nail these three unknowns before writing the service.

**Files:** none (investigation; record findings in this task's checkboxes).

- [ ] **Step 1: Find the session cookie name.** Read `apps/server/src/auth/Layers/SessionCredentialService.ts` (or `Services/SessionCredentialService.ts`) in the t3code repo for `cookieName`. Cross-check live: pair a browser to a t3 instance, inspect the cookie set on `t3.viktorbarzin.me`.
  Run: `gh api repos/pingdotgg/t3code/contents/apps/server/src/auth/Services/SessionCredentialService.ts --jq '.content' | base64 -d | grep -niE 'cookieName|cookie'`
  Record: `T3_COOKIE=<value>`.
- [ ] **Step 2: Find the bootstrap request shape.** Read how the web UI exchanges a pairing token for a session: `apps/server/src/auth/http.ts` `authBootstrapRouteLayer` + the `AuthBootstrapInput` schema in `packages/contracts`, and `apps/web/src/components/auth/PairingRouteSurface.tsx` / `hostedPairing.ts`.
  Run: `gh api repos/pingdotgg/t3code/contents/packages/contracts/src/<auth file>.ts --jq '.content' | base64 -d | grep -niE 'Bootstrap|pairing|token'`
  Record: the exact `POST /api/auth/bootstrap` JSON body (field name(s) for the pairing token).
- [ ] **Step 3: Verify the exchange by hand against a live instance.** On devvm:
  ```bash
  TOK=$(sudo -u wizard t3 auth pairing create --base-dir /home/wizard/.t3 --ttl 5m --json | jq -r '.token // .pairingToken')
  curl -s -i -XPOST http://127.0.0.1:3773/api/auth/bootstrap \
    -H 'content-type: application/json' -d "{\"<field>\":\"$TOK\"}" | grep -iE 'set-cookie|HTTP/'
  ```
  Expected: `HTTP/.. 200` + a `Set-Cookie: <T3_COOKIE>=...`. This confirms the mint→bootstrap→cookie flow the service will automate.
- [ ] **Step 4: Commit findings** as a short note appended to the design doc (`## Discovered auth contract` section): `T3_COOKIE`, bootstrap body shape, and the verified curl. Commit `docs(t3code): record discovered t3 web-auth contract`.

---

## Task 2: systemd template `t3-serve@.service` (file-permission enforcement)

**Files:**
- Create: `infra/scripts/t3-serve@.service`
- Deploy to devvm: `/etc/systemd/system/t3-serve@.service`
- Retire: `/etc/systemd/system/t3-serve.service`, `/etc/systemd/system/t3-serve-emo.service`

- [ ] **Step 1: Write the template unit** (`infra/scripts/t3-serve@.service`):

```ini
[Unit]
Description=T3 Code server for %i (t3 serve, per-user)
Documentation=https://github.com/pingdotgg/t3code
After=network.target

[Service]
Type=simple
User=%i
Group=%i
Environment=HOME=/home/%i
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/%i/.local/bin
Environment=NODE_ENV=production
EnvironmentFile=/etc/t3-serve/%i.env
WorkingDirectory=/home/%i
ExecStart=/usr/bin/t3 serve --host 0.0.0.0 --port ${T3_PORT} --base-dir /home/%i/.t3
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Stage the existing users' env files (preserve live ports):**
```bash
sudo install -d -m 0755 /etc/t3-serve
echo 'T3_PORT=3773' | sudo tee /etc/t3-serve/wizard.env
echo 'T3_PORT=3774' | sudo tee /etc/t3-serve/emo.env
```
- [ ] **Step 3: Deploy the template + migrate wizard, then emo (one at a time to limit blast radius):**
```bash
sudo cp infra/scripts/t3-serve@.service /etc/systemd/system/t3-serve@.service
sudo systemctl daemon-reload
# wizard: stop old bespoke unit, start template instance
sudo systemctl disable --now t3-serve.service
sudo systemctl enable --now t3-serve@wizard.service
```
- [ ] **Step 4: Verify wizard instance runs as wizard on :3773 and serves:**
Run:
```bash
ps -o user= -C t3 | sort -u            # expect: wizard (and emo after next step)
ss -ltn | grep ':3773'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3773/   # expect 200
```
Expected: process owned by `wizard`, listening, 200. (wizard's existing pairings persist — same `~/.t3`.)
- [ ] **Step 5: Migrate emo the same way:**
```bash
sudo systemctl disable --now t3-serve-emo.service
sudo systemctl enable --now t3-serve@emo.service
```
- [ ] **Step 6: Verify emo instance runs as emo + file-permission negative test:**
Run:
```bash
ss -ltn | grep ':3774'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3774/        # expect 200
sudo -u emo test -w /home/wizard/.t3 && echo WRITABLE || echo "denied (correct)"   # expect denied
```
Expected: 200; emo cannot write wizard's private `~/.t3` (file-perm enforcement proven).
- [ ] **Step 7: Commit** `infra/scripts/t3-serve@.service`: `t3code: per-user t3-serve@ systemd template (User=%i file isolation)`.

---

## Task 3: Reconcile script + timer (data-driven from `/etc/ttyd-user-map`)

**Files:**
- Create: `infra/scripts/t3-provision-users.sh`, `infra/scripts/t3-provision-users.service`, `infra/scripts/t3-provision-users.timer`
- Deploy to devvm: `/usr/local/bin/t3-provision-users`, `/etc/systemd/system/t3-provision-users.{service,timer}`
- Writes: `/etc/t3-serve/<u>.env`, `/etc/t3-serve/dispatch.json`

- [ ] **Step 1: Write `infra/scripts/t3-provision-users.sh`** (idempotent; allocates sticky ports from 3773+, ensures `t3-serve@<u>`, emits the dispatcher map):

```bash
#!/usr/bin/env bash
# Reconcile per-user t3 instances from /etc/ttyd-user-map.
# Each "authentik_user=os_user" line → an enabled t3-serve@<os_user> on a
# sticky port, plus /etc/t3-serve/dispatch.json (authentik_user → {os_user,port})
# consumed by t3-dispatch.
set -euo pipefail
MAP=/etc/ttyd-user-map
ENVDIR=/etc/t3-serve
BASE_PORT=3773
install -d -m 0755 "$ENVDIR"

next_port() {            # lowest free port >= BASE_PORT not already assigned
  local used p
  used=$(grep -hoE 'T3_PORT=[0-9]+' "$ENVDIR"/*.env 2>/dev/null | cut -d= -f2 | sort -n)
  p=$BASE_PORT
  while echo "$used" | grep -qx "$p"; do p=$((p+1)); done
  echo "$p"
}

declare -A DISPATCH
while IFS='=' read -r ak os; do
  [[ -z "${ak// }" || "$ak" =~ ^[[:space:]]*# ]] && continue
  ak=$(echo "$ak" | xargs); os=$(echo "$os" | xargs)
  id "$os" >/dev/null 2>&1 || { logger -t t3-provision "skip $ak: no OS user $os"; continue; }
  envf="$ENVDIR/$os.env"
  if [[ ! -f "$envf" ]]; then echo "T3_PORT=$(next_port)" > "$envf"; fi
  port=$(grep -oE '[0-9]+' "$envf")
  systemctl enable --now "t3-serve@$os.service" >/dev/null 2>&1 || true
  DISPATCH[$ak]="{\"os_user\":\"$os\",\"port\":$port}"
done < "$MAP"

{ printf '{'; first=1
  for ak in "${!DISPATCH[@]}"; do
    [[ $first -eq 0 ]] && printf ','; first=0
    printf '"%s":%s' "$ak" "${DISPATCH[$ak]}"
  done; printf '}\n'; } > "$ENVDIR/dispatch.json"
logger -t t3-provision "reconcile complete: $(wc -c < "$ENVDIR/dispatch.json") bytes"
```

- [ ] **Step 2: Write the timer + service** (`infra/scripts/t3-provision-users.service`):
```ini
[Unit]
Description=Reconcile per-user t3 instances from /etc/ttyd-user-map
[Service]
Type=oneshot
ExecStart=/usr/local/bin/t3-provision-users
```
`infra/scripts/t3-provision-users.timer`:
```ini
[Unit]
Description=Periodic t3 per-user reconcile
[Timer]
OnBootSec=2min
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
```
- [ ] **Step 3: Deploy + run once:**
```bash
sudo install -m 0755 infra/scripts/t3-provision-users.sh /usr/local/bin/t3-provision-users
sudo cp infra/scripts/t3-provision-users.service infra/scripts/t3-provision-users.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now t3-provision-users.timer
sudo /usr/local/bin/t3-provision-users
```
- [ ] **Step 4: Verify idempotency + output:**
Run:
```bash
cat /etc/t3-serve/dispatch.json | jq .     # expect {"vbarzin":{"os_user":"wizard","port":3773},"emil.barzin":{"os_user":"emo","port":3774}}
sudo /usr/local/bin/t3-provision-users     # run again
cat /etc/t3-serve/wizard.env               # expect T3_PORT=3773 (unchanged — sticky)
```
Expected: dispatch.json correct; re-run changes nothing (ports stable).
- [ ] **Step 5: Commit** the three files: `t3code: reconcile per-user t3 instances from ttyd-user-map`.

---

## Task 4: Dispatch + auto-pair service (Go, devvm)

**Files:**
- Create: `t3-dispatch/main.go`, `t3-dispatch/go.mod`
- Create: `infra/scripts/t3-dispatch.service` → `/etc/systemd/system/t3-dispatch.service`
- Deploy binary to devvm: `/usr/local/bin/t3-dispatch`

Uses `T3_COOKIE` + bootstrap body from Task 1. Listens `:3780`. Reads `/etc/t3-serve/dispatch.json`.

- [ ] **Step 1: Write `t3-dispatch/main.go`** (substitute `<T3_COOKIE>` and the bootstrap field from Task 1):

```go
package main

import (
	"bytes"; "encoding/json"; "fmt"; "log"; "net/http"; "net/http/httputil"
	"net/url"; "os"; "os/exec"; "sync"; "time"
)

type entry struct{ OsUser string `json:"os_user"`; Port int `json:"port"` }
const cookieName = "<T3_COOKIE>"            // from Task 1
const listenAddr = ":3780"
const dispatchFile = "/etc/t3-serve/dispatch.json"

var mu sync.RWMutex
var table map[string]entry

func loadTable() error {
	b, err := os.ReadFile(dispatchFile); if err != nil { return err }
	m := map[string]entry{}; if err := json.Unmarshal(b, &m); err != nil { return err }
	mu.Lock(); table = m; mu.Unlock(); return nil
}

func lookup(ak string) (entry, bool) { mu.RLock(); defer mu.RUnlock(); e, ok := table[ak]; return e, ok }

func proxyTo(port int) *httputil.ReverseProxy { // ReverseProxy handles WS upgrade transparently
	u, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port)); return httputil.NewSingleHostReverseProxy(u)
}

func autoPair(e entry, w http.ResponseWriter, r *http.Request) {
	out, err := exec.Command("sudo", "-n", "-u", e.OsUser, "t3", "auth", "pairing", "create",
		"--base-dir", "/home/"+e.OsUser+"/.t3", "--ttl", "5m", "--json").Output()
	if err != nil { http.Error(w, "pairing mint failed", 500); log.Printf("mint %s: %v", e.OsUser, err); return }
	var pc struct{ Token string `json:"token"` }            // adjust field per Task 1
	if json.Unmarshal(out, &pc) != nil || pc.Token == "" { http.Error(w, "bad pairing output", 500); return }
	body, _ := json.Marshal(map[string]string{"token": pc.Token}) // adjust body per Task 1
	resp, err := http.Post(fmt.Sprintf("http://127.0.0.1:%d/api/auth/bootstrap", e.Port),
		"application/json", bytes.NewReader(body))
	if err != nil { http.Error(w, "bootstrap failed", 502); return }
	defer resp.Body.Close()
	for _, c := range resp.Cookies() { http.SetCookie(w, c) }
	http.Redirect(w, r, "/", http.StatusFound)
}

func handler(w http.ResponseWriter, r *http.Request) {
	ak := r.Header.Get("X-authentik-username")
	e, ok := lookup(ak)
	if !ok { http.Error(w, "no t3 instance for this user", http.StatusForbidden); return }
	if _, err := r.Cookie(cookieName); err != nil { autoPair(e, w, r); return }
	proxyTo(e.Port).ServeHTTP(w, r)
}

func main() {
	if err := loadTable(); err != nil { log.Fatalf("load %s: %v", dispatchFile, err) }
	go func() { for range time.Tick(60 * time.Second) { _ = loadTable() } }() // pick up reconcile changes
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request){ w.Write([]byte("ok")) })
	http.HandleFunc("/", handler)
	log.Printf("t3-dispatch on %s", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}
```

- [ ] **Step 2: `t3-dispatch/go.mod`:** `module t3-dispatch` / `go 1.22`. Build: `cd t3-dispatch && GOOS=linux GOARCH=amd64 go build -o t3-dispatch .`
- [ ] **Step 3: Write `infra/scripts/t3-dispatch.service`:**
```ini
[Unit]
Description=t3 per-user dispatch + auto-pair (X-authentik-username → user instance)
After=network.target
[Service]
Type=simple
User=wizard
ExecStart=/usr/local/bin/t3-dispatch
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```
(Runs as `wizard`; the scoped sudoers in Task 5 lets it mint per-user tokens.)
- [ ] **Step 4: Deploy + start:**
```bash
scp t3-dispatch/t3-dispatch wizard@10.0.10.10:/tmp/t3-dispatch
sudo install -m 0755 /tmp/t3-dispatch /usr/local/bin/t3-dispatch
sudo cp infra/scripts/t3-dispatch.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now t3-dispatch.service
```
- [ ] **Step 5: Verify routing + auto-pair locally (before Task 5 sudoers, expect mint to 500; after Task 5, 302):**
Run:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3780/healthz                                   # 200
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-authentik-username: nobody' http://localhost:3780/        # 403
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-authentik-username: vbarzin' http://localhost:3780/        # 302 (after Task 5)
```
Expected (post-Task-5): healthz 200, unmapped 403, mapped-no-cookie 302 with Set-Cookie.
- [ ] **Step 6: Commit** `t3-dispatch/` + `infra/scripts/t3-dispatch.service`: `t3code: devvm dispatch + auto-pair service`.

---

## Task 5: Scoped sudoers

**Files:** Create `infra/scripts/sudoers-t3-autopair` → deploy `/etc/sudoers.d/t3-autopair` (mode 0440).

- [ ] **Step 1: Write the sudoers fragment** (modeled on `/etc/sudoers.d/ttyd-users`):
```
# t3-dispatch (runs as wizard) may mint per-user t3 pairing tokens only.
wizard ALL=(%i) NOPASSWD: /usr/bin/t3 auth pairing create --base-dir /home/*/.t3 --ttl 5m --json
```
(If `Runas_Alias`/per-user form is needed, enumerate: `wizard ALL=(wizard,emo) NOPASSWD: /usr/bin/t3 auth pairing create *`.)
- [ ] **Step 2: Deploy + validate syntax:**
```bash
sudo install -m 0440 infra/scripts/sudoers-t3-autopair /etc/sudoers.d/t3-autopair
sudo visudo -cf /etc/sudoers.d/t3-autopair       # expect: parsed OK
```
- [ ] **Step 3: Verify the dispatch service can now mint (re-run Task 4 Step 5 mapped case):** expect `vbarzin` → 302 + `Set-Cookie`.
- [ ] **Step 4: Commit** `infra/scripts/sudoers-t3-autopair`: `t3code: scoped sudoers for dispatch auto-pair`.

---

## Task 6: Terraform — repoint `stacks/t3code` at the devvm dispatcher

**Files:** Modify `stacks/t3code/main.tf`.

- [ ] **Step 1: Remove** the in-cluster nginx (`kubernetes_config_map_v1.t3_dispatch`, `kubernetes_deployment_v1.t3_dispatch`, `kubernetes_service_v1.t3_dispatch`, the `locals.t3_dispatch_nginx_conf`). **Add** a `kubernetes_service` `t3` (port 80) + `kubernetes_endpoints` `t3` → `10.0.10.10:3780`. Keep `module.ingress` `auth = "required"`, `service_name = "t3"`.
- [ ] **Step 2: Plan** — expect: 3 nginx resources destroyed, service+endpoints created, ingress backend `t3-dispatch`→`t3`:
```bash
cd stacks/t3code && ../../scripts/tg plan 2>&1 | grep -E 'will be|^Plan:'
```
- [ ] **Step 3: Claim presence + apply:**
```bash
~/code/scripts/presence claim stack:t3code --purpose "repoint t3 ingress at devvm dispatch+autopair"
cd stacks/t3code && ../../scripts/tg apply --non-interactive
```
- [ ] **Step 4: Verify live end-to-end:**
```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://t3.viktorbarzin.me/    # 302 → Authentik (gate intact)
```
Then a real browser login as Viktor → lands in wizard's workspace, WS connects, no manual pairing. (Cannot be fully curl-tested without an Authentik session — confirm in-browser.)
- [ ] **Step 5: Commit** `stacks/t3code/main.tf`: `t3code: ingress → devvm dispatch+autopair (retire in-cluster nginx)`.

---

## Task 7: Docs, memory, push

- [ ] **Step 1:** Update `.claude/reference/service-catalog.md` t3code row: dispatcher is now the devvm `t3-dispatch` service (+ auto-pair); add-a-user = one `/etc/ttyd-user-map` line → reconcile.
- [ ] **Step 2:** Update design doc status → `implemented`. Append the Task 1 discovered auth-contract note if not already.
- [ ] **Step 3:** `memory_update` id 3085 (dispatcher: in-cluster nginx → devvm t3-dispatch + auto-pair + reconcile).
- [ ] **Step 4:** Commit docs; push all commits to `origin/master`. If the shared working tree is dirty from another session, push via the git-crypt-disabled detached worktree (see memory ids 3533-3535). Wait for Woodpecker CI on `stacks/t3code`.

---

## Self-review notes
- **Spec coverage:** source-of-truth (T3) ✓ Task 3; file-perm enforcement (User=%i) ✓ Task 2; reconcile ✓ Task 3; dispatch+auto-pair ✓ Task 4; sudoers ✓ Task 5; TF shrink ✓ Task 6; reboot persistence (units enabled) ✓ Task 2/3. Out-of-scope items not implemented (correct).
- **Discovery-dependent:** the dispatch service's `cookieName` + bootstrap body are placeholders resolved in Task 1 before Task 4 coding — flagged inline, not left vague.
- **Ports:** instances 3773+ (sticky), dispatcher fixed 3780 — consistent across Tasks 2/3/4/6.
