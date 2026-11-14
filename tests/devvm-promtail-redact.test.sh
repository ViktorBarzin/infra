#!/usr/bin/env bash
# Runs the masking stages of scripts/devvm-promtail.yaml through the pinned
# promtail binary (-stdin -dry-run) and checks what would reach Loki.
#
# Why: the devvm's journal ships to Loki, which any client on the LAN can
# read without logging in, and sudo logs every command line it runs. On
# 2026-11-11 wizard's admin Vault token reached Loki through `sudo
# VAULT_TOKEN=...` lines (ENV=VAULT_TOKEN=<value> in sudo's own log line). The
# same file also carries every agent shell command, through systemd's
# "Started run-<id>.scope - /bin/zsh -c ..." lines. The fix is masking in the
# shipper, the same approach as the Proxmox host (infra 3b413944).
#
# Each scrape job is rebuilt as a stdin job with its own pipeline_stages, so
# the test exercises the exact stages the box runs. Fake secrets are built at
# runtime so no secret-shaped literal sits in this file.
#
# Needs: /usr/local/bin/promtail (playbooks/devvm.yml pins it), python3 + pyyaml.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$HERE/scripts/devvm-promtail.yaml"
PLAYBOOK="$HERE/playbooks/devvm.yml"
PROMTAIL="${PROMTAIL:-/usr/local/bin/promtail}"

