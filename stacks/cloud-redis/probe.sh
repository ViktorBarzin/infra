# Liveness and readiness of cloud-redis, Cloud's Key Value Redis (B27 option
# b). PING as the probe user, password from REDIS_PROBE_PASSWORD. Unlike
# stacks/redis's probe.sh, a BUSY reply fails: a tenant's endless script
# makes Redis answer BUSY to everyone, and only a restart ends it (tenants
# cannot SCRIPT KILL). LOADING passes, so a restart that reads the AOF is not
# killed again. Any other reply passes too, so a probe password the sync has
# not applied yet cannot restart Redis; no answer or no connection fails.
out=$(REDISCLI_AUTH="$REDIS_PROBE_PASSWORD" redis-cli --no-auth-warning --user probe PING 2>&1) || { echo "$out"; exit 1; }
case "$out" in
  *BUSY*) echo "$out"; exit 1 ;;
esac
exit 0
