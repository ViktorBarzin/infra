#!/bin/sh
# Init container of redis-v2 (B40 R1). Redis does not start when its aclfile
# is missing, so this writes the first one from the seed (the default user,
# unchanged for clients, and acl-admin for redis-acl-sync). A file that is
# already there is kept, because redis-acl-sync owns it after the first
# minute; only its acl-admin line is replaced from the seed, so the sync can
# always log in after acl-admin's password changes or the users were
# recreated. Paths can be overridden for the offline test.
set -eu
dir=${ACL_DIR:-/data/acl}
file=$dir/users.acl
seed=${ACL_SEED:-/seed/users.acl}

# Cloud Key Value tenants (B27): a tenant line carries a module part (the
# sync's MODULE_DENIALS in acl_sync.py) only while that module is loaded,
# and redis-server refuses an aclfile that names a command or category it
# does not know. So every start rewrites the tenant lines (user p_*; no infra
# user has an underscore) to match the modules this redis-server will load:
# loadmodule lines of its config file, and --loadmodule in its arguments
# (REDIS_ARGS, set by main.tf from the redis container's own command).
conf=${REDIS_CONF:-/etc/redis/redis.conf}
modules="$( { [ -r "$conf" ] && sed -n 's/^[[:space:]]*loadmodule[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$conf"
  printf '%s\n' "${REDIS_ARGS:-}" | awk '{ for (i = 1; i < NF; i++) if ($i == "--loadmodule") print $(i + 1) }'; } )"
extra=""
case "$modules" in *redisearch*) extra="-@search" ;; esac
case "$modules" in *redistimeseries*) extra="${extra:+$extra }-ts.mget -ts.mrange -ts.mrevrange -ts.queryindex -ts.querylabels" ;; esac
tenant_modules() {
  awk -v extra="$extra" '
    /^user p_[a-z0-9_]+ / {
      n = split($0, t, " ")
      while (n > 0 && (t[n] == "-@search" || t[n] ~ /^-ts\.(mget|mrange|mrevrange|queryindex|querylabels)$/)) n--
      line = t[1]
      for (i = 2; i <= n; i++) line = line " " t[i]
      if (extra != "") line = line " " extra
      print line
      next
    }
    { print }'
}

grep -q '^user default ' "$seed"
admin_line=$(grep '^user acl-admin ' "$seed")
mkdir -p "$dir"
if [ -s "$file" ]; then
  { grep -v '^user acl-admin ' "$file" || true; printf '%s\n' "$admin_line"; } > "$file.init-tmp"
  echo "kept $file, refreshed its acl-admin line"
else
  cp "$seed" "$file.init-tmp"
  echo "seeded $file"
fi
tenant_modules <"$file.init-tmp" >"$file.init-mods"
rm -f "$file.init-tmp"
echo "tenant lines: module part '${extra}'"
mv "$file.init-mods" "$file"