pass=0; fail=0
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
good() { pass=$((pass+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

rep() { local s; printf -v s "%${2}s" ""; printf '%s' "${s// /$1}"; }

# ---- fake secrets ------------------------------------------------------------
VT="hv""s.CAES$(rep Q 40)Fake$(rep 7 20)"     # Vault service token
VB="hv""b.AAAA$(rep x 60)_-fake"                # Vault batch token
VS="s.$(rep K 12)$(rep 4 12)"                   # legacy Vault token, 24 chars
GH="gh""p_$(rep Z 36)"                          # GitHub classic PAT
GP="github""_pat_$(rep 1 22)_$(rep y 59)"       # GitHub fine-grained PAT
FJ="$(rep a 20)$(rep 9 20)"                     # Forgejo token: 40 hex chars
AK="AK""IA$(rep F 16)"                          # AWS access key id
AS="$(rep w 20)/$(rep R 19)"                    # AWS secret key, 40 chars
JW="ey""J$(rep h 20).ey""J$(rep p 30).$(rep s 30)"
OP="$(rep o 32)"                                # opaque bearer token
PW="Pw$(rep d 10)!x"                            # a password
KEYBODY="b3Blbn$(rep N 40)"
D5="-----"; PK="PRIV""ATE KEY"                  # key block markers, split for gitleaks
OB="${D5}BEGIN OPENSSH $PK$D5"; OE="${D5}END OPENSSH $PK$D5"; RB="${D5}BEGIN RSA $PK$D5"

# ---- cases for the journal job: input line, then expected line ---------------
# A sudo line keeps TTY, PWD, USER and COMMAND; only the value goes.
CASES=(
  "  wizard : TTY=pts/3 ; PWD=/home/wizard/code/infra ; USER=root ; ENV=VAULT_TOKEN=$VT ; COMMAND=/usr/bin/vault status"
  "  wizard : TTY=pts/3 ; PWD=/home/wizard/code/infra ; USER=root ; ENV=VAULT_TOKEN=[REDACTED] ; COMMAND=/usr/bin/vault status"

  "  wizard : PWD=/home/wizard ; USER=root ; ENV=MY_DB_PASSWORD=$PW GITHUB_TOKEN=$GH SESSIONKEY=$OP ; COMMAND=/usr/bin/env"
  "  wizard : PWD=/home/wizard ; USER=root ; ENV=MY_DB_PASSWORD=[REDACTED] GITHUB_TOKEN=[REDACTED] SESSIONKEY=[REDACTED] ; COMMAND=/usr/bin/env"

  "  wizard : PWD=/home/wizard ; USER=root ; ENV=VAULT_ADDR=https://vault.viktorbarzin.me ; COMMAND=/usr/bin/vault status"
  "  wizard : PWD=/home/wizard ; USER=root ; ENV=VAULT_ADDR=https://vault.viktorbarzin.me ; COMMAND=/usr/bin/vault status"

  "  wizard : PWD=/home/wizard ; USER=root ; COMMAND=/usr/bin/grep -rlF $VT /etc /opt"
  "  wizard : PWD=/home/wizard ; USER=root ; COMMAND=/usr/bin/grep -rlF [REDACTED] /etc /opt"

  "  wizard : USER=root ; COMMAND=/usr/bin/env --preserve-env=VAULT_TOKEN vault status"
  "  wizard : USER=root ; COMMAND=/usr/bin/env --preserve-env=VAULT_TOKEN vault status"

  "Started run-p123.scope - /bin/zsh -c \"eval 'export VAULT_TOKEN=$VT && vault kv get secret/x'\""
  "Started run-p123.scope - /bin/zsh -c \"eval 'export VAULT_TOKEN=[REDACTED] && vault kv get secret/x'\""

  "batch $VB ok"
  "batch [REDACTED] ok"

  "old token $VS revoked"
  "old token [REDACTED] revoked"

  "unpacked archive.s.tar.gz into /var/tmp/s.cache"
  "unpacked archive.s.tar.gz into /var/tmp/s.cache"

  "gh auth login with $GH and $GP done"
  "gh auth login with [REDACTED] and [REDACTED] done"

  "git clone https://viktor:$FJ@forgejo.viktorbarzin.me/viktor/infra.git"
  "git clone https://viktor:[REDACTED]@forgejo.viktorbarzin.me/viktor/infra.git"

  "curl -H 'Authorization: token $FJ' https://forgejo.viktorbarzin.me/api/v1/user"
  "curl -H 'Authorization: token [REDACTED]' https://forgejo.viktorbarzin.me/api/v1/user"

  "curl -H \"Authorization: Bearer $OP\" https://x"
  "curl -H \"Authorization: Bearer [REDACTED]\" https://x"

  "curl -H 'X-API-Key: $OP' -H 'X-Vault-Token: $OP' https://x"
  "curl -H 'X-API-Key: [REDACTED]' -H 'X-Vault-Token: [REDACTED]' https://x"

  "sent header Bearer $OP upstream"
  "sent header Bearer [REDACTED] upstream"

  "curl -u viktor:$FJ https://forgejo.viktorbarzin.me/api/v1/user"
  "curl -u viktor:[REDACTED] https://forgejo.viktorbarzin.me/api/v1/user"

  "aws key $AK AWS_SECRET_ACCESS_KEY=$AS"
  "aws key [REDACTED] AWS_SECRET_ACCESS_KEY=[REDACTED]"

  "printf '$OB\\n$KEYBODY\\n$OE\\n' > k"
  "printf '$OB[REDACTED]$OE\\n' > k"

  "cat <<EOF $RB $KEYBODY"
  "cat <<EOF $RB[REDACTED]"

  "jwt $JW end"
  "jwt [REDACTED] end"

  "GET /cb?code=1&password=$PW&user=viktor"
  "GET /cb?code=1&password=[REDACTED]&user=viktor"

  "tool --token=$OP --password \"$PW\" --verbose"
  "tool --token=[REDACTED] --password \"[REDACTED]\" --verbose"

  "{\"access_token\":\"$OP\",\"token_type\":\"bearer\",\"expires_in\":300}"
  "{\"access_token\":\"[REDACTED]\",\"token_type\":\"bearer\",\"expires_in\":300}"

  "mysql -h mysql.dbaas -u root -p$PW -e 'select 1'"
  "mysql -h mysql.dbaas -u root -p[REDACTED] -e 'select 1'"

  # Lines Loki rules and dashboards read stay as they are.
  "2026/11/08 10:55:48 agent-api: auth: invalid bearer token (GET /v1/tasks)"
  "2026/11/08 10:55:48 agent-api: auth: invalid bearer token (GET /v1/tasks)"

  "Accepted publickey for wizard from 10.0.10.1 port 50022 ssh2: ED25519 SHA256:$(rep Y 43)"
  "Accepted publickey for wizard from 10.0.10.1 port 50022 ssh2: ED25519 SHA256:$(rep Y 43)"

  "HEAD is now at $(rep 9 20)$(rep b 20) homepage: bump"
  "HEAD is now at $(rep 9 20)$(rep b 20) homepage: bump"

  "TLEVENT {\"event.name\":\"conn.opened\",\"attrs\":{\"tl.token_ms\":12,\"tl.key\":\"k\"}}"
  "TLEVENT {\"event.name\":\"conn.opened\",\"attrs\":{\"tl.token_ms\":12,\"tl.key\":\"k\"}}"
)

# ---- rebuild each scrape job as a stdin job ----------------------------------
python3 - "$CONFIG" "$TMP" <<'PY' || { echo "FAIL: could not parse $CONFIG"; exit 1; }
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
names = []
for sc in cfg["scrape_configs"]:
    name = sc["job_name"]
    names.append(name)
    stdin_cfg = {
        "server": {"disable": True},
        "positions": {"filename": out + "/positions-" + name + ".yaml"},
        "clients": [{"url": "http://127.0.0.1:1/loki/api/v1/push"}],
        "scrape_configs": [{
            "job_name": name,
            "static_configs": [{"targets": ["localhost"], "labels": {"job": name}}],
            "pipeline_stages": sc.get("pipeline_stages", []),
        }],
    }
    yaml.safe_dump(stdin_cfg, open(f"{out}/job-{name}.yaml", "w"))
open(out + "/jobs", "w").write("\n".join(names) + "\n")
PY

# Every job's last stage is the shared masking stage, so a job added later
# cannot ship unmasked lines without this test noticing.
python3 - "$CONFIG" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
stages = [sc.get("pipeline_stages") or [] for sc in cfg["scrape_configs"]]
first_last = stages[0][-1] if stages[0] else None
bad = 0
if not first_last or "match" not in first_last:
    print("FAIL: the first scrape job does not end with the masking match stage"); bad = 1
for sc, st in zip(cfg["scrape_configs"], stages):
    if not st or st[-1] != first_last:
        print(f"FAIL: scrape job {sc['job_name']} does not end with the shared masking stage"); bad = 1
sys.exit(bad)
PY
if [ $? -eq 0 ]; then good; else fail=$((fail+1)); fi

# Dry-run prints "<timestamp><padding>{labels}<TAB><line>"; the line body is
# what Loki would store. In -stdin mode promtail can exit before it has printed
# the last entries (about 1 run in 3 lost a one-line input, measured with
# 3.5.1), so 200 filler lines follow the input and are dropped from the output.
FILLER='{"ts":"2026-11-11T00:00:00.000Z","trace_id":"zz-filler"}'
run_job() {  # run_job <job> <input-file> -> line bodies on stdout, in order
  { cat "$2"; for _ in $(seq 200); do printf '%s\n' "$FILLER"; done; } \
    | timeout 60 "$PROMTAIL" -config.file "$TMP/job-$1.yaml" -stdin -dry-run -log.level=error 2>/dev/null \
    | sed -n -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^{]*\{[^}]*\}\t//p' \
    | grep -v -F 'zz-filler'
}

# ---- journal job -------------------------------------------------------------
: >"$TMP/in"; : >"$TMP/want"
for ((i=0; i<${#CASES[@]}; i+=2)); do
  printf '%s\n' "${CASES[i]}" >>"$TMP/in"
  printf '%s\n' "${CASES[i+1]}" >>"$TMP/want"
done
run_job journal "$TMP/in" >"$TMP/got"
n_want=$(wc -l <"$TMP/want"); n_got=$(wc -l <"$TMP/got")
if [ "$n_want" != "$n_got" ]; then
  bad "journal job: sent $n_want lines, promtail printed $n_got"
else
  i=0
  while IFS= read -r want <&3 && IFS= read -r got <&4; do
    i=$((i+1))
    if [ "$want" == "$got" ]; then good; else
      bad "journal case $i"; echo "  want: $want"; echo "  got:  $got"
    fi
  done 3<"$TMP/want" 4<"$TMP/got"
fi

# No fake secret survives anywhere in the journal output.
for s in "$VT" "$VB" "$VS" "$GH" "$GP" "$FJ" "$AK" "$AS" "$JW" "$OP" "$PW" "$KEYBODY"; do
  if grep -qF -- "$s" "$TMP/got"; then bad "a fake secret (${s:0:4}...) reached the journal output"; else good; fi
done

# ---- agent-api-trace job: the masking runs after the projection ---------------
printf '%s\n' "{\"ts\":\"2026-11-11T10:00:00.000Z\",\"trace_id\":\"t1\",\"actor\":\"muse\",\"verb\":\"delegation.update\",\"event\":\"delegation.undelivered\",\"reason\":\"key $GH was pasted\",\"status\":200,\"request\":{\"text\":\"secret $VT\"}}" >"$TMP/trace-in"
run_job agent-api-trace "$TMP/trace-in" >"$TMP/trace-got"
if grep -qF '"reason":"key [REDACTED] was pasted"' "$TMP/trace-got"; then good; else bad "trace reason not masked: $(cat "$TMP/trace-got")"; fi
if grep -qF '"actor":"muse"' "$TMP/trace-got"; then good; else bad "trace projection lost the actor field"; fi
if grep -qF -e "$GH" -e "$VT" "$TMP/trace-got"; then bad "a fake secret reached the trace output"; else good; fi

# ---- the real file passes promtail's own check, and the playbook checks it ----
if "$PROMTAIL" -check-syntax -config.file "$CONFIG" >/dev/null 2>&1; then good; else bad "promtail -check-syntax rejects $CONFIG"; fi
python3 - "$PLAYBOOK" <<'PY'
import sys, yaml
def walk(n):
    if isinstance(n, list):
        for x in n: yield from walk(x)
    elif isinstance(n, dict):
        yield n
        for k in ("tasks", "block", "rescue", "always", "handlers"):
            if k in n: yield from walk(n[k])
for t in walk(yaml.safe_load(open(sys.argv[1]))):
    if t.get("name") == "Deploy the promtail config":
        v = (t.get("ansible.builtin.copy") or {}).get("validate", "")
        sys.exit(0 if "-check-syntax" in v else 1)
sys.exit(1)
PY
if [ $? -eq 0 ]; then good; else bad "playbook does not validate the promtail config before deploying it"; fi

echo "devvm-promtail-redact: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
