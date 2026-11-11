CREATE DATABASE IF NOT EXISTS claude;

-- One row per transcript line. The ingester sends only where the line came
-- from plus the line itself (raw); every other column is computed here from
-- raw, so a format change is fixed in SQL, not by re-ingesting.
CREATE TABLE IF NOT EXISTS claude.lines
(
    os_user       LowCardinality(String),
    project       LowCardinality(String),
    session_id    String,
    agent_id      String,
    file          String,
    byte_offset   UInt64,
    raw           String CODEC(ZSTD(3)),
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3),
    -- last timestamp the ingester saw earlier in the same file, for records
    -- that carry none of their own (mode, last-prompt, permission-mode)
    ts_hint       DateTime64(3, 'UTC') DEFAULT ingested_at,

    type          LowCardinality(String) DEFAULT JSONExtractString(raw, 'type'),
    subtype       LowCardinality(String) DEFAULT if(type = 'attachment', JSONExtractString(raw, 'attachment', 'type'), JSONExtractString(raw, 'subtype')),
    ts            DateTime64(3, 'UTC') DEFAULT coalesce(
        parseDateTime64BestEffortOrNull(JSONExtractString(raw, 'timestamp'), 3, 'UTC'),
        parseDateTime64BestEffortOrNull(JSONExtractString(raw, 'snapshot', 'timestamp'), 3, 'UTC'),
        if(JSONHas(raw, 'startTime'), fromUnixTimestamp64Milli(JSONExtractInt(raw, 'startTime'), 'UTC'), NULL),
        ts_hint),
    has_own_ts    Bool DEFAULT JSONHas(raw, 'timestamp'),
    uuid          String DEFAULT JSONExtractString(raw, 'uuid'),
    parent_uuid   String DEFAULT JSONExtractString(raw, 'parentUuid'),
    cwd           String DEFAULT JSONExtractString(raw, 'cwd'),
    git_branch    String DEFAULT JSONExtractString(raw, 'gitBranch'),
    version       LowCardinality(String) DEFAULT JSONExtractString(raw, 'version'),
    entrypoint    LowCardinality(String) DEFAULT JSONExtractString(raw, 'entrypoint'),
    is_sidechain  Bool DEFAULT JSONExtractBool(raw, 'isSidechain'),
    is_meta       Bool DEFAULT JSONExtractBool(raw, 'isMeta'),
    prompt_origin LowCardinality(String) DEFAULT JSONExtractString(raw, 'origin', 'kind'),
    is_tool_result Bool DEFAULT JSONHas(raw, 'toolUseResult'),
    model         LowCardinality(String) DEFAULT JSONExtractString(raw, 'message', 'model'),
    input_tokens          UInt64 DEFAULT JSONExtractUInt(raw, 'message', 'usage', 'input_tokens'),
    output_tokens         UInt64 DEFAULT JSONExtractUInt(raw, 'message', 'usage', 'output_tokens'),
    thinking_tokens       UInt64 DEFAULT JSONExtractUInt(raw, 'message', 'usage', 'output_tokens_details', 'thinking_tokens'),
    cache_read_tokens     UInt64 DEFAULT JSONExtractUInt(raw, 'message', 'usage', 'cache_read_input_tokens'),
    cache_creation_tokens UInt64 DEFAULT JSONExtractUInt(raw, 'message', 'usage', 'cache_creation_input_tokens'),
    duration_ms   UInt64 DEFAULT if(type = 'attachment', JSONExtractUInt(raw, 'attachment', 'durationMs'), JSONExtractUInt(raw, 'durationMs'))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (os_user, session_id, ts, byte_offset)
SETTINGS non_replicated_deduplication_window = 100000;

