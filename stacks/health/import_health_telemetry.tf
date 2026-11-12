# Adopt the health-telemetry Secret, created 2026-11-09 but never recorded in
# state, so every health apply failed with "already exists". Delete this file
# once the import has applied.
import {
  to = kubernetes_secret.health_telemetry
  id = "health/health-telemetry"
}
