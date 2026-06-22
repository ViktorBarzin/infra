# Tracing capability: Grafana Tempo + OpenTelemetry Collector

**Status:** implemented (Phase 2) · 2026-06-21 · driver: TripIt observability
**Companion to:** `tripit` repo `docs/adr/0032-observability-otel-traces-and-content-logging.md`
**Extends:** [monitoring architecture](../architecture/monitoring.md)

## Why

The monitoring stack has metrics (Prometheus), logs (Loki, 30d) and alerting, but
had **no distributed tracing**. TripIt added end-to-end OpenTelemetry instrumentation
to reproduce failed user flows and measure performance; its spans need a home, and
logs↔traces need to correlate. This is a **new shared cluster capability** — TripIt
is just the first consumer (the monorepo already has OTel-instrumented apps:
`realestate-crawler`, `trading-bot`, previously metrics-only).

## What landed (`stacks/monitoring/modules/monitoring/`)

1. **Grafana Tempo** (`tempo.tf` / `tempo.yaml`) — single-binary, `filesystem`
   storage on a `proxmox-lvm` PVC (20Gi), 30-day retention, OTLP receivers. Same
   helm-release pattern as Loki.
2. **OpenTelemetry Collector** (`otel-collector.tf` / `otel-collector.yaml`) —
   contrib image (the `redaction` processor is contrib-only), a single
   `otlp -> redaction -> batch -> otlp/tempo` traces pipeline. The redaction
   processor is the **deny-list backstop**: it drops credential-shaped attribute
   values (bearer tokens, JWTs, PEM blocks) before storage. In-app span hygiene is
   primary; this is defense-in-depth.
3. **Grafana correlation** — a `tempo` datasource ConfigMap (`tempo.tf`), and a
   `derivedFields` addition on the **Loki** datasource (`loki.tf`) that pulls
   `trace_id` out of tripit's JSON logs and deep-links to the trace in Tempo. The
   Loki edit is additive (no `uid` change) so existing dashboards are unaffected.
4. **App flip** (`stacks/tripit/main.tf`) — tripit gets `LOG_FORMAT=json` +
   `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at the Collector, turning Phase-1's
   in-process spans into exported traces.

In-cluster apps export OTLP to `otel-collector-opentelemetry-collector.monitoring`;
no browser-facing OTLP ingress is exposed (TripIt's frontend stays
propagate-and-flush per ADR-0032).

## Notes

- **Cardinality:** `trace_id` / `session.id` are span attributes / log fields, never
  Prometheus or Loki labels.
- **Metrics unchanged:** annotation-based Prometheus scraping stays; tracing is
  additive.
- **Privacy:** ADR-0032 records the owner's accepted trade-off that TripIt logs user
  content (incl. external users') to shared monitoring; the Collector redaction
  processor enforces the hard-never deny-list for the **trace** path.
- **Apply:** Terraform-only, presence-claimed (`stack:monitoring`), `proxmox-lvm`
  storage. Update `docs/architecture/monitoring.md` (components table + diagram).