-- One row per message content block: prompts, replies, thinking, tool calls
-- and tool results. Filled by blocks_mv from lines; rebuildable from lines.
CREATE TABLE IF NOT EXISTS claude.blocks
(
    os_user      LowCardinality(String),
    project      LowCardinality(String),
    session_id   String,
    agent_id     String,
    byte_offset  UInt64,
    block_index  UInt16,
    ts           DateTime64(3, 'UTC'),
    role         LowCardinality(String),
    is_tool_result_line Bool,
    prompt_origin LowCardinality(String),
    kind         LowCardinality(String),
    tool_name    LowCardinality(String),
    tool_use_id  String,
    is_error     Bool,
    text         String CODEC(ZSTD(3)),
    INDEX text_idx text TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(text))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (os_user, session_id, ts, byte_offset, block_index)
SETTINGS non_replicated_deduplication_window = 100000;

-- DEFINER: the view writes blocks with the admin's rights, so the ingest
-- user needs INSERT on lines only. Without it an insert by ingest lands in
-- lines and then fails in the view, leaving blocks behind.
CREATE MATERIALIZED VIEW IF NOT EXISTS claude.blocks_mv TO claude.blocks
DEFINER = default SQL SECURITY DEFINER
AS
WITH
    JSONType(raw, 'message', 'content') = 'String' AS is_plain,
    if(is_plain,
       [concat('{"type":"text","text":', JSONExtractRaw(raw, 'message', 'content'), '}')],
       JSONExtractArrayRaw(raw, 'message', 'content')) AS content
SELECT
    os_user, project, session_id, agent_id, byte_offset,
    toUInt16(idx - 1) AS block_index,
    ts,
    type AS role,
    is_tool_result AS is_tool_result_line,
    prompt_origin,
    JSONExtractString(b, 'type') AS kind,
    JSONExtractString(b, 'name') AS tool_name,
    if(kind = 'tool_use', JSONExtractString(b, 'id'), JSONExtractString(b, 'tool_use_id')) AS tool_use_id,
    JSONExtractBool(b, 'is_error') AS is_error,
    multiIf(
        kind = 'text', JSONExtractString(b, 'text'),
        kind = 'thinking', JSONExtractString(b, 'thinking'),
        kind = 'tool_use', JSONExtractRaw(b, 'input'),
        kind = 'tool_result',
            if(JSONType(b, 'content') = 'String',
               JSONExtractString(b, 'content'),
               arrayStringConcat(arrayMap(x -> JSONExtractString(x, 'text'), JSONExtractArrayRaw(b, 'content')), '\n')),
        '') AS text
FROM claude.lines
ARRAY JOIN content AS b, arrayEnumerate(content) AS idx
WHERE type IN ('user', 'assistant');

