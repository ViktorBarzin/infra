# Liveness and readiness command of the redis container (main.tf), run with
# sh -c. It logs in as the ACL user probe (+ping only) so that the kubelet's
# connections do not count as default clients (B40 R2, R3 count). The
# password comes from the env REDIS_PROBE_PASSWORD and reaches redis-cli as
# REDISCLI_AUTH, never in argv. After a refused AUTH (wrong or empty
# password) redis-cli carries on as default, and it exits 0 on any reply,
# error replies too (LOADING, NOAUTH). So the probe checks only that Redis
# answers, the same as the plain `redis-cli PING` it replaces, and a password
# problem never fails it: a liveness probe that failed on one would restart
# Redis. The login itself shows in CLIENT LIST (user=probe) and in
# redis_acl_access_denied_auth_total.
REDISCLI_AUTH="$REDIS_PROBE_PASSWORD" exec redis-cli --no-auth-warning --user probe PING
