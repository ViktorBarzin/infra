# Helm values
# all values - https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml
alertmanager:
  replicaCount: 1
  persistentVolume:
    enabled: true
  persistence:
    storageClass: proxmox-lvm-encrypted
    # Previously on NFS (alertmanager-pv / nfs-truenas). Migrated 2026-04-14 [PM-2026-04-14]
    # to proxmox-lvm-encrypted to eliminate circular alerting dependency.
  strategy:
    type: RollingUpdate
  baseURL: "https://alertmanager.viktorbarzin.me"
  ingress:
    enabled: true
    ingressClassName: "traefik"
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: "traefik-rate-limit@kubernetescrd,traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd"
      traefik.ingress.kubernetes.io/router.entrypoints: "websecure"
      gethomepage.dev/enabled: "true"
      gethomepage.dev/name: "Alertmanager"
      gethomepage.dev/description: "Alert routing"
      gethomepage.dev/icon: "alertmanager.png"
      gethomepage.dev/group: "Core Platform"
      gethomepage.dev/pod-selector: ""
    tls:
      - secretName: "tls-secret"
        hosts:
          - "alertmanager.viktorbarzin.me"
    hosts:
      # - alertmanager.viktorbarzin.me
      - host: alertmanager.viktorbarzin.me
        paths:
          - path: /
            pathType: Prefix
            serviceName: prometheus-server
            servicePort: 80
  config:
    enabled: true
    global:
      smtp_from: "alertmanager@viktorbarzin.me"
      # smtp_smarthost: "smtp.viktorbarzin.me:587"
      smtp_smarthost: "mailserver.mailserver.svc.cluster.local:587"
      smtp_auth_username: "alertmanager@viktorbarzin.me"
      smtp_auth_password: "${alertmanager_mail_pass}"
      smtp_require_tls: true
      slack_api_url: "${alertmanager_slack_api_url}"
    # templates:
    #   - "/etc/alertmanager/template/*.tmpl"
    route:
      group_by: ["alertname"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: slack-warning
      routes:
        # Wave 1 security lane — matches alerts that set `lane = "security"`
        # (K2-K9, V1-V7, S1 from Loki ruler). Routes to dedicated #security
        # channel regardless of severity. Defined first + continue: false so
        # security alerts never fall through to the generic #alerts channel.
        - receiver: slack-security
          group_wait: 10s
          group_interval: 1m
          repeat_interval: 1h
          matchers:
            - lane = security
          continue: false
        - receiver: slack-critical
          group_wait: 10s
          group_interval: 1m
          repeat_interval: 1h
          matchers:
            - severity = critical
          continue: false
        - receiver: slack-info
          group_wait: 5m
          group_interval: 30m
          repeat_interval: 12h
          matchers:
            - severity = info
          continue: false
    inhibit_rules:
      # Node down suppresses workload and service alerts (cascade protection)
      - source_matchers:
          - alertname = NodeDown
        target_matchers:
          - alertname =~ "NodeNotReady|NodeConditionBad|PodCrashLooping|ContainerOOMKilled|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|DaemonSetMissingPods|ScrapeTargetDown|NodeLowFreeMemory|PostgreSQLDown|RedisDown|HeadscaleDown|HeadscaleReplicasMismatch|AuthentikDown|PoisonFountainDown|HackmdDown|PrivatebinDown|MailServerDown|EmailRoundtripFailing|EmailRoundtripStale|ViktorBarzinApexDrift|ViktorBarzinApexProbeStale|NodeExporterDown|DockerRegistryDown|HomeAssistantDown|HomeAssistantCriticalSensorUnavailable|CloudflaredDown|TechnitiumDNSDown|iDRACRedfishMetricsMissing|iDRACSNMPMetricsMissing|HomeAssistantMetricsMissing"
      # NFS down causes mass pod failures and NFS-dependent service outages
      - source_matchers:
          - alertname = NFSServerUnresponsive
        target_matchers:
          - alertname =~ "PodCrashLooping|ContainerOOMKilled|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|DaemonSetMissingPods|ScrapeTargetDown|PostgreSQLDown|RedisDown|AuthentikDown|PoisonFountainDown|HackmdDown|PrivatebinDown|MailServerDown|EmailRoundtripFailing|EmailRoundtripStale|ViktorBarzinApexDrift|ViktorBarzinApexProbeStale|HomeAssistantDown|HomeAssistantCriticalSensorUnavailable"
      # Traefik down makes service-level alerts noise
      - source_matchers:
          - alertname = TraefikDown
        target_matchers:
          - alertname =~ "HighServiceErrorRate|HighService4xxRate|HighServiceLatency|TraefikHighOpenConnections|IngressTTFBHigh|IngressTTFBCritical|IngressErrorRate5xxHigh|AnubisChallengeStoreErrors"
      # Traefik down makes ForwardAuth alerts redundant
      - source_matchers:
          - alertname = TraefikDown
        target_matchers:
          - alertname =~ "PoisonFountainDown|ForwardAuthFallbackActive"
      # A stale Traefik replica returns 404 for a fraction of requests; the same
      # bug surfaces as TTFB / 4xx / 5xx / external-divergence symptoms downstream.
      # When TraefikReplicaConfigStale fires, the root cause is identified —
      # suppress the symptom alerts so only the actionable one pages.
      - source_matchers:
          - alertname = TraefikReplicaConfigStale
        target_matchers:
          - alertname =~ "HighServiceErrorRate|HighService4xxRate|HighServiceLatency|TraefikHighOpenConnections|IngressTTFBHigh|IngressTTFBCritical|IngressErrorRate5xxHigh|ForwardAuthFallbackActive|AnubisChallengeStoreErrors|ExternalAccessDivergence"
      # HA down → every sensor goes unavailable. One root-cause alert is enough.
      - source_matchers:
          - alertname = HomeAssistantDown
        target_matchers:
          - alertname =~ "HomeAssistantCriticalSensorUnavailable|HomeAssistantMetricsMissing"
      # PVFillingUp (95% used) is the immediate critical; PVPredictedFull
      # (linear projection over 6h) is the leading indicator. When the disk
      # is actually full, the prediction is redundant.
      - source_matchers:
          - alertname = PVFillingUp
        target_matchers:
          - alertname = PVPredictedFull
        equal: [namespace, persistentvolumeclaim]
      # EmailRoundtripFailing = active outage right now (probe failed).
      # EmailRoundtripStale = derivative ("haven't seen success in 60min").
      # The Failing alert subsumes the Stale alert.
      - source_matchers:
          - alertname = EmailRoundtripFailing
        target_matchers:
          - alertname = EmailRoundtripStale
      # Power outage makes on-battery alert redundant
      - source_matchers:
          - alertname = PowerOutage
        target_matchers:
          - alertname = OnBattery
      # Power outage suppresses everything downstream
      - source_matchers:
          - alertname = PowerOutage
        target_matchers:
          - alertname =~ "NodeDown|NFSServerUnresponsive|NodeExporterDown|CloudflaredDown|MetalLBSpeakerDown|MetalLBControllerDown|UPSMetricsMissing|iDRACRedfishMetricsMissing|iDRACSNMPMetricsMissing|ATSMetricsMissing|HomeAssistantMetricsMissing|FuseMainMetricsMissing|FuseGarageMetricsMissing|ThermostatHolMetricsMissing|ThermostatMasterBedroomMetricsMissing|ThermostatOfficeMetricsMissing|ThermostatKidsRoomMetricsMissing|ProxmoxMetricsMissing|iDRACSystemUnhealthy|iDRACServerPoweredOff|ProxmoxExporterDown"
      # iDRAC system-level unhealthy suppresses component-level alerts
      - source_matchers:
          - alertname = iDRACSystemUnhealthy
        target_matchers:
          - alertname =~ "iDRACPowerSupplyUnhealthy|iDRACMemoryUnhealthy|iDRACStorageDriveUnhealthy|FanFailure"
      # Fuse panel fault suppresses overcurrent/temp alerts for that panel
      - source_matchers:
          - alertname = FuseMainFault
        target_matchers:
          - alertname = FuseMainMetricsMissing
      - source_matchers:
          - alertname = FuseGarageFault
        target_matchers:
          - alertname = FuseGarageMetricsMissing
      # Tuya Cloud API down suppresses all per-device metrics-missing alerts
      - source_matchers:
          - alertname = TuyaCloudDown
        target_matchers:
          - alertname =~ "ATSMetricsMissing|FuseMainMetricsMissing|FuseGarageMetricsMissing|ThermostatHolMetricsMissing|ThermostatMasterBedroomMetricsMissing|ThermostatOfficeMetricsMissing|ThermostatKidsRoomMetricsMissing"
      # Containerd broken suppresses downstream pod alerts
      - source_matchers:
          - alertname = KubeletImagePullErrors
        target_matchers:
          - alertname =~ "PodsStuckContainerCreating|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|DaemonSetMissingPods"
    receivers:
      - name: slack-critical
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
            fallback: '{{ if eq .Status "firing" }}CRITICAL{{ else }}RESOLVED{{ end }}: {{ .GroupLabels.alertname }}'
            title: '{{ if eq .Status "firing" }}[CRITICAL]{{ else }}[RESOLVED]{{ end }} {{ .GroupLabels.alertname }} ({{ .Alerts | len }})'
            text: '{{ range .Alerts }}• {{ .Annotations.summary }}{{ "\n" }}{{ end }}'
      - name: slack-warning
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}warning{{ else }}good{{ end }}'
            fallback: '{{ if eq .Status "firing" }}WARNING{{ else }}RESOLVED{{ end }}: {{ .GroupLabels.alertname }}'
            title: '{{ if eq .Status "firing" }}[WARNING]{{ else }}[RESOLVED]{{ end }} {{ .GroupLabels.alertname }} ({{ .Alerts | len }})'
            text: '{{ range .Alerts }}• {{ .Annotations.summary }}{{ "\n" }}{{ end }}'
      - name: slack-info
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}#439FE0{{ else }}good{{ end }}'
            fallback: 'INFO: {{ .GroupLabels.alertname }}'
            title: '[INFO] {{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}• {{ .Annotations.summary }}{{ "\n" }}{{ end }}'
      - name: slack-security
        slack_configs:
          - send_resolved: true
            channel: "#security"
            color: '{{ if eq .Status "firing" }}{{ if eq (index .Alerts 0).Labels.severity "critical" }}danger{{ else }}warning{{ end }}{{ else }}good{{ end }}'
            fallback: '{{ if eq .Status "firing" }}[SECURITY-{{ (index .Alerts 0).Labels.severity | toUpper }}]{{ else }}[RESOLVED]{{ end }}: {{ .GroupLabels.alertname }}'
            title: '{{ if eq .Status "firing" }}[SECURITY/{{ (index .Alerts 0).Labels.severity | toUpper }}]{{ else }}[RESOLVED]{{ end }} {{ .GroupLabels.alertname }} ({{ .Alerts | len }})'
            text: |-
              {{ range .Alerts }}*{{ .Annotations.summary }}*
              {{ if .Annotations.description }}{{ .Annotations.description }}
              {{ end }}{{ if .Annotations.runbook }}Runbook: {{ .Annotations.runbook }}
              {{ end }}{{ end }}
  # web.external-url seems to be hardcoded, edited deployment manually
  # extraArgs:
  #   web.external-url: "https://prometheus.viktorbarzin.me"
  resources:
    requests:
      cpu: 25m
      memory: 256Mi
    limits:
      memory: 256Mi
prometheus-node-exporter:
  enabled: true
  resources:
    requests:
      cpu: 25m
      memory: 100Mi
    limits:
      memory: 100Mi
