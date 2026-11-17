# Runs inside a LAPI pod (sh -s, from the crowdsec-lapi-reconcile CronJob).
# The CronJob prepends OPNSENSE_AGENT_PASSWORD=... and JOURNALS_AGENT_PASSWORD=...
# on stdin, so the passwords never appear in a command line the Kubernetes API
# records.
# 1. Allowlist "trusted-infra" = exactly the values in /tmp/allowlist.txt
#    (value<TAB>comment per line, written by the CronJob before this runs),
#    plus the current IPv4 of each name in /tmp/allowlist-dns.txt
#    (name<TAB>comment). A name that does not resolve stops the run before
#    the list changes, so the address from the last good run stays.
# 2. The OPNsense edge firewall's agent is a registered machine.
# 3. The server journals agent (crowdsec-journals Deployment) is a registered machine.
set -eu
LIST=trusted-infra
WANT=/tmp/allowlist.txt

if ! cscli allowlists inspect "$LIST" >/dev/null 2>&1; then
  cscli allowlists create "$LIST" -d "Our own addresses; LAPI never bans them (stacks/crowdsec lapi_allowlist)"
fi

dynamic=""
while IFS="$(printf '\t')" read -r name comment; do
  [ -n "$name" ] || continue
  ip=$(getent ahostsv4 "$name" | awk 'NR == 1 {print $1}')
  [ -n "$ip" ] || { echo "cannot resolve $name, allowlist left unchanged" >&2; exit 1; }
  printf '%s\t%s (%s)\n' "$ip" "$comment" "$name" >> "$WANT"
  dynamic="$dynamic $ip"
done < /tmp/allowlist-dns.txt

# -o raw columns: name,description,value,comment,...; the value is the third.
have=$(cscli allowlists inspect "$LIST" -o raw 2>/dev/null | awk -F, 'NR > 1 && $3 != "" {print $3}')
added=0
while IFS="$(printf '\t')" read -r value comment; do
  [ -n "$value" ] || continue
  if ! printf '%s\n' "$have" | grep -qxF "$value"; then
    cscli allowlists add "$LIST" "$value" -d "$comment" >/dev/null
    added=$((added + 1))
  fi
done < "$WANT"
removed=0
for value in $have; do
  if ! cut -f1 "$WANT" | grep -qxF "$value"; then
    cscli allowlists remove "$LIST" "$value" >/dev/null
    removed=$((removed + 1))
  fi
done
echo "allowlist $LIST: $(cut -f1 "$WANT" | grep -c .) wanted, $added added, $removed removed"
# A dynamic address can be banned before it reaches the list: clear it.
for ip in $dynamic; do
  cscli decisions delete --ip "$ip" >/dev/null 2>&1 || true
  echo "dynamic $ip allowlisted"
done

# --force keeps the password in step with Vault; -f /dev/null keeps cscli from
# writing credentials into this pod.
cscli machines add opnsense-edge --password "$OPNSENSE_AGENT_PASSWORD" --force -f /dev/null >/dev/null
echo "machine opnsense-edge registered"
cscli machines add journals --password "$JOURNALS_AGENT_PASSWORD" --force -f /dev/null >/dev/null
echo "machine journals registered"
