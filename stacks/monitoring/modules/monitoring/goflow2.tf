# goflow2 decodes OPNsense's NetFlow v9 (lan, opt1) and writes one JSON line
# per flow into a FIFO; the Vector sidecar reads it and forwards the lines to
# the netsec Vector, which writes netsec.flows on the claude-sessions
# ClickHouse (docs/architecture/network-security-monitoring.md). Prometheus
# keeps scraping goflow2's own metrics on :8080.
#
# The FIFO, not a file: ~100 flows/s would grow a file by GBs a day, and a
# pipe needs no rotation. If the sidecar stops, goflow2's writes fail and
# those flows are lost until it returns; goflow2 itself keeps running.

# OPNsense's ng_netflow sends IN_BYTES/IN_PKTS and also OUT_BYTES/OUT_PKTS = 0.
# goflow2 v2.2.7 decodes both pairs into `bytes`/`packets`, so the zeros won and
# every record read 0 bytes (found 2026-11-10). The mapping copies IN_* into two
# extra fields first; the netsec Vector reads in_bytes/in_packets.
resource "kubernetes_config_map" "goflow2" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "mapping.yaml" = yamlencode({
      formatter = {
        fields = [
          "type", "time_received_ns", "sampling_rate", "sampler_address",
          "time_flow_start_ns", "time_flow_end_ns", "bytes", "packets",
          "in_bytes", "in_packets", "src_addr", "dst_addr", "etype", "proto",
          "src_port", "dst_port", "in_if", "out_if", "tcp_flags", "next_hop",
          "src_net", "dst_net",
        ]
        protobuf = [
          { name = "in_bytes", index = 1001, type = "varint" },
          { name = "in_packets", index = 1002, type = "varint" },
        ]
      }
      netflowv9 = {
        mapping = [
          { field = 1, destination = "in_bytes" },
          { field = 2, destination = "in_packets" },
        ]
      }
    })
    "vector.yaml" = yamlencode({
      data_dir = "/var/lib/vector"
      api      = { enabled = false }
      sources = {
        goflow2 = {
          type      = "exec"
          mode      = "streaming"
          command   = ["cat", "/run/goflow2/flows"]
          streaming = { respawn_on_exit = true, respawn_interval_secs = 1 }
          decoding  = { codec = "bytes" }
          framing   = { method = "newline_delimited" }
        }
        internal = { type = "internal_metrics" }
      }
      transforms = {
        tag = {
          type   = "remap"
          inputs = ["goflow2"]
          source = ". = {\"message\": .message, \"netsec_kind\": \"flow\"}"
        }
      }
      sinks = {
        netsec = {
          type   = "vector"
          inputs = ["tag"]
          # The scheme is required: without it Vector 0.61 connects to nothing.
          address = "http://netsec-vector.netsec.svc.cluster.local:6000"
          # Dropping here, not blocking: a blocked pipe would stall goflow2.
          buffer = { type = "memory", max_events = 20000, when_full = "drop_newest" }
        }
        metrics = {
          type    = "prometheus_exporter"
          inputs  = ["internal"]
          address = "0.0.0.0:9598"
        }
      }
    })
  }
}

resource "kubernetes_deployment" "goflow2" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "goflow2"
      tier = var.tier
      # ADR-0014 service identity: monitoring is a multi-Service namespace, so
      # the namespace alone can't attribute Goldmane flows. Value = the
      # fronting Service name (kubernetes_service.goflow2 — the metrics svc; the
      # goflow2-netflow NodePort is the same pod by another name).
      "service-identity" = "goflow2"
    }
    annotations = {
      # The mapping and the sidecar config live in the goflow2 ConfigMap.
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "goflow2"
      }
    }
    template {
      metadata {
        labels = {
          app = "goflow2"
          # ADR-0014: Goldmane/Felix stamps POD labels onto flows, so the
          # disambiguating identity must live on the pod template (not just
          # the Deployment metadata above). Not in selector → no replace.
          "service-identity" = "goflow2"
        }
      }
      spec {
        init_container {
          name    = "mkfifo"
          image   = "busybox:1.38@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4"
          command = ["sh", "-c", "[ -p /run/goflow2/flows ] || mkfifo -m 0666 /run/goflow2/flows"]
          volume_mount {
            name       = "fifo"
            mount_path = "/run/goflow2"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              memory = "16Mi"
            }
          }
        }
        container {
          name  = "goflow2"
          image = "netsampler/goflow2:v2.2.7"
          args = [
            # One decode worker: goflow2 writes each record and its newline as
            # two writes, so two workers interleaved them and ~0.4% of lines
            # held two records (2026-11-10). ~100 flows/s needs one worker.
            "-listen", "netflow://:2055?workers=1",
            "-format", "json",
            "-mapping", "/etc/goflow2/mapping.yaml",
            "-transport", "file",
            "-transport.file", "/run/goflow2/flows",
          ]
          volume_mount {
            name       = "fifo"
            mount_path = "/run/goflow2"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/goflow2/mapping.yaml"
            sub_path   = "mapping.yaml"
          }

          port {
            name           = "netflow"
            container_port = 2055
            protocol       = "UDP"
          }
          port {
            name           = "metrics"
            container_port = 8080
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        container {
          name  = "vector"
          image = "docker.io/timberio/vector:0.61.0-debian"
          args  = ["--config", "/etc/vector/vector.yaml"]
          port {
            name           = "vector-metrics"
            container_port = 9598
            protocol       = "TCP"
          }
          volume_mount {
            name       = "fifo"
            mount_path = "/run/goflow2"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/vector/vector.yaml"
            sub_path   = "vector.yaml"
          }
          volume_mount {
            name       = "vector-data"
            mount_path = "/var/lib/vector"
          }
          # 20,000 buffered flows are ~20 MB.
          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "fifo"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Mi"
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.goflow2.metadata[0].name
          }
        }
        volume {
          name = "vector-data"
          empty_dir {
            size_limit = "64Mi"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "goflow2" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "goflow2"
    }
  }
  spec {
    selector = {
      app = "goflow2"
    }
    port {
      name        = "metrics"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "goflow2-netflow" {
  metadata {
    name      = "goflow2-netflow"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "goflow2"
    }
  }
  spec {
    type = "NodePort"
    selector = {
      app = "goflow2"
    }
    port {
      name        = "netflow"
      port        = 2055
      target_port = 2055
      protocol    = "UDP"
      node_port   = 32055
    }
  }
}