# NOTE: The parent chart forwards subchart values under `prometheus-pushgateway:`,
# not `pushgateway:` — using the wrong key silently no-ops.
prometheus-pushgateway:
  # Without persistence the pushgateway's in-memory metrics are lost on restart.
  # Once-per-day pushers (offsite-backup-sync) stay invisible until their next run,
  # which is why backup_last_success_timestamp{job="offsite-backup-sync"} vanished
  # after the 2026-04-22 node3 kubelet hiccup.
  persistentVolume:
    enabled: true
    size: 2Gi
    storageClass: proxmox-lvm-encrypted
    mountPath: /data
  extraArgs:
    - --persistence.file=/data/pushgateway.bin
    - --persistence.interval=1m
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      memory: 256Mi
server:
  # Halve scrape load on apiserver + cAdvisor + node-exporter without losing
  # alerting fidelity. Per-job overrides (snmp-ups 30s, snmp-idrac 1m, etc.)
  # below keep critical metrics fresh; alert `for:` durations were audited and
  # all 1m alerts were bumped to 3m to stay above the new scrape cadence.
  global:
    scrape_interval: 2m
    evaluation_interval: 1m
  # Enable me to delete metrics
  extraFlags:
    - "web.enable-admin-api"
    - "web.enable-lifecycle"
    - "storage.tsdb.allow-overlapping-blocks"
    - "storage.tsdb.retention.size=180GB"
    - "storage.tsdb.wal-compression"
  persistentVolume:
    # enabled: false
    existingClaim: prometheus-data-proxmox
    # storageClass: rook-cephfs
  retention: "26w"  # 6 months — reduces compaction writes vs 52w. Size limit (180GB) is the effective cap anyway.
  # NOTE: Memory must be >= 4Gi. The WAL tmpfs (2Gi, medium: Memory) shares
  # the container's cgroup limit. At 3Gi, Prometheus OOM-kills during WAL replay.
  resources:
    requests:
      cpu: 100m
      memory: 4Gi
    limits:
      memory: 4Gi
  livenessProbeInitialDelay: 300
  readinessProbeInitialDelay: 60
  strategy:
    type: Recreate
  baseURL: "https://prometheus.viktorbarzin.me"
  extraVolumes:
      - name: prometheus-wal-tmpfs
        emptyDir:
          medium: Memory
          sizeLimit: 2Gi
      - name: prometheus-backup
        persistentVolumeClaim:
          claimName: monitoring-prometheus-backup-host
  extraVolumeMounts:
    - name: prometheus-wal-tmpfs
      mountPath: /data/wal
    - name: prometheus-backup
      mountPath: /backup
  sidecarContainers:
    prometheus-backup:
      image: docker.io/library/alpine:3.21
      command:
        - /bin/sh
        - -c
        - |
          echo "Prometheus backup sidecar started (monthly, 1st Sunday 04:00 UTC)"
          while true; do
            # Wait for 1st Sunday of month at 04:00 UTC
            while true; do
              dow=$(date -u +%w)       # 0=Sunday
              dom=$(date -u +%d)       # day of month
              hour=$(date -u +%H)
              if [ "$dow" = "0" ] && [ "$dom" -le 7 ] && [ "$hour" -ge 4 ]; then
                break
              fi
              sleep 3600  # check every hour
            done

            echo "$(date) Starting Prometheus TSDB snapshot"
            # Create TSDB snapshot via admin API (wget is built into BusyBox)
            resp=$(wget -qO- --post-data='' http://localhost:9090/api/v1/admin/tsdb/snapshot 2>&1)
            if [ $? -ne 0 ]; then
              echo "$(date) ERROR: Failed to create snapshot: $resp"
              continue
            fi
            # Parse snapshot name without jq: {"status":"success","data":{"name":"20260322T030000Z-..."}}
            snap_name=$(echo "$resp" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -z "$snap_name" ]; then
              echo "$(date) ERROR: Could not parse snapshot name from: $resp"
              continue
            fi
            echo "$(date) Snapshot created: $snap_name"

            # Tar snapshot to NFS backup volume
            backup_file="prometheus_$(date +%Y%m%d_%H%M).tar.gz"
            tar cf - -C /data/snapshots/ "$snap_name" | gzip -9 > "/backup/$backup_file"
            echo "$(date) Backup written: $backup_file ($(du -h /backup/$backup_file | cut -f1))"

            # Clean up snapshot from data dir
            rm -rf "/data/snapshots/$snap_name"

            # Rotate: keep 2 most recent backups
            ls -t /backup/prometheus_*.tar.gz 2>/dev/null | tail -n +3 | xargs rm -f 2>/dev/null

            # Push success metric to Pushgateway for alerting
            printf "prometheus_backup_last_success_timestamp %s\n" "$(date +%s)" | wget -qO- --header="Content-Type: text/plain" --post-file=- http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/prometheus-backup 2>/dev/null

            echo "$(date) Backup complete. Files in /backup:"
            ls -lh /backup/prometheus_*.tar.gz 2>/dev/null || echo "  (none)"

            # Sleep 24h to avoid re-triggering within the same Sunday window
            sleep 86400
          done
      volumeMounts:
        - name: storage-volume
          mountPath: /data
          readOnly: false
        - name: prometheus-backup
          mountPath: /backup
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 128Mi
  ingress:
    enabled: true
    ingressClassName: "traefik"
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: "traefik-rate-limit@kubernetescrd,traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd"
      traefik.ingress.kubernetes.io/router.entrypoints: "websecure"

      gethomepage.dev/enabled: "true"
      gethomepage.dev/description: "Prometheus"
      gethomepage.dev/icon: "prometheus.png"
      gethomepage.dev/name: "Prometheus"
      gethomepage.dev/group: "Core Platform"
      gethomepage.dev/widget.type: "prometheus"
      gethomepage.dev/widget.url: "http://prometheus-server.monitoring.svc.cluster.local:80"
      gethomepage.dev/pod-selector: ""
    tls:
      - secretName: "tls-secret"
        hosts:
          - "prometheus.viktorbarzin.me"
    hosts:
      - "prometheus.viktorbarzin.me"
  alertmanagers:
    - static_configs:
        - targets:
            - "prometheus-alertmanager.monitoring.svc.cluster.local:9093"
          # - "alertmanager.viktorbarzin.me"
      tls_config:
        insecure_skip_verify: true

serverFiles:
  prometheus.yml:
    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets:
              - localhost:9090
      - job_name: kubernetes-apiservers
        scheme: https
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - action: keep
            regex: default;kubernetes;https
            source_labels:
              - __meta_kubernetes_namespace
              - __meta_kubernetes_service_name
              - __meta_kubernetes_endpoint_port_name
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: true
        metric_relabel_configs:
          - source_labels: [__name__]
            regex: '(apiserver_request_duration_seconds|apiserver_request_sli_duration_seconds|apiserver_request_body_size_bytes|etcd_request_duration_seconds|apiserver_watch_list_duration_seconds|apiserver_watch_cache_read_wait_seconds|apiserver_response_sizes|apiserver_watch_events_sizes|apiserver_admission_controller_admission_duration_seconds|workqueue_queue_duration_seconds|workqueue_work_duration_seconds|apiserver_flowcontrol_request_execution_seconds|rest_client_rate_limiter_duration_seconds|rest_client_request_duration_seconds|rest_client_request_size_bytes|rest_client_response_size_bytes)_bucket'
            action: drop
          - source_labels: [__name__]
            regex: 'kubernetes_feature_enabled|apiserver_longrunning_requests'
            action: drop
          # Whitelist: only keep essential apiserver metrics (prevents regression to 250K samples/scrape)
          - source_labels: [__name__]
            regex: 'apiserver_request_total|apiserver_request_duration_seconds_sum|apiserver_request_duration_seconds_count|apiserver_requested_deprecated_apis|workqueue_depth|up'
            action: keep
      - job_name: kubernetes-nodes
        scheme: https
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)
          - replacement: kubernetes.default.svc:443
            target_label: __address__
          - regex: (.+)
            replacement: /api/v1/nodes/$1/proxy/metrics
            source_labels:
              - __meta_kubernetes_node_name
            target_label: __metrics_path__
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: true
        metric_relabel_configs:
          - source_labels: [__name__]
            regex: '(storage_operation_duration_seconds|csi_operations_seconds|volume_operation_total_seconds|kubelet_image_pull_duration_seconds|kubelet_http_requests_duration_seconds|rest_client_rate_limiter_duration_seconds|rest_client_request_duration_seconds|rest_client_request_size_bytes|rest_client_response_size_bytes|kubelet_pod_worker_duration_seconds|kubelet_volume_metric_collection_duration_seconds|kubelet_cgroup_manager_duration_seconds)_bucket'
            action: drop
          - source_labels: [__name__]
            regex: 'kubernetes_feature_enabled|kubelet_container_log_filesystem_used_bytes'
            action: drop
          # Whitelist: only keep essential kubelet metrics
          # pvc-autoresizer requires all four kubelet_volume_stats metrics
          # (available_bytes, capacity_bytes, inodes_free, inodes); it skips
          # any PVC missing even one. Without inodes_free + inodes the
          # autoresizer's GetMetrics returns empty for every PVC and the
          # reconcile is a no-op cluster-wide.
          - source_labels: [__name__]
            regex: 'kubelet_volume_stats_capacity_bytes|kubelet_volume_stats_used_bytes|kubelet_volume_stats_available_bytes|kubelet_volume_stats_inodes|kubelet_volume_stats_inodes_used|kubelet_volume_stats_inodes_free|kubelet_running_containers|kubelet_runtime_operations_errors_total|process_cpu_seconds_total|process_resident_memory_bytes|process_start_time_seconds|go_memstats_alloc_bytes|up'
            action: keep
      - job_name: kubernetes-nodes-cadvisor
        scheme: https
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)
          - replacement: kubernetes.default.svc:443
            target_label: __address__
          - regex: (.+)
            replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
            source_labels:
              - __meta_kubernetes_node_name
            target_label: __metrics_path__
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: true
        metric_relabel_configs:
          - source_labels: [__name__]
            regex: 'container_tasks_state|container_memory_failures_total'
            action: drop
          - source_labels: [__name__]
            regex: 'container_fs_.*|container_blkio_.*|container_pressure_.*|container_spec_.*|container_ulimits_soft|container_file_descriptors|container_threads|container_threads_max|container_sockets|container_processes|container_last_seen|machine_nvm_.*|machine_swap_bytes|machine_cpu_physical_cores|machine_cpu_sockets|container_network_(receive|transmit)_(errors|packets_dropped)_total|container_cpu_(load_average_10s|load_d_average_10s|system_seconds_total|user_seconds_total)|container_memory_(cache|failcnt|kernel_usage|mapped_file|max_usage_bytes|rss|swap|total_active_file_bytes|total_inactive_file_bytes)'
            action: drop
          # Whitelist: only keep essential cAdvisor metrics
          - source_labels: [__name__]
            regex: 'container_cpu_usage_seconds_total|container_cpu_cfs_throttled_seconds_total|container_memory_working_set_bytes|container_network_receive_bytes_total|container_network_transmit_bytes_total|container_oom_events_total|container_spec_memory_limit_bytes|container_start_time_seconds|machine_cpu_cores|machine_memory_bytes'
            action: keep
      - job_name: kubernetes-service-endpoints
        honor_labels: true
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scrape
          - action: drop
            regex: true
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scrape_slow
          - action: replace
            regex: (https?)
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scheme
            target_label: __scheme__
          - action: replace
            regex: (.+)
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_path
            target_label: __metrics_path__
          - action: replace
            regex: (.+?)(?::\d+)?;(\d+)
            replacement: $1:$2
            source_labels:
              - __address__
              - __meta_kubernetes_service_annotation_prometheus_io_port
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_service_annotation_prometheus_io_param_(.+)
            replacement: __param_$1
          - action: labelmap
            regex: __meta_kubernetes_service_label_(.+)
          - action: replace
            source_labels:
              - __meta_kubernetes_namespace
            target_label: namespace
          - action: replace
            source_labels:
              - __meta_kubernetes_service_name
            target_label: service
          - action: replace
            source_labels:
              - __meta_kubernetes_pod_node_name
            target_label: node
        metric_relabel_configs:
          - source_labels: [__name__]
            regex: 'kube_replicaset_.*|kube_pod_tolerations|kube_pod_status_scheduled|kube_deployment_status_condition|kube_pod_labels|kube_pod_created|kube_pod_owner|kube_pod_container_info|kube_pod_init_container_.*|kube_endpoint_.*|kube_service_.*|kube_configmap_.*|kube_secret_.*|kube_lease_.*|kube_ingress_.*|kube_networkpolicy_.*|kube_certificatesigningrequest_.*|kube_limitrange_.*|kube_mutatingwebhookconfiguration_.*|kube_validatingwebhookconfiguration_.*|kube_verticalpodautoscaler_.*|kube_clusterrole.*|kube_role.*|kube_poddisruptionbudget_.*|coredns_proxy_request_duration_seconds_bucket|node_filesystem_device_error|node_filesystem_readonly'
            action: drop
          # Whitelist: only keep essential kube-state-metrics, node-exporter, and coredns metrics
          - source_labels: [__name__]
            regex: 'kube_cronjob_status_last_successful_time|kube_deployment_spec_replicas|kube_deployment_status_replicas_available|kube_deployment_status_replicas_unavailable|kube_job_status_failed|kube_job_status_start_time|kube_node_info|kube_node_status_allocatable|kube_node_status_capacity|kube_node_status_condition|kube_persistentvolumeclaim_status_phase|kube_volumeattachment_info|kube_pod_container_resource_limits|kube_pod_container_resource_requests|kube_pod_container_status_restarts_total|kube_pod_container_status_running|kube_pod_container_status_waiting_reason|kube_pod_info|kube_pod_status_phase|kube_pod_status_ready|kube_pod_status_reason|kube_pod_status_conditions|kube_resourcequota|kube_statefulset_replicas|kube_statefulset_status_replicas_ready|kube_daemonset_status_desired_number_scheduled|kube_daemonset_status_number_ready|kube_node_spec_unschedulable|node_cpu_seconds_total|node_disk_io_time_seconds_total|node_disk_read_bytes_total|node_disk_written_bytes_total|node_disk_reads_completed_total|node_disk_writes_completed_total|node_filesystem_avail_bytes|node_filesystem_size_bytes|node_filesystem_device_error|node_filesystem_readonly|node_hwmon_chip_names|node_hwmon_temp_celsius|node_load1|node_load15|node_load5|node_memory_MemAvailable_bytes|node_memory_MemTotal_bytes|node_memory_Buffers_bytes|node_memory_Cached_bytes|node_memory_MemFree_bytes|node_memory_SwapTotal_bytes|node_memory_SwapFree_bytes|node_network_receive_bytes_total|node_network_transmit_bytes_total|node_nfs_requests_total|node_uname_info|node_vmstat_oom_kill|coredns_cache_entries|coredns_cache_hits_total|coredns_cache_misses_total|coredns_dns_requests_total|coredns_dns_responses_total|coredns_forward_requests_total|coredns_forward_responses_total|coredns_build_info|process_cpu_seconds_total|process_resident_memory_bytes|process_start_time_seconds|up|pve_.*'
            action: keep
      - job_name: kubernetes-service-endpoints-slow
        honor_labels: true
        scrape_interval: 5m
        scrape_timeout: 30s
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scrape_slow
          - action: replace
            regex: (https?)
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scheme
            target_label: __scheme__
          - action: replace
            regex: (.+)
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_path
            target_label: __metrics_path__
          - action: replace
            regex: (.+?)(?::\d+)?;(\d+)
            replacement: $1:$2
            source_labels:
              - __address__
              - __meta_kubernetes_service_annotation_prometheus_io_port
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_service_annotation_prometheus_io_param_(.+)
            replacement: __param_$1
          - action: labelmap
            regex: __meta_kubernetes_service_label_(.+)
          - action: replace
            source_labels:
              - __meta_kubernetes_namespace
            target_label: namespace
          - action: replace
            source_labels:
              - __meta_kubernetes_service_name
            target_label: service
          - action: replace
            source_labels:
              - __meta_kubernetes_pod_node_name
            target_label: node
      - job_name: prometheus-pushgateway
        honor_labels: true
        kubernetes_sd_configs:
          - role: service
        relabel_configs:
          - action: keep
            regex: pushgateway
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_probe
      - job_name: kubernetes-services
        honor_labels: true
        metrics_path: /probe
        params:
          module:
            - http_2xx
        kubernetes_sd_configs:
          - role: service
        relabel_configs:
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_probe
          - source_labels:
              - __address__
            target_label: __param_target
          - replacement: blackbox
            target_label: __address__
          - source_labels:
              - __param_target
            target_label: instance
          - action: labelmap
            regex: __meta_kubernetes_service_label_(.+)
          - source_labels:
              - __meta_kubernetes_namespace
            target_label: namespace
          - source_labels:
              - __meta_kubernetes_service_name
            target_label: service
      - job_name: kubernetes-pods
        honor_labels: true
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scrape
          - action: drop
            regex: traefik
            source_labels:
              - __meta_kubernetes_namespace
          - action: drop
            regex: true
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scrape_slow
          - action: replace
            regex: (https?)
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scheme
            target_label: __scheme__
          - action: replace
            regex: (.+)
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_path
            target_label: __metrics_path__
          - action: replace
            regex: (\d+);(([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4})
            replacement: '[$2]:$1'
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              - __meta_kubernetes_pod_ip
            target_label: __address__
          - action: replace
            regex: (\d+);((([0-9]+?)(\.|$)){4})
            replacement: $2:$1
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              - __meta_kubernetes_pod_ip
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_pod_annotation_prometheus_io_param_(.+)
            replacement: __param_$1
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - action: replace
            source_labels:
              - __meta_kubernetes_namespace
            target_label: namespace
          - action: replace
            source_labels:
              - __meta_kubernetes_pod_name
            target_label: pod
          - action: drop
            regex: Pending|Succeeded|Failed|Completed
            source_labels:
              - __meta_kubernetes_pod_phase
          - action: replace
            source_labels:
              - __meta_kubernetes_pod_node_name
            target_label: node
      - job_name: kubernetes-pods-slow
        honor_labels: true
        scrape_interval: 5m
        scrape_timeout: 30s
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - action: keep
            regex: true
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scrape_slow
          - action: replace
            regex: (https?)
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_scheme
            target_label: __scheme__
          - action: replace
            regex: (.+)
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_path
            target_label: __metrics_path__
          - action: replace
            regex: (\d+);(([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4})
            replacement: '[$2]:$1'
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              - __meta_kubernetes_pod_ip
            target_label: __address__
          - action: replace
            regex: (\d+);((([0-9]+?)(\.|$)){4})
            replacement: $2:$1
            source_labels:
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              - __meta_kubernetes_pod_ip
            target_label: __address__
          - action: labelmap
            regex: __meta_kubernetes_pod_annotation_prometheus_io_param_(.+)
            replacement: __param_$1
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - action: replace
            source_labels:
              - __meta_kubernetes_namespace
            target_label: namespace
          - action: replace
            source_labels:
              - __meta_kubernetes_pod_name
            target_label: pod
          - action: drop
            regex: Pending|Succeeded|Failed|Completed
            source_labels:
              - __meta_kubernetes_pod_phase
          - action: replace
            source_labels:
              - __meta_kubernetes_pod_node_name
            target_label: node
  # prometheus.yml:
  # storage:
  # tsdb:
  #   # no_lockfile: true
  #   # max_blocks_in_cache: 100000
  #   # max_lookback_duration: 0s
  #   # min_block_duration: 2h
  #   # retention: 15d
  #   # chunk_encoding: 1
  #   # chunk_range: 1h
  #   # max_chunks_to_persist: 4800
  #   # chunks_to_persist: 4800
  #   cache:
  #     entries: 5000
  #   head:
  #     chunk_bytes: 1048576
  #   # wal:
  #     # compressions: 1
  #     # flush_after_seconds: 30
  #     # segment_size: 1073741824
  #   series_file:
  #     # no_sync: true
  #     # max_concurrent_writes: 256
  #     # block_size: 262144
  #     cache:
  #       max_size: 1073741824

  #   alertingaaa:
  #     alertmanagers:
  #       - static_configs:
  #           targets: "alertmanager.viktorbarzin.lan"
  alerting_rules.yml:
    groups:
      - name: R730 Host
        rules:
          - alert: HighCPUTemperature
            expr: node_hwmon_temp_celsius{instance="pve-node-r730"} * on(chip) group_left(chip_name) node_hwmon_chip_names{instance="pve-node-r730"} > 75
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "CPU temp: {{ $value | printf \"%.0f\" }}°C (threshold: 75°C)"
          - alert: SSDHighWriteRate
            expr: rate(node_disk_written_bytes_total{job="proxmox-host", device="sdb"}[2m]) / 1024 / 1024 > 2 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900 # sdb is SSD; value in MB
            for: 10m
            labels:
              severity: info
            annotations:
              summary: "SSD write rate: {{ $value | printf \"%.1f\" }} MB/s (threshold: 2 MB/s)"
          - alert: HDDHighWriteRate
            expr: rate(node_disk_written_bytes_total{job="proxmox-host", device="sdc"}[2m]) / 1024 / 1024 > 10 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900 # sdc is 11TB HDD; value in MB
            for: 20m
            labels:
              severity: info
            annotations:
              summary: "HDD write rate: {{ $value | printf \"%.1f\" }} MB/s (threshold: 10 MB/s)"
          - alert: HighSystemLoad
            expr: scalar(node_load1{instance="pve-node-r730"}) * 100 / count(count(node_cpu_seconds_total{instance="pve-node-r730"}) by (cpu)) > 50
            for: 30m
            labels:
              severity: info
            annotations:
              summary: "System load: {{ $value | printf \"%.0f\" }}% (threshold: 50%)"
          - alert: FanFailure
            expr: r730_idrac_redfish_chassis_fan_health != 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Fan unhealthy on R730 - check iDRAC"
      - name: Nvidia Tesla T4 GPU
        rules:
          - alert: HighGPUTemp
            expr: nvidia_tesla_t4_DCGM_FI_DEV_GPU_TEMP > 65
            for: 3m  # bumped from 1m for global scrape_interval=2m
            labels:
              severity: warning
            annotations:
              summary: "GPU temp: {{ $value | printf \"%.0f\" }}°C (threshold: 65°C)"
          - alert: HighPowerUsage
            expr: nvidia_tesla_t4_DCGM_FI_DEV_POWER_USAGE > 50
            for: 30m
            labels:
              severity: info
              subsystem: gpu
            annotations:
              summary: "GPU power: {{ $value | printf \"%.0f\" }}W (threshold: 50W)"
          - alert: HighUtilization
            expr: nvidia_tesla_t4_DCGM_FI_DEV_GPU_UTIL > 50
            for: 30m
            labels:
              severity: info
            annotations:
              summary: "GPU util: {{ $value | printf \"%.0f\" }}% (threshold: 50%)"
          - alert: HighMemoryUsage
            expr: nvidia_tesla_t4_DCGM_FI_DEV_FB_USED / 1024 > 14
            for: 15m
            labels:
              severity: info
            annotations:
              summary: "VRAM used: {{ $value | printf \"%.1f\" }} GB (threshold: 14 GB)"
          - alert: NvidiaExporterDown
            expr: absent(nvidia_tesla_t4_DCGM_FI_DEV_GPU_TEMP) == 1
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "NVIDIA GPU exporter is down - no GPU metrics available"
          - alert: GPUNodeUnschedulable
            expr: kube_node_spec_unschedulable{node="k8s-node1"} == 1
            for: 5m
            labels:
              severity: critical
              subsystem: gpu
            annotations:
              summary: "GPU node {{ $labels.node }} is cordoned — Frigate and GPU workloads cannot schedule"
      - name: Power
        rules:
          - alert: OnBattery
            expr: ups_upsSecondsOnBattery > 0
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "UPS on battery: {{ $value | printf \"%.0f\" }}s"
          - alert: LowUPSBattery
            expr: ups_upsEstimatedMinutesRemaining < 25 and on(instance) ups_upsInputVoltage < 150
            for: 3m  # bumped from 1m for global scrape_interval=2m; snmp-ups job pinned to 30s
            labels:
              severity: critical
            annotations:
              summary: "UPS battery low: {{ $value | printf \"%.0f\" }} min remaining (threshold: 25 min)"
          - alert: PowerOutage
            expr: ups_upsInputVoltage < 150
            for: 3m  # bumped from 1m for global scrape_interval=2m; snmp-ups job pinned to 30s
            labels:
              severity: critical
            annotations:
              summary: "Power outage - input voltage: {{ $value | printf \"%.0f\" }}V (threshold: <150V)"
          - alert: HighPowerUsage
            expr: r730_idrac_idrac_power_control_consumed_watts > 300
            for: 60m
            labels:
              severity: info
              subsystem: r730
            annotations:
              summary: "Server power: {{ $value | printf \"%.0f\" }}W (threshold: 300W)"
          - alert: UsingInverterEnergyForTooLong
            expr: automatic_transfer_switch_power_mode > 0 and on() ups_upsEstimatedChargeRemaining < 80
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "On inverter with battery draining ({{ $value }}% charge) - may be stuck on inverter"
          - alert: UPSAlarmsActive
            expr: ups_upsAlarmsPresent > 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "UPS has {{ $value }} active alarm(s)"
          - alert: UPSBatteryDegraded
            expr: ups_upsBatteryStatus != 2
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "UPS battery status abnormal ({{ $value }}, expected 2=normal)"
          - alert: UPSOverloaded
            expr: ups_upsOutputPercentLoad{upsOutputLineIndex="1"} > 80
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "UPS load: {{ $value }}% (threshold: 80%)"
          - alert: UPSOutputVoltageAbnormal
            expr: ups_upsOutputVoltage{upsOutputLineIndex="1"} < 210 or ups_upsOutputVoltage{upsOutputLineIndex="1"} > 250
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "UPS output voltage: {{ $value }}V (expected 210-250V)"
          - alert: ATSFault
            expr: automatic_transfer_switch_fault != 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "ATS fault detected (value: {{ $value }})"
          - alert: ATSPowerFault
            expr: automatic_transfer_switch_power_fault != 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "ATS power fault detected (value: {{ $value }})"
          - alert: ATSOverload
            expr: automatic_transfer_switch_load_power_watts > 3000
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "ATS load: {{ $value | printf \"%.0f\" }}W (threshold: 3000W)"
          - alert: ATSInputVoltageAbnormal
            expr: automatic_transfer_switch_voltage_l1_volts < 200 or automatic_transfer_switch_voltage_l1_volts > 260
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "ATS input voltage: {{ $value | printf \"%.0f\" }}V (expected 200-260V)"
      - name: Server Health
        rules:
          - alert: iDRACSystemUnhealthy
            expr: r730_idrac_redfish_system_health_state != 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "iDRAC system health state: {{ $value }} (expected 1=OK)"
          - alert: iDRACPowerSupplyUnhealthy
            expr: r730_idrac_redfish_chassis_power_powersupply_health != 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "iDRAC PSU {{ $labels.member_id }} unhealthy (state: {{ $value }})"
          - alert: iDRACMemoryUnhealthy
            expr: r730_idrac_redfish_system_memory_health_state != 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "iDRAC memory subsystem unhealthy (state: {{ $value }})"
          - alert: iDRACStorageDriveUnhealthy
            expr: r730_idrac_redfish_system_storage_drive_health_state != 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "iDRAC storage drive {{ $labels.member_id }} unhealthy (state: {{ $value }})"
          - alert: iDRACSSDWearCritical
            expr: r730_idrac_idrac_storage_drive_life_left_percent > 0 and r730_idrac_idrac_storage_drive_life_left_percent < 10
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "SSD {{ $labels.id }} has {{ $value }}% life remaining"
          - alert: iDRACSSDWearWarning
            expr: r730_idrac_idrac_storage_drive_life_left_percent > 0 and r730_idrac_idrac_storage_drive_life_left_percent < 20
            for: 6h
            labels:
              severity: warning
            annotations:
              summary: "SSD {{ $labels.id }} has {{ $value }}% life remaining"
          - alert: iDRACServerPoweredOff
            expr: r730_idrac_redfish_system_power_state != 2
            for: 3m
            labels:
              severity: critical
            annotations:
              summary: "R730 server is not powered on (state: {{ $value }}, expected 2=On)"
          - alert: ProxmoxExporterDown
            expr: pve_up{id="node/pve"} == 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Proxmox exporter cannot reach PVE host"
          - alert: FuseMainFault
            expr: fuse_main_fault != 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Main fuse panel fault detected"
          - alert: FuseGarageFault
            expr: fuse_garage_fault != 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Garage fuse panel fault detected"
          - alert: FuseMainHighLeakage
            expr: fuse_main_leakage_current > 30
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Main fuse leakage current: {{ $value }}mA (threshold: 30mA)"
          - alert: FuseGarageHighLeakage
            expr: fuse_garage_leakage_current > 30
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Garage fuse leakage current: {{ $value }}mA (threshold: 30mA)"
          - alert: FuseMainOvertemperature
            expr: fuse_main_temperature > 70
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Main fuse temperature: {{ $value }}°C (threshold: 70°C)"
          - alert: FuseGarageOvertemperature
            expr: fuse_garage_temperature > 70
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Garage fuse temperature: {{ $value }}°C (threshold: 70°C)"
          - alert: FuseMainVoltageAbnormal
            expr: fuse_main_voltage / 10 < 200 or fuse_main_voltage / 10 > 260
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Main fuse voltage: {{ $value }}V (expected 200-260V)"
          - alert: FuseGarageVoltageAbnormal
            expr: fuse_garage_voltage / 10 < 200 or fuse_garage_voltage / 10 > 260
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Garage fuse voltage: {{ $value }}V (expected 200-260V)"
      - name: Thermostats
        rules:
          - alert: ThermostatOverheating
            expr: >
              thermostat_hol_temp_current > 400
              or thermostat_master_bedroom_temp_current > 400
              or thermostat_office_temp_current > 400
              or thermostat_kids_room_temp_current > 400
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Thermostat temperature {{ $value | printf \"%.1f\" }} (x10 °C) exceeds 40°C"
          - alert: ThermostatFreezing
            expr: >
              thermostat_hol_temp_current < 50
              or thermostat_master_bedroom_temp_current < 50
              or thermostat_office_temp_current < 50
              or thermostat_kids_room_temp_current < 50
            for: 15m
            labels:
              severity: critical
            annotations:
              summary: "Thermostat temperature {{ $value | printf \"%.1f\" }} (x10 °C) below 5°C — risk of freezing"
          - alert: ThermostatHumidityHigh
            expr: >
              thermostat_hol_humidity > 80
              or thermostat_master_bedroom_humidity > 80
              or thermostat_office_humidity > 80
              or thermostat_kids_room_humidity > 80
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Thermostat humidity {{ $value }}% exceeds 80%"
      - name: Metric Staleness
        rules:
          - alert: UPSMetricsMissing
            expr: absent(ups_upsInputVoltage)
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "UPS metrics missing for 10m - check SNMP exporter and ups.viktorbarzin.lan"
          - alert: iDRACRedfishMetricsMissing
            expr: absent(r730_idrac_idrac_power_supply_input_voltage)
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "iDRAC Redfish metrics missing for 10m - check idrac-redfish-exporter pod"
          - alert: iDRACSNMPMetricsMissing
            expr: absent(r730_idrac_idrac_system_health)
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "iDRAC SNMP metrics missing for 10m - check SNMP exporter and idrac.viktorbarzin.lan"
          - alert: ATSMetricsMissing
            expr: absent(automatic_transfer_switch_power_mode)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "ATS metrics missing for 15m - check tuya-bridge pod"
          - alert: FuseMainMetricsMissing
            expr: absent(fuse_main_voltage)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Fuse main panel metrics missing for 15m - check tuya-bridge pod"
          - alert: FuseGarageMetricsMissing
            expr: absent(fuse_garage_voltage)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Fuse garage panel metrics missing for 15m - check tuya-bridge pod"
          - alert: ThermostatHolMetricsMissing
            expr: absent(thermostat_hol_temp_current)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Thermostat hol metrics missing for 15m - check tuya-bridge pod"
          - alert: ThermostatMasterBedroomMetricsMissing
            expr: absent(thermostat_master_bedroom_temp_current)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Thermostat master bedroom metrics missing for 15m - check tuya-bridge pod"
          - alert: ThermostatOfficeMetricsMissing
            expr: absent(thermostat_office_temp_current)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Thermostat office metrics missing for 15m - check tuya-bridge pod"
          - alert: ThermostatKidsRoomMetricsMissing
            expr: absent(thermostat_kids_room_temp_current)
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Thermostat kids room metrics missing for 15m - check tuya-bridge pod"
          - alert: TuyaCloudDown
            expr: count(({__name__=~".*_tuya_cloud_up"}) == 0) > 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Tuya Cloud API rejecting calls ({{ $value }} devices affected) — renew subscription at iot.tuya.com (code 28841002 = expired trial) or rotate TINYTUYA_API_KEY"
          - alert: ProxmoxMetricsMissing
            expr: absent(pve_up)
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Proxmox metrics missing for 10m - check proxmox-exporter pod"
          - alert: HomeAssistantMetricsMissing
            expr: absent(up{job="haos"})
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Home Assistant (ha-sofia) metrics missing for 10m - check HA Prometheus integration"
      - name: Storage
        rules:
          - alert: NodeFilesystemFull
            expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes) * 100 < 10
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}% free (threshold: 10%)"
          # PVAutoExpanding removed — was info-only at >80% used, but
          # pvc-autoresizer's threshold is 10% free (= 90% used), so the
          # alert always fired ~10 percentage points before any action
          # was needed. Real failures are caught by PVFillingUp (autoresizer
          # didn't keep up) and PVPredictedFull (trend toward exhaustion).
          - alert: PVFillingUp
            expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 95 and kubelet_volume_stats_capacity_bytes < 1099511627776
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "PV {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }}: {{ $value | printf \"%.0f\" }}% used — pvc-autoresizer didn't expand in time (storage_limit reached, expansion failing, or no autoresizer annotations)"
          - alert: PVPredictedFull
            expr: predict_linear(kubelet_volume_stats_used_bytes[6h], 3600*24) > kubelet_volume_stats_capacity_bytes and kubelet_volume_stats_capacity_bytes < 1099511627776
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "PV {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }}: predicted full within 24h (current projected: {{ $value | humanize1024 }}B)"
          - alert: NFSServerUnresponsive
            expr: |
              (
                count by () (
                  sum by (instance) (changes(node_nfs_requests_total[15m])) > 0
                ) or on() vector(0)
              ) < 2
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "Only {{ $value | printf \"%.0f\" }} node(s) have NFS activity — Proxmox NFS (192.168.1.127) may be down (need ≥2)"
      - name: K8s Health
        rules:
          - alert: PodCrashLooping
            expr: kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.pod }}: stuck in CrashLoopBackOff"
          - alert: ContainerOOMKilled
            expr: increase(container_oom_events_total{container!=""}[15m]) > 0 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }}: {{ $value | printf \"%.0f\" }} OOM kill(s) in 15m"
          - alert: PodUnschedulable
            expr: kube_pod_status_conditions{condition="PodScheduled", status="false"} == 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.pod }}: unschedulable — check resource requests and node affinity"
          - alert: NodeNotReady
            expr: kube_node_status_condition{condition="Ready",status="true"} == 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Node {{ $labels.node }} is NotReady"
          - alert: NodeConditionBad
            expr: kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"} == 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.node }}: {{ $labels.condition }} active"
          # `for: 2h` requires the failure to persist across at least 2
          # cron iterations of a typical 5-min/15-min/1h job before paging —
          # transient single-run failures (network blip, upstream timeout)
          # are recovered by the next iteration without alerting.
          - alert: JobFailed
            expr: |
              kube_job_status_failed > 0
              and on(namespace, job_name)
              (time() - kube_job_status_start_time) < 3600
            for: 2h
            labels:
              severity: warning
            annotations:
              summary: "Job {{ $labels.namespace }}/{{ $labels.job_name }}: {{ $value | printf \"%.0f\" }} failure(s)"
          # `KubeletImagePullErrors` measures node-level pull-error rate,
          # which is too coarse to catch one pod stuck in ImagePullBackOff.
          # Council-complaints sat in ImagePullBackOff for 10h on 2026-05-12
          # without paging because the rate stayed below threshold.
          - alert: PodImagePullBackOff
            expr: |
              sum by (namespace, pod, container) (
                kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|ErrImagePull|InvalidImageName"}
              ) > 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) cannot pull image"
              description: "Check the deployment's image reference — often a stale tag, a removed registry, or a credentials mismatch. `kubectl -n {{ $labels.namespace }} describe pod {{ $labels.pod }}` shows the pull error."
          # N-1 capacity check: if any non-GPU worker (node2/3/4) died, would
          # its memory requests fit on the remaining Ready workers (incl. node1
          # GPU node — its taint is PreferNoSchedule, soft)? Fires when the
          # most-loaded non-GPU worker holds more memory requests than the rest
          # of the cluster has free.
          - alert: ClusterCannotTolerateNonGpuNodeLoss
            expr: |
              max(
                sum by (node) (
                  kube_pod_container_resource_requests{resource="memory",unit="byte",node=~"k8s-node[234]"}
                )
              )
              >
              sum(
                clamp_min(
                  kube_node_status_allocatable{resource="memory",unit="byte",node=~"k8s-node[1234]"}
                  - on(node) group_left() sum by (node) (
                      kube_pod_container_resource_requests{resource="memory",unit="byte",node=~"k8s-node[1234]"}
                    ),
                  0
                )
                and on(node) (kube_node_status_condition{condition="Ready",status="true"} == 1)
              )
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Cluster cannot tolerate losing any non-GPU worker — memory requests won't fit on the rest"
              description: |
                The most-loaded non-GPU worker (k8s-node2/3/4) has more memory
                requests pinned to it than the rest of the workers (incl. node1
                GPU node) currently have free. If that node went down, its
                pods would not reschedule and stay Pending.
                Remediation: right-size top reservers via Goldilocks (immich-server,
                frigate, prometheus, pg-cluster, paperless) or bump VM RAM on
                k8s-node2/k8s-node3 from 32GB → 48GB to match node1.
      - name: Infrastructure Health
        rules:
          - alert: HomeAssistantDown
            expr: up{job="haos"} == 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Home Assistant down: {{ $labels.instance }}"
          - alert: HomeAssistantCriticalSensorUnavailable
            expr: haos_entity_available{entity=~"sensor\\.(tesla_t4_gpu_(temperature|power_usage|utilization|memory_used)|r730_(cpu_temperature|power_consumption|power_supply_input_voltage_[12]|system_board_(exhaust|inlet)_temperature)|ups_(input_voltage|output_voltage|load|battery_remaining|output_source))"} == 0
            for: 15m
            labels:
              severity: critical
            annotations:
              summary: "HA sensor unavailable: {{ $labels.friendly_name }} ({{ $labels.entity }})"
              description: "{{ $labels.entity }} on {{ $labels.instance }} has been unavailable for 15+ minutes. Common cause: REST sensor needs HA restart (reload_all doesn't rebuild rest: platform). Verify exporter endpoint from HA: `ssh vbarzin@192.168.1.8` → `curl -sk <exporter-url>`. Fix: `curl -X POST -H \"Authorization: Bearer $HOME_ASSISTANT_SOFIA_TOKEN\" $HOME_ASSISTANT_SOFIA_URL/api/services/homeassistant/restart`."
          - alert: CoreDNSErrors
            expr: rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]) > 1 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "CoreDNS SERVFAIL rate: {{ $value | printf \"%.1f\" }}/s (threshold: 1/s)"
          - alert: ScrapeTargetDown
            expr: up{job!~"istiod|envoy-stats|openwrt"} == 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Scrape target down: {{ $labels.job }}/{{ $labels.instance }}"
          - alert: PrometheusStorageFull
            expr: (prometheus_tsdb_storage_blocks_bytes / (1024*1024*1024)) > 150
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Prometheus TSDB: {{ $value | printf \"%.0f\" }} GiB (threshold: 150 GiB)"
          - alert: PrometheusNotificationsFailing
            expr: rate(prometheus_notifications_errors_total[5m]) > 0
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Prometheus notification errors: {{ $value | printf \"%.2f\" }}/s"
          - alert: EtcdBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="backup-etcd", namespace="default"}) > 691200
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "etcd backup is {{ $value | humanizeDuration }} old (threshold: 8d)"
          - alert: EtcdBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="backup-etcd", namespace="default"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "etcd backup CronJob has never completed successfully"
          - alert: PostgreSQLBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="postgresql-backup", namespace="dbaas"}) > 129600
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "PostgreSQL backup is {{ $value | humanizeDuration }} old (threshold: 36h)"
          - alert: PostgreSQLBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="postgresql-backup", namespace="dbaas"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "PostgreSQL backup CronJob has never completed successfully"
          - alert: MySQLBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="mysql-backup", namespace="dbaas"}) > 129600
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "MySQL backup is {{ $value | humanizeDuration }} old (threshold: 36h)"
          - alert: MySQLBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="mysql-backup", namespace="dbaas"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "MySQL backup CronJob has never completed successfully"
          - alert: VaultBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="vault-raft-backup", namespace="vault"}) > 691200
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "Vault backup is {{ $value | humanizeDuration }} old (threshold: 8d)"
          - alert: VaultBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="vault-raft-backup", namespace="vault"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "Vault backup CronJob has never completed successfully"
          - alert: VaultRaftLeaderStuck
            expr: |
              (vault_core_active == 1)
              and on(instance)
              (rate(vault_raft_last_index_gauge[5m]) == 0)
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Vault raft leader {{ $labels.instance }} is active but commit index has not advanced for >2m"
              description: "The raft leader is reachable on TCP but its commit index has stalled — likely a stuck goroutine hang (see 2026-04-22 post-mortem). External /v1/sys/health will be 503. Recovery: graceful delete of the stuck pod (see docs/runbooks/vault-raft-leader-deadlock.md). NOTE: silent until vault telemetry + scrape job are enabled."
          - alert: VaultHAStatusUnavailable
            expr: |
              (count(up{job="vault"} == 1) > 0)
              and
              (count(vault_core_active == 1) == 0)
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Vault pods are Up but no pod reports HA active leader"
              description: "At least one Vault pod is scraping healthy, but no pod has vault_core_active=1. HA layer is broken — external endpoint will be 503 even though the pods themselves are alive. See docs/runbooks/vault-raft-leader-deadlock.md. NOTE: silent until vault telemetry + scrape job are enabled."
          - alert: VaultwardenBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="vaultwarden-backup", namespace="vaultwarden"}) > 86400
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "Vaultwarden backup is {{ $value | humanizeDuration }} old (threshold: 24h, runs every 6h)"
          - alert: VaultwardenBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="vaultwarden-backup", namespace="vaultwarden"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "Vaultwarden backup CronJob has never completed successfully"
          - alert: MailserverBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="mailserver-backup", namespace="mailserver"}) > 129600
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "Mailserver backup is {{ $value | humanizeDuration }} old (threshold: 36h, runs daily 03:00)"
          - alert: MailserverBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="mailserver-backup", namespace="mailserver"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "Mailserver backup CronJob has never completed successfully"
          - alert: VaultwardenDown
            expr: (kube_deployment_status_replicas_available{namespace="vaultwarden", deployment="vaultwarden"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Vaultwarden has no available replicas — password manager down"
          - alert: VaultwardenSQLiteCorrupt
            expr: vaultwarden_sqlite_integrity_ok == 0
            for: 0m
            labels:
              severity: critical
            annotations:
              summary: "Vaultwarden SQLite database failed integrity check — data corruption detected"
          - alert: VaultwardenIntegrityCheckStale
            expr: (time() - vaultwarden_sqlite_integrity_check_timestamp) > 7200
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Vaultwarden integrity check hasn't run in {{ $value | humanizeDuration }} (expected hourly)"
          - alert: RedisBackupStale
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="redis-backup", namespace="redis"}) > 691200
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "Redis backup is {{ $value | humanizeDuration }} old (threshold: 8d)"
          - alert: RedisBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="redis-backup", namespace="redis"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "Redis backup CronJob has never completed successfully"
          - alert: PrometheusBackupStale
            expr: (time() - prometheus_backup_last_success_timestamp{job="prometheus-backup"}) > 2764800
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "Prometheus backup is {{ $value | humanizeDuration }} old (threshold: 32d)"
          - alert: PrometheusBackupNeverRun
            expr: absent(prometheus_backup_last_success_timestamp{job="prometheus-backup"})
            for: 32d
            labels:
              severity: warning
            annotations:
              summary: "Prometheus backup has never reported a successful run (sidecar runs monthly, 1st Sunday 04:00 UTC — alert only fires if absent for >32d)"
          - alert: CSIDriverCrashLoop
            expr: kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", namespace=~"nfs-csi|proxmox-csi"} > 0
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "CSI driver CrashLoopBackOff in {{ $labels.namespace }}/{{ $labels.pod }} — storage-layer failure risk"
          - alert: BackupCronJobFailed
            expr: kube_job_status_failed{job_name=~".*backup.*"} > 0
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Backup job failed: {{ $labels.namespace }}/{{ $labels.job_name }}"
          - alert: LVMSnapshotStale
            expr: (time() - lvm_snapshot_last_run_timestamp{job="lvm-pvc-snapshot"}) > 108000
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "LVM PVC snapshots are {{ $value | humanizeDuration }} old (expected daily)"
              description: "Timer lvm-pvc-snapshot.timer on 192.168.1.127 hasn't pushed fresh metrics. Runbook: docs/runbooks/restore-lvm-snapshot.md"
          - alert: LVMSnapshotNeverRun
            expr: absent(lvm_snapshot_last_run_timestamp{job="lvm-pvc-snapshot"})
            for: 48h
            labels:
              severity: warning
            annotations:
              summary: "LVM PVC snapshot job has never reported metrics to Pushgateway"
          - alert: LVMSnapshotFailing
            expr: lvm_snapshot_last_status{job="lvm-pvc-snapshot"} != 0
            for: 0m
            labels:
              severity: critical
            annotations:
              summary: "LVM PVC snapshot job failed (status={{ $value }})"
          - alert: LVMThinPoolLow
            expr: lvm_snapshot_thinpool_free_pct{job="lvm-pvc-snapshot"} < 15
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "LVM thin pool has only {{ $value }}% free — snapshot overhead may cause pool exhaustion"
          # --- 3-2-1 Backup Pipeline Alerts ---
          - alert: WeeklyBackupStale
            expr: (time() - daily_backup_last_run_timestamp{job="daily-backup"}) > 777600
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Daily backup is {{ $value | humanizeDuration }} old (threshold: 9d)"
          - alert: WeeklyBackupFailing
            expr: daily_backup_last_status{job="daily-backup"} != 0
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "Daily backup completed with errors (status={{ $value }})"
          - alert: PfsenseBackupStale
            expr: (time() - backup_last_success_timestamp{job="pfsense-backup"}) > 777600
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "pfsense backup is {{ $value | humanizeDuration }} old (threshold: 9d)"
          - alert: OffsiteBackupSyncStale
            expr: (time() - backup_last_success_timestamp{job="offsite-backup-sync"}) > 777600
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Offsite backup sync is {{ $value | humanizeDuration }} old (threshold: 9d)"
          - alert: OffsiteBackupSyncFailing
            expr: offsite_sync_last_status{job="offsite-backup-sync"} != 0
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "Offsite backup sync last run reported errors (status={{ $value }})"
          - alert: NfsMirrorStale
            expr: (time() - nfs_mirror_last_run_timestamp{job="nfs-mirror"}) > 1382400
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "NFS local mirror to sda is {{ $value | humanizeDuration }} old (threshold: 16d / 2 weekly cycles)"
          - alert: NfsMirrorFailing
            expr: nfs_mirror_last_status{job="nfs-mirror"} != 0
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "NFS local mirror last run failed (status={{ $value }})"
          - alert: BackupDiskFull
            expr: (1 - node_filesystem_avail_bytes{job="proxmox-host", mountpoint="/mnt/backup"} / node_filesystem_size_bytes{job="proxmox-host", mountpoint="/mnt/backup"}) > 0.85
            for: 15m
            labels:
              severity: critical
            annotations:
              summary: "Backup disk /mnt/backup is {{ $value | humanizePercentage }} full"
          - alert: NewTailscaleClient
            expr: irate(headscale_machine_registrations_total{action="reauth"}[5m]) > 0
            for: 5m
            labels:
              severity: info
            annotations:
              summary: "New Tailscale client registered ({{ $value | printf \"%.2f\" }} reauth/s)"
          - alert: CrowdSecDown
            expr: up{job="crowdsec"} == 0
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "CrowdSec LAPI down — WAF/IDS degraded (Traefik plugin fails open)"
          - alert: KyvernoDown
            expr: (kube_deployment_status_replicas_available{namespace="kyverno", deployment="kyverno-admission-controller"} or on() vector(0)) < 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Kyverno admission controller down — policy enforcement disabled"
          - alert: SealedSecretsDown
            expr: (kube_deployment_status_replicas_available{namespace="sealed-secrets", deployment="sealed-secrets"} or on() vector(0)) < 1
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Sealed Secrets controller down — new secrets can't be decrypted"
          - alert: WoodpeckerDown
            expr: (kube_statefulset_status_replicas_ready{namespace="woodpecker", statefulset="woodpecker-server"} or on() vector(0)) < 1
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Woodpecker CI server down — CI/CD pipelines not running"
      - name: Critical Services
        rules:
          - alert: PostgreSQLDown
            expr: kube_pod_status_ready{namespace="dbaas", pod=~"pg-cluster-.*", condition="true"} != 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "PostgreSQL pod {{ $labels.pod }} is not ready"
          - alert: RedisDown
            expr: (kube_statefulset_status_replicas_ready{namespace="redis", statefulset="redis-v2"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Redis is down — statefulset redis-v2 has no ready pod"
          - alert: RedisMemoryPressure
            # Single instance, volatile-lru (2026-05-30): at maxmemory, TTL'd
            # (cache) keys are evicted but TTL-less keys (Immich BullMQ + Celery
            # jobs) are NOT — so once cache headroom is gone, queue writes start
            # erroring. 80% is the backstop to intervene (bump maxmemory) first.
            expr: redis_memory_used_bytes{namespace="redis"} / redis_memory_max_bytes{namespace="redis"} > 0.80
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Redis pod {{ $labels.pod }} using {{ $value | humanizePercentage }} of maxmemory — volatile-lru evicting cache keys; queue writes at risk"
          - alert: RedisEvictions
            # volatile-lru evicts only TTL'd (cache) keys under pressure — an
            # occasional eviction is by design, but a sustained rate means we're
            # near maxmemory and should raise it before queue writes error.
            expr: rate(redis_evicted_keys_total{namespace="redis"}[5m]) > 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Redis pod {{ $labels.pod }} evicting keys ({{ $value }} keys/s) — near maxmemory"
          - alert: RedisForkLatencyHigh
            # latest_fork_usec > 500ms means BGSAVE fork is stalling the main
            # thread long enough to drop client requests. COW pressure or
            # constrained memory headroom are the usual causes.
            expr: redis_latest_fork_usec{namespace="redis"} > 500000
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "Redis pod {{ $labels.pod }} fork took {{ $value }}us (>500ms) — investigate memory headroom"
          - alert: RedisAOFRewriteLong
            expr: redis_aof_rewrite_in_progress{namespace="redis"} == 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Redis pod {{ $labels.pod }} AOF rewrite running >10m — COW memory risk, investigate"
          - alert: HeadscaleReplicasMismatch
            expr: (kube_deployment_status_replicas_available{namespace="headscale"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Headscale VPN has no available replicas"
          - alert: AuthentikDown
            expr: (kube_deployment_status_replicas_available{namespace="authentik", deployment="goauthentik-server"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Authentik auth server has no available replicas"
          - alert: PoisonFountainDown
            expr: |
              kube_deployment_spec_replicas{namespace="poison-fountain", deployment="poison-fountain"} > 0
              and (kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Poison Fountain is down - AI bot blocking degraded to fail-open"
          - alert: PgBouncerDown
            expr: (kube_deployment_status_replicas_available{namespace="authentik", deployment="pgbouncer"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "PgBouncer down — Authentik cannot reach PostgreSQL"
          - alert: CNPGOperatorDown
            expr: (kube_deployment_status_replicas_available{namespace="cnpg-system", deployment="cnpg-cloudnative-pg"} or on() vector(0)) < 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "CNPG operator down — PostgreSQL failover/management degraded"
          - alert: PGConnectionsHigh
            # Per-cluster connection utilisation. Sums per-database backend
            # counts on each pod, then takes max across pods (primary holds
            # the real workload; replicas only have streaming_replica conns).
            expr: (max by (cnpg_cluster) (sum by (cnpg_cluster, instance) (cnpg_backends_total))) / (max by (cnpg_cluster) (cnpg_pg_settings_setting{name="max_connections"})) > 0.85
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "PostgreSQL {{ $labels.cnpg_cluster }}: connection utilisation {{ $value | humanizePercentage }} — approaching max_connections ceiling"
          - alert: PGConnectionsCritical
            expr: (max by (cnpg_cluster) (sum by (cnpg_cluster, instance) (cnpg_backends_total))) / (max by (cnpg_cluster) (cnpg_pg_settings_setting{name="max_connections"})) > 0.95
            for: 3m
            labels:
              severity: critical
            annotations:
              summary: "PostgreSQL {{ $labels.cnpg_cluster }}: connection utilisation {{ $value | humanizePercentage }} — new client connections will be refused soon. Bump max_connections or reap idle backends."
      - name: Cluster
        rules:
          - alert: NodeDown
            expr: (up{job="kubernetes-nodes"} or on() vector(0)) == 0
            for: 3m
            labels:
              severity: critical
            annotations:
              summary: "Node down: {{ $labels.instance }}"
          - alert: DockerRegistryDown
            expr: (registry_process_start_time_seconds or on() vector(0)) == 0
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Docker registry down for 10m"
          - alert: RegistryLowCacheHitRate
            expr: (sum by (job) (rate(registry_registry_storage_cache_total{type="Hit"}[15m]))) / (sum by (job) (rate(registry_registry_storage_cache_total{type="Request"}[15m]))) * 100 < 25
            for: 12h
            labels:
              severity: info
            annotations:
              summary: "Registry cache hit rate: {{ $value | printf \"%.0f\" }}% (threshold: 25%)"
          - alert: RegistryManifestIntegrityFailure
            expr: registry_manifest_integrity_failures > 0
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "{{ $labels.instance }}: {{ $value }} broken manifest reference(s) — orphan index or missing blob"
              description: "The forgejo-integrity-probe CronJob found {{ $value }} manifest/blob references that return non-200 on {{ $labels.instance }}. Rebuild the affected image per docs/runbooks/forgejo-registry-rebuild-image.md. (registry.viktorbarzin.me retired Phase 4 of forgejo-registry-consolidation 2026-05-07 — only forgejo.viktorbarzin.me remains.)"
          - alert: RegistryIntegrityProbeStale
            expr: time() - registry_manifest_integrity_last_run_timestamp > 3600
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.instance }} integrity probe has not reported in >1h — CronJob may be broken"
          - alert: RegistryCatalogInaccessible
            expr: registry_manifest_integrity_catalog_accessible == 0
            for: 15m
            labels:
              severity: critical
            annotations:
              summary: "{{ $labels.instance }} probe cannot fetch /v2/_catalog — auth failure or registry down"
          - alert: NodeHighCPUUsage
            expr: pve_cpu_usage_ratio * 100 > 60
            for: 6h
            labels:
              severity: info
            annotations:
              summary: "CPU usage on {{ $labels.node }}: {{ $value | printf \"%.0f\" }}% (threshold: 60%)"
          # - name: PodStuckNotReady
          #   rules:
          #   - alert: PodStuckNotReady
          #     expr: kube_pod_status_ready{condition="true"} == 0
          #     for: 5m
          #     labels:
          #       severity: page
          #     annotations:
          #       summary: Pod stuck not ready.
          - alert: DeploymentReplicasMismatch
            expr: |
              (
                kube_deployment_spec_replicas
                - on(namespace, deployment) kube_deployment_status_replicas_available
              ) > 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.deployment }}: {{ $value | printf \"%.0f\" }} replica(s) unavailable"
          - alert: StatefulSetReplicasMismatch
            expr: |
              (
                kube_statefulset_replicas
                - on(namespace, statefulset) kube_statefulset_status_replicas_ready
              ) > 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.statefulset }}: {{ $value | printf \"%.0f\" }} replica(s) unavailable"
          - alert: DaemonSetMissingPods
            expr: |
              (
                kube_daemonset_status_desired_number_scheduled
                - on(namespace, daemonset) kube_daemonset_status_number_ready
              ) > 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.daemonset }}: {{ $value | printf \"%.0f\" }} pod(s) missing"
          - alert: NodeExporterDown
            expr: up{job="prometheus-prometheus-node-exporter"} == 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Node exporter down: {{ $labels.instance }}"
          - alert: NodeHighIOWait
            expr: avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100 > 30
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "IOWait on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}% (threshold: 30%)"
          - alert: NoNodeLoadData
            expr: absent(node_load1)
            for: 10m
            labels:
              severity: info
            annotations:
              summary: "No node load data for 10m - check Prometheus scraping"
      - name: "Node Runtime Health"
        rules:
          - alert: KubeletImagePullErrors
            expr: sum by (node) (rate(kubelet_runtime_operations_errors_total{operation_type=~"pull_image|PullImage"}[10m])) > 0.1
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "Image pull errors on {{ $labels.node }}: {{ $value | printf \"%.2f\" }}/s — containerd may be broken"
          - alert: KubeletPLEGUnhealthy
            expr: (time() - kubelet_pleg_last_seen_seconds) > 180
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "PLEG on {{ $labels.instance }} not seen for {{ $value | printf \"%.0f\" }}s — kubelet lifecycle management broken"
          - alert: PodsStuckContainerCreating
            expr: count by (node) (kube_pod_container_status_waiting_reason{reason="ContainerCreating"} == 1) > 3
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "{{ $value | printf \"%.0f\" }} pods stuck in ContainerCreating on {{ $labels.node }}"
          - alert: KubeletRuntimeOperationsLatency
            expr: histogram_quantile(0.99, sum by (instance, operation_type, le) (rate(kubelet_runtime_operations_duration_seconds_bucket[10m]))) > 60
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Kubelet {{ $labels.operation_type }} p99: {{ $value | printf \"%.0f\" }}s on {{ $labels.instance }} (threshold: 30s)"
          - alert: KubeletRunningContainersDrop
            # Relative >50% drop vs. 10m ago, sustained for 5m.
            # Absolute-count threshold removed 2026-05-18: routine drains
            # routinely drop 10-30 containers and tripped the old `< -10`
            # rule; only a >50% drop that persists 5m+ indicates a real
            # node-level fault (kubelet hang, runtime crash, mass eviction).
            expr: |
              (
                (kubelet_running_containers{container_state="running"} - kubelet_running_containers{container_state="running"} offset 10m)
                / kubelet_running_containers{container_state="running"} offset 10m
              ) < -0.5
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Running containers on {{ $labels.instance }} dropped >50% in 10m ({{ $value | printf \"%.2f\" }} ratio)"
          - alert: CalicoNodeNotReady
            expr: kube_daemonset_status_number_ready{namespace="calico-system", daemonset="calico-node"} < kube_daemonset_status_desired_number_scheduled{namespace="calico-system", daemonset="calico-node"}
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Calico: only {{ $value | printf \"%.0f\" }} of desired calico-node pods ready — networking degraded"
      # Upgrade Gates: any firing alert here halts kured rolling reboots via
      # --prometheus-url + alertFilterRegexp ignore-list (see stacks/kured/main.tf).
      # These are silent-failure detectors and cluster-health velocity signals
      # that catch cascade-style failures (March 2026 26h outage class).
      - name: "Upgrade Gates"
        rules:
          - alert: KubeAPIServerDown
            expr: up{job="kubernetes-apiservers"} == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Kubernetes apiserver {{ $labels.instance }} is down — control plane degraded, blocks kured"
          - alert: KubeStateMetricsDown
            expr: absent(kube_node_info)
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "kube-state-metrics not responding — many alerts are SILENT until this is fixed"
          - alert: PrometheusRuleEvaluationFailing
            expr: increase(prometheus_rule_evaluation_failures_total[10m]) > 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Prometheus rule evaluation failing — alerting itself is degraded ({{ $value | printf \"%.0f\" }} failures in 10m)"
          - alert: PVCStuckPending
            expr: kube_persistentvolumeclaim_status_phase{phase="Pending"} == 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} stuck Pending for 10m+"
          # RecentNodeReboot — kubelet just restarted, give the node some time
          # to settle before any other reboot-driving thing (kured, K8s
          # version-upgrade chain) acts. Threshold tightened from 86400 →
          # 3600 on 2026-05-17 — post-reboot workloads (calico-node,
          # kube-proxy, CSI sidecars, GPU drivers) typically reconverge
          # within minutes; 1h is comfortable margin. The 24h-between-
          # cluster-reboots protection lives separately in
          # `kured-sentinel-gate` Check 4 (reads node Ready
          # lastTransitionTime, independent of this alert).
          - alert: RecentNodeReboot
            expr: (time() - process_start_time_seconds{job="kubernetes-nodes"}) < 3600
            for: 0m
            labels:
              severity: info
            annotations:
              summary: "Node {{ $labels.node }} kubelet started {{ $value | humanizeDuration }} ago — 1h settle window halts further reboots"
          - alert: MysqlStandaloneDown
            # Single-replica StatefulSet: brief drain re-scheduling routinely
            # takes 1-3 min during k8s upgrades. 3m suppresses those blips;
            # real outages persist longer. Raised from 2m on 2026-05-18.
            expr: kube_statefulset_status_replicas_ready{statefulset="mysql-standalone"} < 1
            for: 3m
            labels:
              severity: critical
            annotations:
              summary: "mysql-standalone has 0 ready replicas — DB-dependent apps will fail"
          - alert: ClusterPodReadyRatioDropped
            expr: |
              (
                sum(kube_pod_status_ready{condition="true"})
                / sum(kube_pod_status_phase{phase="Running"})
              ) < 0.9
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Cluster pod-ready ratio is {{ $value | printf \"%.1f\" }} (threshold: 0.9) — possible cascade"
          - alert: NodeMemoryPressure
            expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Node {{ $labels.node }} reports MemoryPressure=true — kubelet may evict pods"
          - alert: NodeDiskPressure
            expr: kube_node_status_condition{condition="DiskPressure",status="true"} == 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Node {{ $labels.node }} reports DiskPressure=true — image GC may not keep up"
          - alert: KubeQuotaAlmostFull
            expr: |
              kube_resourcequota{type="used"}
              / on(namespace, resource, resourcequota) kube_resourcequota{type="hard"} > 0.95
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "ResourceQuota {{ $labels.namespace }}/{{ $labels.resourcequota }} {{ $labels.resource }} at {{ $value | printf \"%.1f\" }} — workloads may fail to reschedule"
          # K8sVersionSkew: kubelet on any node disagrees with the apiserver's gitVersion.
          # Catches a half-done kubeadm rollout — e.g. master at 1.34.5 but a worker
          # still on 1.34.2 after the agent aborted mid-flight. Distinct gitVersion
          # count >1 across kubernetes-nodes + kubernetes-apiservers means skew exists.
          # 30m for: gives a normal rolling upgrade (master + 4 workers + 10-min soaks
          # ≈ 60-90 min) room to be in mid-progress without firing during a healthy
          # run — but only because Prometheus only counts a node post-restart, and the
          # agent's soak between workers exceeds 10min anyway.
          - alert: K8sVersionSkew
            expr: count(count by (git_version) (kubernetes_build_info{job=~"kubernetes-nodes|kubernetes-apiservers"})) > 1
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Kubelet/apiserver gitVersion skew detected — possible half-done k8s upgrade. Inspect: kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}'"
          # EtcdPreUpgradeSnapshotMissing: the k8s-version-upgrade agent pushes
          # `k8s_upgrade_in_flight=1` + `k8s_upgrade_snapshot_taken=0` at Stage 0,
          # then sets snapshot_taken=1 in Stage 2 after etcdctl confirms the
          # snapshot file size. Anywhere in_flight=1 with snapshot_taken=0
          # lasting >10m means the agent skipped or failed Stage 2 — a critical
          # safety hole (no recovery point if master upgrade hangs).
          - alert: EtcdPreUpgradeSnapshotMissing
            expr: k8s_upgrade_in_flight == 1 and k8s_upgrade_snapshot_taken == 0
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "K8s upgrade is in flight but no etcd snapshot was recorded — pipeline pre-flight failed silently"
          # K8sUpgradeStalled: the v2 Job-chain pushes `k8s_upgrade_started_timestamp`
          # in preflight and resets `k8s_upgrade_in_flight=0` in postflight. If
          # in_flight=1 persists for >90 min, a Job in the chain failed
          # (backoffLimit=1), got preempted/evicted, or is hung. Manual recovery:
          # `kubectl -n k8s-upgrade get jobs` → identify failed/stuck Job → delete
          # it → fix root cause → re-create the same Job. Next-Job creation in each
          # phase is idempotent (deterministic name = `k8s-upgrade-<phase>-<target>`)
          # so re-running won't duplicate downstream Jobs.
          - alert: K8sUpgradeStalled
            expr: k8s_upgrade_in_flight == 1 and (time() - k8s_upgrade_started_timestamp) > 5400
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "K8s upgrade has been in flight for >90 min — chain is stuck. Check: kubectl -n k8s-upgrade get jobs"
      - name: "Traefik Ingress"
        rules:
          - alert: TraefikDown
            expr: up{job="traefik"} == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Traefik pod {{ $labels.instance }} is down"
          # Detects a Traefik replica whose K8s Ingress informer cache has gone
          # stale — pod reloads at a fraction of the rate of peers, returns 404
          # for ingresses it never re-listed. Pattern observed 2026-05-12 when
          # pod traefik-db7696fbf-k42wp came back after a SIGTERM with only 6
          # routers vs 119 on healthy peers (11 vs 145 config reloads). Symptom:
          # ~33% of requests to viktorbarzin.me hosts returned a Go-style
          # "404 page not found" depending on which replica kube-proxy picked.
          # Remediation: `kubectl -n traefik delete pod <stale-pod>` — the
          # Deployment recreates it with a fresh informer cache. PDB
          # minAvailable=2 keeps the other two replicas serving.
          # 30m rate window lets stale (deleted) pod series age out quickly;
          # `for: 1h` tolerates startup ramp-up but catches sustained drift.
          # The `min(rate) > 0.0005` guard filters out both stale-zero series
          # (recently-deleted pods linger with rate=0) and fresh pods that
          # haven't accumulated samples — bug pattern rate (~0.00076 ≈ 2.75/hr
          # in the 2026-05-12 incident) sits comfortably above the floor.
          - alert: TraefikReplicaConfigStale
            expr: |
              (
                max(rate(traefik_config_reloads_total[30m]))
                /
                min(rate(traefik_config_reloads_total[30m]))
              ) > 5
              and min(rate(traefik_config_reloads_total[30m])) > 0.0005
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "Traefik replica config divergence: max/min reload rate = {{ $value | printf \"%.1f\" }}x"
              description: "One Traefik replica is reloading config much less than its peers — likely a stale K8s informer cache returning 404 for ingresses. Identify the stale pod by comparing `traefik_config_reloads_total` across pods and delete it: `kubectl -n traefik delete pod <pod-name>`."
          - alert: HighServiceErrorRate
            expr: |
              (
                sum(rate(traefik_service_requests_total{code=~"5..", service!~".*nextcloud.*"}[5m])) by (service)
                / sum(rate(traefik_service_requests_total{service!~".*nextcloud.*"}[5m])) by (service)
                * 100
              ) > 10
              and sum(rate(traefik_service_requests_total{service!~".*nextcloud.*"}[5m])) by (service) > 0.1
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "5xx rate on {{ $labels.service }}: {{ $value | printf \"%.1f\" }}% (threshold: 10%)"
          - alert: HighService4xxRate
            # `.*catchall-error-pages.*` is excluded because that IngressRoute
            # is the wildcard `HostRegexp(^(.+\.)?viktorbarzin\.me$)` handler
            # — its entire purpose is to return 404 for unmatched hostnames
            # (typos + scanner traffic), so its 4xx rate is permanently ~100%.
            # Without this exclusion the alert is a perpetual false positive.
            expr: |
              (
                sum(rate(traefik_service_requests_total{code=~"4..", service!~".*nextcloud.*|.*grafana.*|.*linkwarden.*|.*claude-memory.*|.*catchall-error-pages.*"}[5m])) by (service)
                / sum(rate(traefik_service_requests_total{service!~".*nextcloud.*|.*grafana.*|.*linkwarden.*|.*claude-memory.*|.*catchall-error-pages.*"}[5m])) by (service)
                * 100
              ) > 30
              and sum(rate(traefik_service_requests_total{service!~".*nextcloud.*|.*grafana.*|.*linkwarden.*|.*claude-memory.*|.*catchall-error-pages.*"}[5m])) by (service) > 0.1
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "4xx rate on {{ $labels.service }}: {{ $value | printf \"%.1f\" }}% (threshold: 30%)"
          - alert: HighServiceLatency
            expr: |
              (
                sum(rate(traefik_service_request_duration_seconds_sum{service!~".*idrac.*|.*headscale.*",protocol!="websocket"}[5m])) by (service)
                / sum(rate(traefik_service_request_duration_seconds_count{service!~".*idrac.*|.*headscale.*",protocol!="websocket"}[5m])) by (service)
              ) > 10
              and sum(rate(traefik_service_request_duration_seconds_count{service!~".*idrac.*|.*headscale.*",protocol!="websocket"}[5m])) by (service) > 0.05
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Avg latency on {{ $labels.service }}: {{ $value | printf \"%.1f\" }}s (threshold: 10s)"
          - alert: TLSCertExpiringSoon
            expr: (traefik_tls_certs_not_after - time()) / 86400 < 7
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "TLS cert {{ $labels.cn }} expires in {{ $value | printf \"%.0f\" }} days"
          - alert: TLSCertRenewalOverdue
            expr: (traefik_tls_certs_not_after - time()) / 86400 < 30
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "TLS cert {{ $labels.cn }} expires in {{ $value | printf \"%.0f\" }} days — renewal may have failed (LE certs valid 90d, renewed at 60d)"
          - alert: TraefikHighOpenConnections
            expr: sum(traefik_service_open_connections) by (service) > 500
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.service }} has {{ $value | printf \"%.0f\" }} open connections (threshold: 500)"
          - alert: ForwardAuthFallbackActive
            expr: |
              (
                kube_deployment_spec_replicas{namespace="poison-fountain", deployment="poison-fountain"} > 0
                and (kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} or on() vector(0)) < 1
              ) or (
                kube_deployment_status_replicas_available{namespace="authentik", deployment="goauthentik-server"} or on() vector(0)
              ) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "ForwardAuth fallback active — check Poison Fountain and Authentik availability"
          # - alert: OpenWRT High Memory Usage
          #   expr: 100 - ((openwrt_node_memory_MemAvailable_bytes * 100) / openwrt_node_memory_MemTotal_bytes) > 90
          #   for: 10m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: OpenWRT high memory usage. Can cause services getting stuck.
          # MailServerDown, HackmdDown, PrivatebinDown moved to "Application Health" group
          # New Tailscale client moved to "Infrastructure Health" group
      - name: "Slow Ingress Latency"
        # Per-host slow-latency + Anubis-specific 5xx alerts. Sourced from
        # `traefik_service_*` metrics scraped via `kubernetes-pods` (only fresh
        # samples we have — `*_bucket` series are scraped but the `traefik`
        # job's metric_relabel drops them, so `histogram_quantile` produces no
        # samples). Once buckets are restored, replace the avg expressions with
        # `histogram_quantile(0.95, ...)`. The `service` label format is
        # `<ns>-<release>-<port>@kubernetes` and maps roughly 1:1 to a public
        # host (e.g. `travel-blog-anubis-travel-8080@kubernetes`).
        rules:
          - alert: IngressTTFBHigh
            expr: |
              (
                sum(rate(traefik_service_request_duration_seconds_sum{service!~".*idrac.*|.*headscale.*|.*nextcloud.*|.*immich.*",protocol!="websocket"}[5m])) by (service)
                / sum(rate(traefik_service_request_duration_seconds_count{service!~".*idrac.*|.*headscale.*|.*nextcloud.*|.*immich.*",protocol!="websocket"}[5m])) by (service)
              ) > 1
              and sum(rate(traefik_service_request_duration_seconds_count{service!~".*idrac.*|.*headscale.*|.*nextcloud.*|.*immich.*",protocol!="websocket"}[5m])) by (service) > 0.05
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Slow ingress on {{ $labels.service }}: avg latency {{ $value | printf \"%.2f\" }}s (threshold: 1s for 10m)"
          - alert: IngressTTFBCritical
            expr: |
              (
                sum(rate(traefik_service_request_duration_seconds_sum{service!~".*idrac.*|.*headscale.*|.*nextcloud.*|.*immich.*",protocol!="websocket"}[5m])) by (service)
                / sum(rate(traefik_service_request_duration_seconds_count{service!~".*idrac.*|.*headscale.*|.*nextcloud.*|.*immich.*",protocol!="websocket"}[5m])) by (service)
              ) > 3
              and sum(rate(traefik_service_request_duration_seconds_count{service!~".*idrac.*|.*headscale.*|.*nextcloud.*|.*immich.*",protocol!="websocket"}[5m])) by (service) > 0.05
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Critically slow ingress on {{ $labels.service }}: avg latency {{ $value | printf \"%.2f\" }}s (threshold: 3s for 5m)"
          - alert: IngressErrorRate5xxHigh
            # Rolling upgrades / pod migrations cause brief 5xx spikes that
            # clear within 1-2 min. Only persistent 5xx indicates a real
            # problem. Raised from 5m to 10m on 2026-05-18.
            expr: |
              (
                sum(rate(traefik_service_requests_total{code=~"5..", service!~".*nextcloud.*"}[5m])) by (service)
                / sum(rate(traefik_service_requests_total{service!~".*nextcloud.*"}[5m])) by (service)
                * 100
              ) > 5
              and sum(rate(traefik_service_requests_total{service!~".*nextcloud.*"}[5m])) by (service) > 0.1
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "5xx rate on {{ $labels.service }}: {{ $value | printf \"%.1f\" }}% (threshold: 5% for 10m)"
          - alert: AnubisChallengeStoreErrors
            # Anubis exposes only Go-runtime metrics on :9090 (no anubis_* /
            # challenge_* counters), so we proxy via Traefik 5xx on services
            # whose name contains `anubis`. Catches the "store: key not found"
            # 500 we saw — every Anubis 5xx is suspicious because the only
            # legitimate path through it is /.within.website/x/cmd/anubis or a
            # redirect to the upstream, both 200/3xx in healthy operation.
            expr: |
              sum(rate(traefik_service_requests_total{service=~".*anubis.*",code=~"5.."}[5m])) by (service) > 0
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Anubis service {{ $labels.service }} returning 5xx ({{ $value | printf \"%.2f\" }} req/s) — likely challenge-store error"
      - name: "Networking & Access"
        rules:
          - alert: CloudflaredDown
            expr: (kube_deployment_status_replicas_available{namespace="cloudflared", deployment="cloudflared"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Cloudflared tunnel down — external access via Cloudflare broken"
          - alert: CloudflaredDegraded
            expr: |
              (
                kube_deployment_spec_replicas{namespace="cloudflared", deployment="cloudflared"}
                - on(namespace, deployment) kube_deployment_status_replicas_available{namespace="cloudflared", deployment="cloudflared"}
              ) > 0
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Cloudflared: {{ $value | printf \"%.0f\" }} replica(s) unavailable"
          - alert: MetalLBSpeakerDown
            # kubelet restart during k8s upgrade briefly takes the speaker
            # pod down; typical recovery is 30-45s. The full drain+kubeadm+
            # apt+kubelet-restart+uncordon cycle in the chain's worker phase
            # can take a single node out of MetalLB rotation for 5-7 min in
            # the worst case (depending on PDB stickiness). 10m suppresses
            # those upgrade-induced blips while still catching genuine
            # speaker-down conditions.
            # Reverted from 2m → 10m on 2026-05-23 after node4 upgrade
            # tripped it mid-soak and aborted the chain. Previous value was
            # 5m (set 2026-05-18) which was already correct; a brief patch
            # had tightened it.
            expr: |
              (
                kube_daemonset_status_desired_number_scheduled{namespace="metallb-system", daemonset="metallb-speaker"}
                - on(namespace, daemonset) kube_daemonset_status_number_ready{namespace="metallb-system", daemonset="metallb-speaker"}
              ) > 0
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "MetalLB speaker: {{ $value | printf \"%.0f\" }} pod(s) missing"
          - alert: MetalLBControllerDown
            expr: (kube_deployment_status_replicas_available{namespace="metallb-system", deployment="metallb-controller"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "MetalLB controller down — no LoadBalancer IP management"
          - alert: TechnitiumDNSDown
            expr: |
              (kube_deployment_status_replicas_available{namespace="technitium", deployment="technitium"} or on() vector(0))
              + (kube_deployment_status_replicas_available{namespace="technitium", deployment="technitium-secondary"} or on() vector(0))
              < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Both Technitium DNS instances down — internal DNS broken"
      - name: "Storage Drivers"
        rules:
          - alert: NFSCSIControllerDown
            expr: (kube_deployment_status_replicas_available{namespace="nfs-csi", deployment="csi-nfs-controller"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "NFS CSI controller down — new NFS volume provisioning broken"
          # ISCSICSIControllerDown alert removed — democratic-csi replaced by proxmox-csi (2026-04-05)
          - alert: NFSCSINodeDown
            expr: kube_daemonset_status_number_unavailable{namespace="nfs-csi", daemonset="csi-nfs-node"} > 0
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "{{ $value }} NFS CSI node pod(s) unavailable — NFS mounts will fail on affected nodes"
          - alert: NFSMountFailures
            expr: |
              count(kube_pod_container_status_waiting_reason{reason="ContainerCreating"} == 1) > 5
              and on()
              count(kube_pod_container_status_waiting_reason{reason="ContainerCreating"} == 1) > 2 * count(kube_pod_container_status_waiting_reason{reason="ContainerCreating"} offset 10m == 1 or on() vector(0))
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: ">5 pods stuck in ContainerCreating with sudden increase — possible NFS or storage outage"
          - alert: NFSHighRPCRetransmissions
            expr: |
              sum by (instance) (rate(node_nfs_rpc_retransmissions_total[5m])) > 5
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Node {{ $labels.instance }}: NFS RPC retransmission rate {{ $value | printf \"%.1f\" }}/s — NFS server (192.168.1.127) may be degraded or unreachable"
          # Proxmox CSI per-node LUN saturation. The plugin enforces
          # csi.proxmox.sinextra.dev/max-volume-attachments=28 (set on every k8s-node*
          # by stacks/proxmox-csi). QEMU's virtio-scsi-pci hard cap is 30 LUNs.
          # When K8s-side VolumeAttachments approach the cap, new PVCs fail to
          # attach with "no free lun found" — vaultwarden + 18 pods stuck 2026-05-26.
          - alert: ProxmoxCSILunUsageHigh
            expr: count by (node) (kube_volumeattachment_info{node=~"k8s-node.*"}) >= 24
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.node }}: {{ $value }}/28 CSI volumes attached (>= 85% of cap)"
              description: "Approaching the proxmox-csi-plugin per-node cap of 28 attachments. Workloads scheduled to this node with new PVCs may fail to attach. Consider rebalancing or migrating PVCs to other nodes."
          - alert: ProxmoxCSILunUsageCritical
            expr: count by (node) (kube_volumeattachment_info{node=~"k8s-node.*"}) >= 27
            for: 3m
            labels:
              severity: critical
            annotations:
              summary: "{{ $labels.node }}: {{ $value }}/28 CSI volumes attached — 1 slot left"
              description: "Only 1 LUN slot remains before the proxmox-csi cap. Next PVC attach to this node will fail with 'no free lun found'."
          - alert: ProxmoxCSILunCapReached
            expr: count by (node) (kube_volumeattachment_info{node=~"k8s-node.*"}) >= 28
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "{{ $labels.node }}: at proxmox-csi LUN cap (28/28) — attaches WILL fail"
              description: "Pods needing new PVC attachments on {{ $labels.node }} will fail with 'no free lun found'. Detach unused volumes from this node's Proxmox VM config, or migrate PVCs to a less-loaded node."
      - name: "Application Health"
        rules:
          - alert: MailServerDown
            expr: (kube_deployment_status_replicas_available{namespace="mailserver", deployment="mailserver"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Mail server has no available replicas - mail may not be received"
          # Note: no BankSyncFailing alert — GoCardless enforces per-account
          # PSD2 quotas (4 successful pulls per account per 24h). Manual UI
          # syncs consume the same quota, so the nightly cron routinely hits
          # rate-limits without any real outage. Alert only on staleness.
          - alert: BankSyncStale
            expr: (time() - bank_sync_last_success_timestamp) > 172800
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "Bank sync (instance {{ $labels.instance }}): NO account has synced in over 48h. Likely a real outage — check CronJob, http-api logs, and GoCardless re-auth."
          - alert: BankSyncAccountStale
            expr: (time() - bank_sync_account_last_success_timestamp) > 259200
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "Bank sync (instance {{ $labels.instance }}): account {{ $labels.account }} has not synced in over 72h. GoCardless requisition may have expired — re-link in Settings → Bank Sync."
          - alert: EmailRoundtripFailing
            expr: email_roundtrip_success{job="email-roundtrip-monitor"} == 0
            for: 60m
            labels:
              severity: warning
            annotations:
              summary: "Email round-trip probe failing. Check MX DNS, Postfix, Mailgun API, and IMAP."
          - alert: EmailRoundtripStale
            expr: (time() - email_roundtrip_last_success_timestamp{job="email-roundtrip-monitor"}) > 3600
            for: 20m
            labels:
              severity: warning
            annotations:
              summary: "Email round-trip probe has not succeeded in >60 min"
          - alert: EmailRoundtripNeverRun
            expr: absent(email_roundtrip_success{job="email-roundtrip-monitor"})
            for: 60m
            labels:
              severity: warning
            annotations:
              summary: "Email round-trip monitor never reported - check CronJob in mailserver namespace"
          - alert: ViktorBarzinApexDrift
            expr: viktorbarzin_apex_correct{job="viktorbarzin-apex-probe"} == 0
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "viktorbarzin.me apex A drifted from expected 10.0.20.200"
              description: "Technitium serves the split-horizon apex for ~80 *.viktorbarzin.me CNAMEs. If this is wrong, every internal service (auth, vault, immich, ha-sofia, ...) breaks. Check Technitium primary zone records via API or web console."
          - alert: ViktorBarzinApexProbeStale
            expr: (time() - viktorbarzin_apex_last_correct_timestamp{job="viktorbarzin-apex-probe"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "viktorbarzin.me apex probe has not seen a correct result in >15 min"
              description: "Probe may be failing intermittently or apex may be drifting. Check CronJob `viktorbarzin-apex-probe` in `technitium` namespace."
          - alert: ViktorBarzinApexProbeNeverRun
            expr: absent(viktorbarzin_apex_correct{job="viktorbarzin-apex-probe"})
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "viktorbarzin.me apex probe never reported"
              description: "Check `kubectl -n technitium get cronjob viktorbarzin-apex-probe` and the most recent job pod logs."
          - alert: AIOStreamsStreamCountLow
            expr: aiostreams_stream_count{job="aiostreams-stream-probe"} < 50
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "AIOStreams returning <50 streams for the canary title for 30m"
              description: "Probe for Breaking Bad S01E01 returned {{ $value }} streams. Could indicate an upstream addon outage, RD filter expansion, or a regression in the user's preset filters. Check `kubectl -n aiostreams get cronjob aiostreams-stream-probe` and the most recent job pod logs."
          - alert: AIOStreamsProbeFailing
            expr: aiostreams_probe_success{job="aiostreams-stream-probe"} == 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "AIOStreams stream-probe failing for 30m"
              description: "The /api/v1/user fetch or stream search is returning errors, or stream count is below threshold. Check probe logs."
          - alert: AIOStreamsProbeStale
            expr: (time() - aiostreams_probe_last_run_timestamp{job="aiostreams-stream-probe"}) > 1800
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "AIOStreams stream-probe hasn't run in >30 min"
              description: "CronJob may be unschedulable or failing before pushgateway POST."
          - alert: ClaudeOAuthTokenExpiringSoon
            expr: (claude_oauth_token_expiry_timestamp{job="claude-oauth-expiry-monitor"} - time()) < (30 * 86400)
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "Claude OAuth token {{ $labels.path }} expires in <30 days"
              description: "Run `claude setup-token` to mint a new 1-year token and update the corresponding Vault path + mint_epoch in stacks/claude-agent-service/main.tf."
          - alert: ClaudeOAuthTokenCritical
            expr: (claude_oauth_token_expiry_timestamp{job="claude-oauth-expiry-monitor"} - time()) < (7 * 86400)
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "Claude OAuth token {{ $labels.path }} expires in <7 days — rotate NOW"
              description: "The long-lived CLAUDE_CODE_OAUTH_TOKEN is within 1 week of expiry. Automated upgrades will break when it expires. Harvest via `claude setup-token` and update Vault + TF."
          - alert: ClaudeOAuthTokenMonitorStale
            expr: (time() - claude_oauth_expiry_monitor_last_push_timestamp) > (48 * 3600)
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Claude OAuth expiry monitor hasn't pushed in >48h"
              description: "CronJob claude-oauth-expiry-monitor in claude-agent ns isn't running. Check `kubectl -n claude-agent get cronjob claude-oauth-expiry-monitor`."
          - alert: ClaudeOAuthTokenMonitorNeverRun
            expr: absent(claude_oauth_expiry_monitor_last_push_timestamp)
            for: 2h
            labels:
              severity: warning
            annotations:
              summary: "Claude OAuth expiry monitor has never pushed — CronJob not running"
              description: "Expected `claude_oauth_expiry_monitor_last_push_timestamp` to appear once the CronJob runs. Check the CronJob in claude-agent namespace."
          - alert: HackmdDown
            expr: (kube_deployment_status_replicas_available{namespace="hackmd"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Hackmd has no available replicas"
          - alert: PrivatebinDown
            expr: (kube_deployment_status_replicas_available{namespace="privatebin"} or on() vector(0)) < 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Privatebin has no available replicas"
          - alert: DawarichIngestionStale
            expr: (time() - dawarich_last_point_ingested_timestamp{user="viktor"}) > 172800
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Dawarich: no points from viktor in >2 days"
              description: "The iOS Dawarich app likely stopped sending location points. Open the app, verify it's running, and check background location permissions. Server-side is healthy when this alert fires — the issue is client-side."
          - alert: DawarichIngestionMonitorStale
            expr: (time() - dawarich_ingestion_monitor_last_push_timestamp{user="viktor"}) > 129600
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Dawarich ingestion freshness monitor hasn't pushed in >36h"
              description: "CronJob ingestion-freshness-monitor in dawarich ns isn't running or failing. Check `kubectl -n dawarich get cronjob ingestion-freshness-monitor` and recent Job logs."
          - alert: DawarichIngestionMonitorNeverRun
            expr: absent(dawarich_ingestion_monitor_last_push_timestamp{user="viktor"})
            for: 2h
            labels:
              severity: warning
            annotations:
              summary: "Dawarich ingestion freshness monitor has never pushed"
              description: "Expected `dawarich_ingestion_monitor_last_push_timestamp` to appear once the daily CronJob runs. Check the CronJob in dawarich namespace."
      - name: "Network Traffic (GoFlow2)"
        rules:
          - alert: GoFlow2Down
            expr: up{job="goflow2"} == 0
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "GoFlow2 NetFlow collector is down — no network flow visibility"
          - alert: NoNetFlowData
            expr: absent(goflow2_flow_traffic_bytes_total) and on() up{job="goflow2"} == 1
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "GoFlow2 is up but receiving no NetFlow data — check softflowd on pfSense"
          - alert: NetFlowTrafficSpike
            expr: |
              rate(goflow2_flow_traffic_bytes_total[5m]) > 2 * avg_over_time(rate(goflow2_flow_traffic_bytes_total[5m])[1h:5m])
              and rate(goflow2_flow_traffic_bytes_total[5m]) > 1048576
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "NetFlow traffic spike: {{ $value | humanize1024 }}B/s — more than 2x the 1h average"
          - alert: NetFlowHighErrorRate
            expr: |
              rate(goflow2_flow_decoder_error_total[5m]) /
              (rate(goflow2_flow_process_nf_total[5m]) + 1) > 0.1
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "GoFlow2 decoder error rate: {{ $value | printf \"%.1f\" }}% — possible malformed flows or attack"
          - alert: NetFlowProcessingDelay
            expr: goflow2_flow_process_nf_delay_seconds{quantile="0.5"} > 600
            for: 15m
            labels:
              severity: info
            annotations:
              summary: "NetFlow processing delay p50: {{ $value | printf \"%.0f\" }}s — softflowd may be overloaded"
      - name: "DNS Anomaly Detection"
        rules:
          # Spike detection: compare current value against its own 1h history via
          # avg_over_time. Previous version compared against dns_anomaly_avg_queries
          # which was computed from a per-pod /tmp file and always equalled the
          # current value (fresh /tmp each run), so the alert could never fire.
          - alert: DNSQuerySpike
            expr: dns_anomaly_total_queries > 2 * avg_over_time(dns_anomaly_total_queries[1h] offset 15m) and dns_anomaly_total_queries > 1000
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "DNS query spike: {{ $value | printf \"%.0f\" }} queries (>2x 1h avg)"
          - alert: DNSQueryRateDropped
            expr: dns_anomaly_total_queries < 0.5 * avg_over_time(dns_anomaly_total_queries[1h] offset 15m) and avg_over_time(dns_anomaly_total_queries[1h] offset 15m) > 1000
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "DNS query volume dropped: {{ $value | printf \"%.0f\" }} queries (<50% of 1h avg) — upstream clients may be failing to reach Technitium"
          - alert: DNSHighErrorRate
            expr: dns_anomaly_server_failure > 100
            for: 0m
            labels:
              severity: warning
            annotations:
              summary: "High DNS SERVFAIL rate: {{ $value | printf \"%.0f\" }} failures detected"
          - alert: TechnitiumZoneSyncFailed
            expr: technitium_zone_sync_status != 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Technitium zone-sync CronJob has reported failure for 30m — replicas may be missing zones"
          - alert: TechnitiumZoneSyncStale
            expr: (time() - technitium_zone_sync_last_run) > 3600
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Technitium zone-sync has not run successfully in >1h (last: {{ $value | humanizeDuration }} ago)"
          - alert: TechnitiumZoneCountMismatch
            expr: (max(technitium_zone_count{instance!="primary"}) - min(technitium_zone_count{instance!="primary"})) > 0
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Technitium zone counts differ across instances (max-min delta: {{ $value | printf \"%.0f\" }}) — replica has drifted from primary"
          - alert: CoreDNSForwardFailureRate
            expr: sum(rate(coredns_forward_responses_total{rcode=~"SERVFAIL|REFUSED"}[5m])) > 0.1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "CoreDNS forward SERVFAIL/REFUSED rate: {{ $value | printf \"%.2f\" }}/s — upstream DNS (pfSense/public) may be unhealthy"
      - name: qbittorrent
        rules:
          - alert: MAMCookieExpired
            expr: mam_farming_cookie_expired > 0
            for: 0m
            labels:
              severity: critical
            annotations:
              summary: "MAM session cookie has expired — refresh `mam_id` in Vault servarr/mam_id"
          - alert: MAMRatioBelowOne
            expr: mam_ratio < 1.0
            for: 24h
            labels:
              severity: warning
            annotations:
              summary: "MAM ratio is {{ $value | printf \"%.2f\" }} for 24h (target: >= 1.0)"
          - alert: MAMFarmingStuck
            expr: |
              increase(mam_farming_grabbed[4h]) == 0
              and mam_farming_total_seeding < 150
              and mam_ratio >= 1.2
            for: 4h
            labels:
              severity: warning
            annotations:
              summary: "Grabber has added 0 torrents in 4h despite healthy ratio ({{ $value | printf \"%.2f\" }})"
          - alert: MAMJanitorStuckBacklog
            expr: mam_janitor_skipped_active > 400
            for: 6h
            labels:
              severity: warning
            annotations:
              summary: "Janitor is skipping {{ $value | printf \"%.0f\" }} in-progress torrents — queue not draining"
          - alert: QBittorrentDisconnected
            expr: qbt_connected == 0
            for: 10m
            labels:
              severity: critical
            annotations:
              summary: "qBittorrent is disconnected from the network"

      - name: Headscale VPN
        rules:
          - alert: HeadscaleDown
            expr: up{job="kubernetes-service-endpoints", namespace="headscale"} == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Headscale VPN control plane is down"
          - alert: HeadscaleNoOnlineNodes
            expr: headscale_nodestore_nodes_total == 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "No nodes registered in Headscale"
          - alert: HeadscaleHighHTTPLatency
            expr: histogram_quantile(0.95, rate(headscale_http_duration_seconds_bucket[5m])) > 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Headscale p95 HTTP latency is {{ $value | printf \"%.1f\" }}s"
          - alert: HeadscaleHighErrorRate
            expr: sum(rate(headscale_http_requests_total{code=~"5.."}[5m])) / sum(rate(headscale_http_requests_total[5m])) > 0.05
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Headscale 5xx error rate is {{ $value | printf \"%.1f\" }}%"
      - name: "External Access"
        rules:
          - alert: ExternalAccessDivergence
            expr: external_internal_divergence_count > 0
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "{{ $value | printf \"%.0f\" }} service(s) externally unreachable but internally healthy — check Cloudflare tunnel, DNS, or Traefik routing"
      - name: "Authentik Outpost"
        # Guards against the 2026-04-18 incident where /dev/shm filled with
        # gorilla/sessions FileStore files (~44k files at ~1.5KB each) and the
        # outpost returned HTTP 400 on every forward-auth request.
        # See docs/post-mortems/2026-04-18-authentik-outpost-shm-full.md.
        rules:
          - alert: AuthentikOutpostMemoryHigh
            # Working set includes /dev/shm tmpfs contents (session files).
            # sizeLimit on the outpost emptyDir is 2Gi; warn at 75% to leave
            # plenty of headroom for mitigation before ENOSPC.
            expr: container_memory_working_set_bytes{namespace="authentik", pod=~"ak-outpost-.*", container="proxy"} > 1.5 * 1024 * 1024 * 1024
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Authentik outpost working set {{ $value | humanize1024 }} — /dev/shm may be filling with session files (threshold 1.5 GiB of 2 GiB sizeLimit)"
          - alert: AuthentikOutpostMemoryCritical
            expr: container_memory_working_set_bytes{namespace="authentik", pod=~"ak-outpost-.*", container="proxy"} > 1.8 * 1024 * 1024 * 1024
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Authentik outpost near /dev/shm fill ({{ $value | humanize1024 }}) — imminent forward-auth failure. Restart pod: kubectl -n authentik delete pod -l goauthentik.io/outpost-name=authentik-embedded-outpost"
          - alert: AuthentikOutpostRestarts
            # Pod restarts on a stateless outpost usually mean OOM or crash.
            # Normal is 0; we expect one manual rollout per incident/upgrade.
            expr: increase(kube_pod_container_status_restarts_total{namespace="authentik", pod=~"ak-outpost-.*"}[30m]) > 2
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Authentik outpost restarted {{ $value | printf \"%.0f\" }} times in 30m — check for OOM or crash loop"
          - alert: AuthentikOutpostDevShmFull
            # Direct filesystem measure of the /dev/shm emptyDir sizeLimit.
            # The 2026-04-18 incident went undetected for 40h because working-set
            # memory lags tmpfs fill (files count against memory but not always
            # against working set). This rule catches the underlying cause.
            # See docs/post-mortems/2026-04-18-authentik-outpost-shm-full.md.
            expr: container_fs_usage_bytes{namespace="authentik", pod=~"ak-outpost-.*"} / container_fs_limit_bytes{namespace="authentik", pod=~"ak-outpost-.*"} > 0.8
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Authentik outpost filesystem at {{ $value | humanizePercentage }} on {{ $labels.pod }} — session files filling tmpfs, forward-auth imminent failure"
          - alert: AuthentikOutpostForwardAuth400Spike
            # Sudden 400 spike from the outpost means forward-auth is broken
            # for all protected services. The /dev/shm ENOSPC class of failures
            # manifests as the outpost returning 400 on /outpost.goauthentik.io/auth/traefik.
            # Service label format is `authentik-ak-outpost-authentik-embedded-outpost-9000@kubernetes`
            # — the original regex `authentik-authentik-outpost.*` never matched anything (fixed 2026-05-10).
            expr: sum by (service) (increase(traefik_service_requests_total{code="400", service=~"authentik-ak-outpost-.*"}[5m])) > 10
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Authentik outpost returning {{ $value | printf \"%.0f\" }} 400s in 5m on {{ $labels.service }} — forward-auth broken for all 43 protected services"
          - alert: AuthentikForwardAuthFallbackActive
            # Catches the auth-proxy "Emergency Access" Basic-Auth fallback firing
            # at the edge — symptom of the outpost service having zero ready
            # endpoints (selector mismatch, label drift, controller bug). The
            # auth-proxy nginx returns 401 with `WWW-Authenticate: Basic` and
            # `X-Auth-Fallback: true` in that case; Traefik proxies the 401
            # back through the websecure entrypoint.
            #
            # Why this rule and not `kube_endpoint_address_available == 0`:
            # kube-state-metrics endpoint metrics are silently dropped by the
            # Prometheus pipeline in this cluster (kube_endpoint_* series
            # exist but never have current values). Detecting the failure
            # signal at the edge is more reliable than instrumenting the
            # broken middle.
            #
            # Baseline 401/s on websecure is ~0.02 (linkwarden API). Threshold
            # of 5 leaves ~250x headroom; fallback firing on a busy site
            # immediately pushes 401/s well above that.
            #
            # See `.claude/reference/authentik-state.md` for the upgrade
            # validation checklist that exercises the same path.
            expr: sum(rate(traefik_entrypoint_requests_total{code="401",entrypoint="websecure"}[5m])) > 5
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "websecure 401 rate {{ $value | printf \"%.1f\" }}/s for 5m — Authentik forward-auth Emergency Access fallback likely firing. Check `kubectl -n authentik get endpoints ak-outpost-authentik-embedded-outpost`."
          - alert: AuthentikServerReplicasMismatch
            # With 3 replicas + PDB minAvailable=2, a sustained drop to <3
            # means a node is unschedulable, image pull failing, or quota hit.
            expr: (kube_deployment_spec_replicas{namespace="authentik", deployment="goauthentik-server"} - kube_deployment_status_replicas_available{namespace="authentik", deployment="goauthentik-server"}) > 0
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Authentik server has {{ $value }} unavailable replica(s) for 15m — check pod events"
      # Mailserver Dovecot alerts were removed with the exporter in
      # code-1ik (viktorbarzin/dovecot_exporter incompatible with
      # Dovecot 2.3 stats architecture). Re-add the rule group if a
      # working exporter is introduced.
      - name: Infrastructure Drift
        # Metrics pushed by .woodpecker/drift-detection.yml after each cron run.
        # See Wave 7 of the state-drift consolidation plan.
        rules:
          - alert: DriftDetectionStale
            # Drift detection pipeline hasn't reported in 26h. Either the cron
            # didn't fire, or the job is failing before the push step.
            expr: time() - max(drift_detection_last_run_timestamp) > 26 * 3600
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Drift detection hasn't reported in {{ $value | humanizeDuration }} — check Woodpecker pipeline 'drift-detection'"
          - alert: DriftUnaddressed
            # Any stack drifted for >72h without being reconciled. Either apply
            # to bring config in line, or update HCL to match desired state.
            expr: max(drift_stack_age_hours) > 72
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "A stack has been drifted for {{ $value | printf \"%.0f\" }}h — run scripts/tg plan across stacks to identify and reconcile"
          - alert: DriftStacksMany
            # More than 10 stacks drifting simultaneously usually means a
            # systemic issue (cluster upgrade, new admission controller,
            # provider version bump) rather than individual misconfigurations.
            expr: drift_stack_count > 10
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "{{ $value | printf \"%.0f\" }} stacks drifting — likely a systemic cause (new admission webhook, provider upgrade). Check the most recent drift-detection run in Woodpecker."
      # Webterminal availability. Metrics pushed by the webterminal-probe
      # CronJob in stacks/terminal/main.tf every 5 minutes. The probe targets
      # terminal.viktorbarzin.me via Cloudflare so any failure in the chain
      # (CDN → tunnel → Traefik → ttyd) lights up an alert.
      #
      # The 2026-05-17 incident that motivated these alerts: a Traefik replica
      # came up missing the kubernetes_ingress-derived router for
      # terminal.viktorbarzin.me, so ~70% of /token preflight requests routed
      # to that replica returned 404 with router="-". The WS upgrade failed
      # intermittently. Fix: `kubectl delete pod -n traefik <replica>`.
      - name: Webterminal
        rules:
          - alert: WebterminalTokenDegraded
            # /token via Cloudflare must redirect to Authentik (302). Any other
            # status (especially 404) means a Traefik replica is missing the
            # terminal Ingress route or ttyd is down.
            expr: webterminal_probe_token_status{job="webterminal-probe"} != 302 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: warning
              subsystem: webterminal
            annotations:
              summary: "Webterminal /token returning HTTP {{ $value }} via Cloudflare (expected 302). Likely a Traefik replica with a partial routing table — `kubectl get pods -n traefik` and delete the suspect replica."
          - alert: WebterminalWebsocketDegraded
            # WebSocket upgrade to /ws must also redirect (302). 404 here is
            # the user-visible "Failed to connect. Retrying..." in the lobby
            # iframe.
            expr: webterminal_probe_ws_status{job="webterminal-probe"} != 302 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: critical
              subsystem: webterminal
            annotations:
              summary: "Webterminal WebSocket /ws returning HTTP {{ $value }} via Cloudflare — users see 'Failed to connect' in the iframe. Check Traefik route parity across replicas."
          - alert: WebterminalTtydUnreachable
            # In-cluster probe to ttyd Service. Bypasses Cloudflare/Traefik/
            # Authentik, so non-200 means ttyd itself is down on the DevVM.
            expr: webterminal_probe_ttyd_status{job="webterminal-probe"} != 200 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 10m
            labels:
              severity: critical
              subsystem: webterminal
            annotations:
              summary: "ttyd in-cluster probe got HTTP {{ $value }} (expected 200) — ttyd on the DevVM (10.0.10.10:7681) is down. `systemctl status ttyd` on devvm."
          - alert: WebterminalProbeStale
            # No probe push for >20m means the CronJob isn't running. Either
            # the kubelet that owns the namespace can't schedule it or the
            # job is failing before the push step.
            expr: (time() - max(webterminal_probe_last_success_timestamp{job="webterminal-probe"})) > 1200
            for: 15m
            labels:
              severity: warning
              subsystem: webterminal
            annotations:
              summary: "Webterminal probe hasn't reported a successful run in {{ $value | humanizeDuration }} — `kubectl get cronjob -n terminal webterminal-probe` and inspect recent Jobs."
      # Traefik router parity — detects the root cause of the webterminal
      # outage. When a Traefik replica's Kubernetes Ingress provider fails to
      # sync, its router table will diverge from siblings. Catches the issue
      # cluster-wide (not just terminal.viktorbarzin.me) since the same race
      # can happen for any kubernetes_ingress-managed hostname.
      - name: Traefik Router Parity
        rules:
          - alert: TraefikRouterCountSkew
            # Each Traefik replica should report the same number of routers.
            # If max-min across instances is >0 for 10m, one replica is stuck
            # and should be restarted.
            expr: |
              (
                max(count by (instance) (traefik_router_open_connections))
                -
                min(count by (instance) (traefik_router_open_connections))
              ) > 0
            for: 10m
            labels:
              severity: warning
              subsystem: traefik
            annotations:
              summary: "Traefik replicas have diverging router counts (skew={{ $value | printf \"%.0f\" }}). Restart the laggard pod: `kubectl get pods -n traefik` and delete the one with fewer routers."

extraScrapeConfigs: |
  # The `mailserver-dovecot` scrape job was retired in code-1ik together
  # with the Dovecot exporter. docker-mailserver 15.0.0's Dovecot 2.3
  # doesn't emit the old_stats protocol the exporter expected, so the
  # scrape only ever returned `dovecot_up{scope="user"} 0`. Re-add here
  # if a working exporter is introduced.
  - job_name: 'proxmox-host'
    static_configs:
      - targets:
        - "192.168.1.127:9100"
        labels:
          node: 'pve-node-r730'
    metrics_path: '/metrics'
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'pve-node-r730' # Giving it a friendly name
  - job_name: 'istiod'
    kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
        - istio-system
    relabel_configs:
    - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
      action: keep
      regex: istiod;http-monitoring
  - job_name: 'envoy-stats'
    metrics_path: /stats/prometheus
    kubernetes_sd_configs:
    - role: pod
    relabel_configs:
    - source_labels: [__meta_kubernetes_pod_container_port_name]
      action: keep
      regex: '.*-envoy-prom'

  - job_name: 'cnpg'
    # Scrapes the CNPG built-in postgres exporter (port 9187, named "metrics")
    # on every cluster instance pod. Adds cnpg_cluster + cnpg_role labels so
    # alerts (PGConnectionsHigh/Critical) can group by cluster.
    kubernetes_sd_configs:
    - role: pod
      namespaces:
        names:
        - dbaas
    relabel_configs:
    - source_labels: [__meta_kubernetes_pod_label_cnpg_io_podRole, __meta_kubernetes_pod_container_port_name]
      action: keep
      regex: 'instance;metrics'
    - source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster]
      target_label: cnpg_cluster
    - source_labels: [__meta_kubernetes_pod_label_cnpg_io_instanceRole]
      target_label: cnpg_role
    - source_labels: [__meta_kubernetes_pod_name]
      target_label: pod

  - job_name: 'crowdsec'
    static_configs:
        - targets:
          - "crowdsec-service.crowdsec.svc.cluster.local:6060"
    metrics_path: '/metrics'
  - job_name: 'snmp-idrac'
    scrape_interval: 1m
    scrape_timeout: 45s
    static_configs:
        - targets:
          - "idrac.viktorbarzin.lan.:161"
    metrics_path: '/snmp'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'snmp-exporter.monitoring.svc.cluster.local:9116'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'r730_idrac_$${1}'
  - job_name: 'redfish-idrac'
    scrape_interval: 3m
    scrape_timeout: 45s
    metrics_path: /metrics
    static_configs:
      - targets:
        - 192.168.1.4
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: idrac-redfish-exporter.monitoring.svc.cluster.local:9090  
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'r730_idrac_$${1}'
  - job_name: 'openwrt'
    static_configs:
        - targets:
          #- "home.viktorbarzin.lan:9100"
          #- "10.0.20.100:9100"
          - "192.168.2.1:9100"
    metrics_path: '/metrics'
    #relabel_configs:
    #  - source_labels: [__address__]
    #    target_label: __param_target
    #  - source_labels: [__param_target]
    #    target_label: instance
    #  - target_label: __address__
    #    #replacement: 'home.viktorbarzin.lan:9100'
    #    #replacement: '10.0.20.100:9100'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'openwrt_$${1}'
  - job_name: 'snmp-ups'
    # Keep UPS fast: 30s overrides the 2m global so PowerOutage / LowUPSBattery
    # detect within ~30s instead of 2m.
    scrape_interval: 30s
    params:
      module: [huawei]
    static_configs:
        - targets:
          - "ups.viktorbarzin.lan.:161"
    metrics_path: '/snmp'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'snmp-exporter.monitoring.svc.cluster.local:9116'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'ups_$${1}'
  - job_name: 'registry'
    static_configs:
        - targets:
          #- "192.168.1.10:5001" # rpi
          #- "10.0.10.10:5001" # devvm
          - "10.0.20.10:5001" # registry-vm
    metrics_path: '/metrics'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'registry_$${1}' 
  - job_name: 'automatic-transfer-switch'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bfe98afa941d5a1e2def8s'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'automatic_transfer_switch_$${1}'
  - job_name: 'fuse-garage'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bf62301ef04e38d881ugcu'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'fuse_garage_$${1}'
  - job_name: 'fuse-main'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bf1a684e80ae942e4dji6b'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'fuse_main_$${1}'
  - job_name: 'thermostat-hol'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bf7efce9519bd508df431s'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'thermostat_hol_$${1}'
  - job_name: 'thermostat-master-bedroom'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bf70e80159641f61a5lzho'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'thermostat_master_bedroom_$${1}'
  - job_name: 'thermostat-office'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bf9597a0064f0349d4b09x'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'thermostat_office_$${1}'
  - job_name: 'thermostat-kids-room'
    static_configs:
        - targets:
          - "tuya-bridge.tuya-bridge.svc.cluster.local:80"
    metrics_path: '/metrics/bfe64da91577117e0annt5'
    params:
      api-key: ['${tuya_api_key}']
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'thermostat_kids_room_$${1}'
  - job_name: 'haos'
    static_configs:
        - targets:
          - "ha-sofia.viktorbarzin.lan.:8123"
    metrics_path: '/api/prometheus'
    bearer_token: "${haos_api_token}"
  - job_name: 'nvidia'
    static_configs:
        - targets:
          - "nvidia-exporter.nvidia.svc.cluster.local"
    metrics_path: '/metrics'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'nvidia_tesla_t4_$${1}'
  - job_name: 'gpu-pod-memory'
    static_configs:
        - targets:
          - "gpu-pod-exporter.nvidia.svc.cluster.local"
    metrics_path: '/metrics'
  - job_name: 'traefik'
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - traefik
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'traefik_(router|service|entrypoint)_request_duration_seconds_bucket|traefik_router_.*'
        action: drop
  - job_name: 'realestate-crawler-api'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - realestate-crawler
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: realestate-crawler-api
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
    metrics_path: '/metrics/'
  - job_name: 'realestate-crawler-celery'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - realestate-crawler
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: realestate-crawler-celery-metrics
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: instance
    metrics_path: '/metrics'
  - job_name: 'goflow2'
    static_configs:
        - targets:
          - "goflow2.monitoring.svc.cluster.local:8080"
    metrics_path: '/metrics'
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'goflow2_flow_process_nf_templates_total'
        action: drop