-- Side files: tool-results/*.txt (large tool outputs) and
-- subagents/*.meta.json. Replaced when a file changes.
CREATE TABLE IF NOT EXISTS claude.files
(
    os_user     LowCardinality(String),
    project     LowCardinality(String),
    session_id  String,
    path        String,
    kind        LowCardinality(String),
    mtime       DateTime64(3, 'UTC'),
    content     String CODEC(ZSTD(3)),
    INDEX content_idx content TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(content))
)
ENGINE = ReplacingMergeTree(mtime)
ORDER BY (os_user, session_id, path);

-- One row per API request. Claude Code writes one transcript line per content
-- block and repeats the message's usage on each, so token sums must come from
-- here, never from summing lines (that inflates them about 2.5x).
CREATE VIEW IF NOT EXISTS claude.requests AS
SELECT
    os_user,
    any(project) AS project,
    session_id,
    agent_id,
    JSONExtractString(raw, 'requestId') AS request_id,
    min(ts) AS ts,
    any(model) AS model,
    max(input_tokens) AS input_tokens,
    max(output_tokens) AS output_tokens,
    max(thinking_tokens) AS thinking_tokens,
    max(cache_read_tokens) AS cache_read_tokens,
    max(cache_creation_tokens) AS cache_creation_tokens
FROM claude.lines
WHERE type = 'assistant' AND JSONExtractString(raw, 'requestId') != ''
GROUP BY os_user, session_id, agent_id, request_id;

-- One row per session; subagent requests are included in the token sums.
-- cost_usd sums the last cost-state of each Claude Code process (resuming
-- starts a new process). It is final once the session has exited; for a
-- running session it is the last snapshot Claude Code wrote, which can lag.
CREATE VIEW IF NOT EXISTS claude.sessions AS
SELECT s.*, r.api_requests, r.input_tokens, r.output_tokens, r.thinking_tokens,
       r.cache_read_tokens, r.cache_creation_tokens
FROM
(
    SELECT
        os_user,
        session_id,
        any(project) AS project,
        anyIf(cwd, cwd != '') AS cwd,
        anyIf(git_branch, git_branch != '') AS git_branch,
        minIf(ts, has_own_ts) AS started,
        maxIf(ts, has_own_ts) AS ended,
        dateDiff('second', started, ended) AS wall_seconds,
        countIf(type = 'user' AND agent_id = '' AND NOT is_tool_result AND NOT is_meta) AS prompts,
        countIf(type = 'user' AND agent_id = '' AND prompt_origin = 'human') AS human_prompts,
        uniqExactIf(agent_id, agent_id != '') AS subagents,
        countIf(type = 'system' AND subtype = 'compact_boundary') AS compactions,
        arraySum(maxMapIf([JSONExtractInt(raw, 'startTime')], [JSONExtractFloat(raw, 'totalCostUSD')], type = 'cost-state' AND agent_id = '').2) AS cost_usd,
        groupUniqArrayIf(model, model != '' AND model != '<synthetic>') AS models,
        anyIf(version, version != '') AS claude_version
    FROM claude.lines
    GROUP BY os_user, session_id
) AS s
LEFT JOIN
(
    SELECT
        os_user,
        session_id,
        count() AS api_requests,
        sum(input_tokens) AS input_tokens,
        sum(output_tokens) AS output_tokens,
        sum(thinking_tokens) AS thinking_tokens,
        sum(cache_read_tokens) AS cache_read_tokens,
        sum(cache_creation_tokens) AS cache_creation_tokens
    FROM claude.requests
    GROUP BY os_user, session_id
) AS r USING (os_user, session_id);

-- One row per session and model. cost-state's modelUsage is cumulative per
-- Claude Code process, so take each process's maximum and sum the processes,
-- as sessions.cost_usd does for the total. Use this for spend per model:
-- sessions.models lists every model a session used, so arrayJoin(models)
-- would credit the whole session's cost to each of them.
CREATE VIEW IF NOT EXISTS claude.model_costs AS
SELECT
    os_user,
    session_id,
    model,
    min(process_started) AS started,
    sum(cost) AS cost_usd,
    sum(input) AS input_tokens,
    sum(output) AS output_tokens,
    sum(cache_read) AS cache_read_tokens,
    sum(cache_creation) AS cache_creation_tokens
FROM
(
    SELECT
        os_user,
        session_id,
        mu.1 AS model,
        JSONExtractInt(raw, 'startTime') AS process_start,
        fromUnixTimestamp64Milli(process_start, 'UTC') AS process_started,
        max(JSONExtractFloat(mu.2, 'costUSD')) AS cost,
        max(JSONExtractUInt(mu.2, 'inputTokens')) AS input,
        max(JSONExtractUInt(mu.2, 'outputTokens')) AS output,
        max(JSONExtractUInt(mu.2, 'cacheReadInputTokens')) AS cache_read,
        max(JSONExtractUInt(mu.2, 'cacheCreationInputTokens')) AS cache_creation
    FROM claude.lines
    ARRAY JOIN JSONExtractKeysAndValuesRaw(raw, 'modelUsage') AS mu
    WHERE type = 'cost-state' AND agent_id = ''
    GROUP BY os_user, session_id, model, process_start
)
GROUP BY os_user, session_id, model;

-- One row per finished turn, from Claude Code's turn_duration records.
CREATE VIEW IF NOT EXISTS claude.turns AS
SELECT
    os_user, project, session_id, agent_id, ts,
    duration_ms,
    JSONExtractUInt(raw, 'messageCount') AS message_count
FROM claude.lines
WHERE type = 'system' AND subtype = 'turn_duration';

-- ===== netsec ===============================================================
-- What the network IDS records (docs/plans/2026-11-10-network-ids.md,
-- docs/architecture/network-security-monitoring.md). Written by the netsec
-- Vector (stacks/netsec) as netsec_writer; read by Viktor as netsec_reader.
-- Not in backup.sh on purpose: browsing data stays off NFS and offsite.
-- Addresses are IPv6 columns; IPv4 arrives as text and is stored mapped.
CREATE DATABASE IF NOT EXISTS netsec;

-- One row per NetFlow record from OPNsense (lan, opt1) via goflow2. 365 days.
CREATE TABLE IF NOT EXISTS netsec.flows
(
    ts        DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    ts_start  DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    received  DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    exporter  LowCardinality(String),
    src_ip    IPv6,
    dst_ip    IPv6,
    src_port  UInt16,
    dst_port  UInt16,
    proto     LowCardinality(String),
    etype     LowCardinality(String),
    bytes     UInt64 CODEC(T64, ZSTD(1)),
    packets   UInt64 CODEC(T64, ZSTD(1)),
    tcp_flags UInt16,
    in_if     UInt32,
    out_if    UInt32,
    next_hop  LowCardinality(String),
    src_net   LowCardinality(String),
    dst_net   LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (toStartOfHour(ts), src_ip, dst_ip, ts)
TTL toDateTime(ts) + INTERVAL 365 DAY DELETE
SETTINGS ttl_only_drop_parts = 1;

-- Suricata EVE events (alert, dns, tls, http, ssh). 365 days.
-- Common fields are typed; the whole event is kept in payload.
CREATE TABLE IF NOT EXISTS netsec.eve
(
    ts            DateTime64(6, 'UTC') CODEC(Delta, ZSTD(1)),
    event_type    LowCardinality(String),
    in_iface      LowCardinality(String),
    src_ip        IPv6,
    dest_ip       IPv6,
    src_port      UInt16,
    dest_port     UInt16,
    proto         LowCardinality(String),
    app_proto     LowCardinality(String),
    flow_id       UInt64,
    community_id  String,
    signature_id  UInt32,
    signature     LowCardinality(String),
    category      LowCardinality(String),
    severity      UInt8,
    dns_rrname    String,
    tls_sni       String,
    http_hostname String,
    payload       JSON(max_dynamic_paths = 256,
                       SKIP REGEXP '^http\\.(request|response)_headers',
                       SKIP REGEXP '^(packet|payload|payload_printable)$') CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (event_type, toStartOfHour(ts), src_ip, ts)
TTL toDateTime(ts) + INTERVAL 365 DAY DELETE;

-- Squid access log for opted-in machines (phase 5). 365 days.
CREATE TABLE IF NOT EXISTS netsec.proxy
(
    ts         DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    client_ip  IPv6,
    method     LowCardinality(String),
    host       String,
    url          String CODEC(ZSTD(3)),
    sni          String,
    bump_mode    LowCardinality(String),
    status       UInt16,
    bytes        UInt64,
    squid_status LowCardinality(String),
    duration_ms  UInt32,
    server_ip    IPv6,
    user_agent   String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (toStartOfHour(ts), client_ip, ts)
TTL toDateTime(ts) + INTERVAL 365 DAY DELETE
SETTINGS ttl_only_drop_parts = 1;

-- Pod DNS lookups logged by node-local-dns, sent by Alloy over OTLP (phase 4). 365 days.
CREATE TABLE IF NOT EXISTS netsec.dns_queries
(
    ts        DateTime64(6, 'UTC') CODEC(Delta, ZSTD(1)),
    client_ip IPv6,
    qname     String,
    qtype     LowCardinality(String),
    rcode     LowCardinality(String),
    answers   Array(String) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (toStartOfHour(ts), client_ip, ts)
TTL toDateTime(ts) + INTERVAL 365 DAY DELETE
SETTINGS ttl_only_drop_parts = 1;

-- Tetragon process and connect events from k8s nodes (phase 4b). 365 days.
CREATE TABLE IF NOT EXISTS netsec.tetragon
(
    ts            DateTime64(6, 'UTC') CODEC(Delta, ZSTD(1)),
    node          LowCardinality(String),
    event_type    LowCardinality(String),
    namespace     LowCardinality(String),
    pod           String,
    container     LowCardinality(String),
    binary        String,
    arguments     String CODEC(ZSTD(3)),
    parent_binary String,
    dst_ip        IPv6,
    dst_port      UInt16,
    payload       JSON(max_dynamic_paths = 256) CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (event_type, toStartOfHour(ts), namespace, ts)
TTL toDateTime(ts) + INTERVAL 365 DAY DELETE
SETTINGS ttl_only_drop_parts = 1;

-- OPNsense HAProxy connection log for the internet-facing mail frontends
-- (25, 465, 587, 993). Their clients reach the mailserver through HAProxy on
-- OPNsense, so flows and eve show OPNsense as the source; this table keeps
-- the real client address. 365 days.
CREATE TABLE IF NOT EXISTS netsec.haproxy
(
    ts            DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    client_ip     IPv6,
    client_port   UInt16,
    frontend_ip   IPv6,
    frontend_port UInt16,
    frontend      LowCardinality(String),
    backend       LowCardinality(String),
    server        LowCardinality(String),
    connect_ms    Int32,
    duration_ms   Int64,
    bytes_in      UInt64,
    bytes_out     UInt64,
    termination   LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (frontend, toStartOfHour(ts), client_ip, ts)
TTL toDateTime(ts) + INTERVAL 365 DAY DELETE
SETTINGS ttl_only_drop_parts = 1;

-- Hourly rollups, kept forever (no TTL). Raw tables keep 365 days; these keep
-- the patterns: who talked to whom, on which port, how much, and which
-- signatures, names, SNIs, JA4s, user agents and SSH versions were seen.
-- Measured 2026-11-11: about 3.5 GB a year, most of it flows_hourly.
--
-- Each table is a SummingMergeTree whose ORDER BY holds every dimension, so
-- merges add up the counters. Rows for one key can sit in several parts until
-- a merge: always aggregate with sum() and GROUP BY, never read n directly.
--
-- Each materialized view fills its table on insert into the raw table. The
-- views count only rows with ts >= 2026-11-11 11:45:00 UTC, the moment they
-- went live; older rows were backfilled once with the same SELECT and
-- ts < that moment, so nothing is counted twice.
--
-- A flow crossing VLAN 10 and 20 is logged on both interfaces, so counts in
-- the eve_* rollups include both copies, as in netsec.eve.

-- NetFlow, per hour and pair. port is the lower of the two ports: the service
-- port for client-server traffic, so both directions of one connection share it.
CREATE TABLE IF NOT EXISTS netsec.flows_hourly
(
    hour    DateTime('UTC'),
    src_ip  IPv6,
    dst_ip  IPv6,
    port    UInt16,
    proto   LowCardinality(String),
    flows   UInt64,
    bytes   UInt64,
    packets UInt64
)
ENGINE = SummingMergeTree((flows, bytes, packets))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, src_ip, dst_ip, port, proto);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.flows_hourly_mv TO netsec.flows_hourly AS
SELECT toStartOfHour(ts) AS hour, src_ip, dst_ip, least(src_port, dst_port) AS port, proto,
       count() AS flows, sum(bytes) AS bytes, sum(packets) AS packets
FROM netsec.flows
WHERE ts >= toDateTime64('2026-11-11 11:45:00', 3, 'UTC')
GROUP BY hour, src_ip, dst_ip, port, proto;

-- Suricata alerts, per hour, signature and pair.
CREATE TABLE IF NOT EXISTS netsec.eve_alert_hourly
(
    hour         DateTime('UTC'),
    signature_id UInt32,
    signature    LowCardinality(String),
    category     LowCardinality(String),
    severity     UInt8,
    src_ip       IPv6,
    dest_ip      IPv6,
    dest_port    UInt16,
    proto        LowCardinality(String),
    n            UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, signature_id, src_ip, dest_ip, dest_port, proto, signature, category, severity);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.eve_alert_hourly_mv TO netsec.eve_alert_hourly AS
SELECT toStartOfHour(ts) AS hour, signature_id, signature, category, severity,
       src_ip, dest_ip, dest_port, proto, count() AS n
FROM netsec.eve
WHERE event_type = 'alert' AND ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;

-- Suricata DNS answers, per hour, client and name. EVE logs a response from
-- the server, so the client is dest_ip and the resolver is src_ip.
CREATE TABLE IF NOT EXISTS netsec.eve_dns_hourly
(
    hour      DateTime('UTC'),
    client_ip IPv6,
    server_ip IPv6,
    rrname    String,
    rrtype    LowCardinality(String),
    rcode     LowCardinality(String),
    n         UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, client_ip, rrname, server_ip, rrtype, rcode);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.eve_dns_hourly_mv TO netsec.eve_dns_hourly AS
SELECT toStartOfHour(ts) AS hour, dest_ip AS client_ip, src_ip AS server_ip, dns_rrname AS rrname,
       JSONExtractString(toString(arrayElement(payload.dns.queries.:`Array(JSON)`, 1)), 'rrtype') AS rrtype,
       coalesce(payload.dns.rcode.:String, '') AS rcode, count() AS n
FROM netsec.eve
WHERE event_type = 'dns' AND ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;

-- Suricata TLS handshakes, per hour, pair, SNI and client fingerprint.
CREATE TABLE IF NOT EXISTS netsec.eve_tls_hourly
(
    hour      DateTime('UTC'),
    src_ip    IPv6,
    dest_ip   IPv6,
    dest_port UInt16,
    sni       String,
    ja4       LowCardinality(String),
    version   LowCardinality(String),
    n         UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, src_ip, sni, dest_ip, dest_port, ja4, version);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.eve_tls_hourly_mv TO netsec.eve_tls_hourly AS
SELECT toStartOfHour(ts) AS hour, src_ip, dest_ip, dest_port, tls_sni AS sni,
       coalesce(payload.tls.ja4.:String, '') AS ja4, coalesce(payload.tls.version.:String, '') AS version,
       count() AS n
FROM netsec.eve
WHERE event_type = 'tls' AND ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;

-- Suricata plaintext HTTP requests, per hour, pair, host and user agent.
CREATE TABLE IF NOT EXISTS netsec.eve_http_hourly
(
    hour       DateTime('UTC'),
    src_ip     IPv6,
    dest_ip    IPv6,
    dest_port  UInt16,
    hostname   String,
    user_agent String,
    n          UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, src_ip, hostname, dest_ip, dest_port, user_agent);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.eve_http_hourly_mv TO netsec.eve_http_hourly AS
SELECT toStartOfHour(ts) AS hour, src_ip, dest_ip, dest_port, http_hostname AS hostname,
       coalesce(payload.http.http_user_agent.:String, '') AS user_agent, count() AS n
FROM netsec.eve
WHERE event_type = 'http' AND ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;

-- Suricata SSH sessions, per hour, pair and software versions.
CREATE TABLE IF NOT EXISTS netsec.eve_ssh_hourly
(
    hour            DateTime('UTC'),
    src_ip          IPv6,
    dest_ip         IPv6,
    dest_port       UInt16,
    client_software LowCardinality(String),
    server_software LowCardinality(String),
    n               UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, src_ip, dest_ip, dest_port, client_software, server_software);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.eve_ssh_hourly_mv TO netsec.eve_ssh_hourly AS
SELECT toStartOfHour(ts) AS hour, src_ip, dest_ip, dest_port,
       coalesce(payload.ssh.client.software_version.:String, '') AS client_software,
       coalesce(payload.ssh.server.software_version.:String, '') AS server_software,
       count() AS n
FROM netsec.eve
WHERE event_type = 'ssh' AND ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;

-- HAProxy mail connections, per hour, client, port and termination state.
CREATE TABLE IF NOT EXISTS netsec.haproxy_hourly
(
    hour          DateTime('UTC'),
    client_ip     IPv6,
    frontend_port UInt16,
    termination   LowCardinality(String),
    connections   UInt64,
    bytes_in      UInt64,
    bytes_out     UInt64
)
ENGINE = SummingMergeTree((connections, bytes_in, bytes_out))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, client_ip, frontend_port, termination);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.haproxy_hourly_mv TO netsec.haproxy_hourly AS
SELECT toStartOfHour(ts) AS hour, client_ip, frontend_port, termination,
       count() AS connections, sum(bytes_in) AS bytes_in, sum(bytes_out) AS bytes_out
FROM netsec.haproxy
WHERE ts >= toDateTime64('2026-11-11 11:45:00', 3, 'UTC')
GROUP BY ALL;

-- Squid requests from opted-in machines, per hour, client and host.
CREATE TABLE IF NOT EXISTS netsec.proxy_hourly
(
    hour      DateTime('UTC'),
    client_ip IPv6,
    host      String,
    bump_mode LowCardinality(String),
    requests  UInt64,
    bytes     UInt64
)
ENGINE = SummingMergeTree((requests, bytes))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, client_ip, host, bump_mode);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.proxy_hourly_mv TO netsec.proxy_hourly AS
SELECT toStartOfHour(ts) AS hour, client_ip, host, bump_mode, count() AS requests, sum(bytes) AS bytes
FROM netsec.proxy
WHERE ts >= toDateTime64('2026-11-11 11:45:00', 3, 'UTC')
GROUP BY ALL;

-- Pod DNS lookups, per hour, pod address and name.
CREATE TABLE IF NOT EXISTS netsec.dns_queries_hourly
(
    hour      DateTime('UTC'),
    client_ip IPv6,
    qname     String,
    qtype     LowCardinality(String),
    rcode     LowCardinality(String),
    n         UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, client_ip, qname, qtype, rcode);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.dns_queries_hourly_mv TO netsec.dns_queries_hourly AS
SELECT toStartOfHour(ts) AS hour, client_ip, qname, qtype, rcode, count() AS n
FROM netsec.dns_queries
WHERE ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;

-- Tetragon, per hour, namespace, binary and destination (pod names change, so
-- they are left out).
CREATE TABLE IF NOT EXISTS netsec.tetragon_hourly
(
    hour       DateTime('UTC'),
    node       LowCardinality(String),
    event_type LowCardinality(String),
    namespace  LowCardinality(String),
    binary     String,
    dst_ip     IPv6,
    dst_port   UInt16,
    n          UInt64
)
ENGINE = SummingMergeTree((n))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, event_type, namespace, binary, dst_ip, dst_port, node);

CREATE MATERIALIZED VIEW IF NOT EXISTS netsec.tetragon_hourly_mv TO netsec.tetragon_hourly AS
SELECT toStartOfHour(ts) AS hour, node, event_type, namespace, binary, dst_ip, dst_port, count() AS n
FROM netsec.tetragon
WHERE ts >= toDateTime64('2026-11-11 11:45:00', 6, 'UTC')
GROUP BY ALL;
