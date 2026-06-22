# Tracing capability: Grafana Tempo + OpenTelemetry Collector

**Status:** implemented (Phase 2) · 2026-06-22 · driver: TripIt observability
**Companion to:** `tripit` repo `docs/adr/0032-observability-otel-traces-and-content-logging.md`
**Extends:** [monitoring architecture](../architecture/monitoring.md)

## Why

The monitoring stack has metrics (Prometheus), logs (Loki, 30d) and alerting, but
had **no distributed tracing**. TripIt added end-to-end OpenTelemetry instrumentation
to reproduce failed user flows and measure performance; its spans need a home, and
logs↔traces need to correlate. This is a **new shared cluster capability** — TripIt
is just the first consumer.

## What landed (`stacks/monitoring/modules/monitoring/`)

1. **Grafana Tempo** (`tempo.tf` / `tempo.yaml`) — single-binary, `filesystem`
   storage on a `proxmox-lvm` PVC (20Gi), 30-day retention, OTLP receivers.
   `tempo.resources` set explicitly (req 256Mi / limit 2Gi) — the single-binary
   chart ignores a top-level `resources:` and the pod otherwise OOMs on the
   namespace LimitRange default.
2. **OpenTelemetry Collector** (`otel-collector.tf` / `otel-collector.yaml`) —
   contrib image (the `redaction` processor is contrib-only), one
   `otlp -> redaction -> batch -> otlp/tempo` traces pipeline. The redaction
   processor is the **deny-list backstop** (drops bearer/JWT/PEM-shaped values).
3. **Grafana correlation** — a `tempo` datasource (`tempo.tf`), and a
   `derivedFields` addition on the **Loki** datasource (`loki.tf`) pulling
   `trace_id` out of tripit's JSON logs and deep-linking to Tempo. Additive (no
   `uid` change) so existing dashboards are unaffected.
4. **App flip** (`stacks/tripit/main.tf`) — tripit gets `LOG_FORMAT=json` +
   `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at the Collector.

Both helm releases use **`atomic=true` + `cleanup_on_fail=true`**: a failed install
auto-rolls-back rather than leaving a stuck `failed` release (the first-attempt
failure mode — see infra memory #6479).

## Notes

- **Cardinality:** `trace_id` / `session.id` are span attributes / log fields, never
  Prometheus or Loki labels.
- **Privacy:** ADR-0032 records the accepted trade-off that TripIt logs user content
  to shared monitoring; the Collector redaction processor enforces the deny-list on
  the trace path.
- **Apply:** Terraform-only, presence-claimed (`stack:monitoring`). Update
  `docs/architecture/monitoring.md` (components table + diagram) once stable.
