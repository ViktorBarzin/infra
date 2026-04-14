# Post-Mortem: <TITLE>

| Field | Value |
|-------|-------|
| **Date** | <DATE> |
| **Duration** | <DURATION> |
| **Severity** | <SEV1/SEV2/SEV3> |
| **Affected Services** | <COUNT> pods across <COUNT> namespaces |
| **Status** | Draft |

## Summary

<1-2 sentence summary of the incident.>

## Impact

- **User-facing**: <What users experienced>
- **Blast radius**: <How many services/pods/namespaces affected>
- **Duration**: <How long the outage lasted>
- **Data loss**: <None/details>
- **Monitoring gap**: <Any blind spots in alerting>

## Timeline (UTC)

| Time | Event |
|------|-------|
| **HH:MM** | <First sign of trouble> |
| **HH:MM** | <Detection / user report> |
| **HH:MM** | <Investigation begins> |
| **HH:MM** | <Root cause identified> |
| **HH:MM** | <Fix applied> |
| **HH:MM** | <Service restored> |

## Root Cause

<Narrative description of what went wrong and why.>

## Contributing Factors

1. <Factor that made the incident worse or harder to detect>
2. <Factor...>

## Detection Gaps

| Gap | Impact | Fix |
|-----|--------|-----|
| <What wasn't monitored> | <How it delayed detection> | <What to add> |

## Prevention Plan

### P0 — Prevent this exact failure

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P0 | <action> | Config | <details> | TODO |

### P1 — Reduce blast radius

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P1 | <action> | Alert | <details> | TODO |

### P2 — Detect faster

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P2 | <action> | Monitor | <details> | TODO |

### P3 — Improve resilience

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P3 | <action> | Architecture | <details> | TODO |

## Lessons Learned

1. <Key takeaway>
2. <Key takeaway>

## Follow-up Implementation

_This section is auto-populated by the postmortem-todo-resolver agent._

| Date | Action | Priority | Type | Commit | Implemented By |
|------|--------|----------|------|--------|----------------|
