# Helm values
# all values - https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml
alertmanager:
  replicaCount: 2
  persistentVolume:
    enabled: true
    existingClaim: alertmanager-pvc
    #existingClaim: alertmanager-iscsi-pvc
    # storageClass: rook-cephfs
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
          - alertname =~ "NodeNotReady|NodeConditionBad|PodCrashLooping|ContainerOOMKilled|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|DaemonSetMissingPods|ScrapeTargetDown|NodeLowFreeMemory|PostgreSQLDown|MySQLDown|RedisDown|HeadscaleDown|AuthentikDown|PoisonFountainDown|HackmdDown|PrivatebinDown|MailServerDown|NodeExporterDown|DockerRegistryDown|HomeAssistantDown|CloudflaredDown|TechnitiumDNSDown"
      # NFS down causes mass pod failures and NFS-dependent service outages
      - source_matchers:
          - alertname = NFSServerUnresponsive
        target_matchers:
          - alertname =~ "PodCrashLooping|ContainerOOMKilled|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|DaemonSetMissingPods|ScrapeTargetDown|PostgreSQLDown|MySQLDown|RedisDown|AuthentikDown|PoisonFountainDown|HackmdDown|PrivatebinDown|MailServerDown|HomeAssistantDown"
      # Traefik down makes service-level alerts noise
      - source_matchers:
          - alertname = TraefikDown
        target_matchers:
          - alertname =~ "HighServiceErrorRate|HighService4xxRate|HighServiceLatency|TraefikHighOpenConnections"
      # Traefik down makes ForwardAuth alerts redundant
      - source_matchers:
          - alertname = TraefikDown
        target_matchers:
          - alertname =~ "PoisonFountainDown|ForwardAuthFallbackActive"
      # Power outage makes on-battery alert redundant
      - source_matchers:
          - alertname = PowerOutage
        target_matchers:
          - alertname = OnBattery
      # Power outage suppresses everything downstream
      - source_matchers:
          - alertname = PowerOutage
        target_matchers:
          - alertname =~ "NodeDown|NFSServerUnresponsive|NodeExporterDown|CloudflaredDown|MetalLBSpeakerDown|MetalLBControllerDown"
    receivers:
      - name: slack-critical
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
            title: '{{ if eq .Status "firing" }}[CRITICAL]{{ else }}[RESOLVED]{{ end }} {{ .GroupLabels.alertname }} ({{ .Alerts | len }})'
            text: '{{ range .Alerts }}• {{ .Annotations.summary }}{{ "\n" }}{{ end }}'
      - name: slack-warning
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}warning{{ else }}good{{ end }}'
            title: '{{ if eq .Status "firing" }}[WARNING]{{ else }}[RESOLVED]{{ end }} {{ .GroupLabels.alertname }} ({{ .Alerts | len }})'
            text: '{{ range .Alerts }}• {{ .Annotations.summary }}{{ "\n" }}{{ end }}'
      - name: slack-info
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}#439FE0{{ else }}good{{ end }}'
            title: '[INFO] {{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}• {{ .Annotations.summary }}{{ "\n" }}{{ end }}'
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
server:
  # Enable me to delete metrics
  extraFlags:
    # - "web.enable-admin-api"
    - "web.enable-lifecycle"
    - "storage.tsdb.allow-overlapping-blocks"
    - "storage.tsdb.retention.size=180GB"
    - "storage.tsdb.wal-compression"
  persistentVolume:
    # enabled: false
    existingClaim: prometheus-data
    # storageClass: rook-cephfs
  retention: "52w"
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
  # 2. Mount it over the WAL directory
  extraVolumeMounts:
    - name: prometheus-wal-tmpfs
      mountPath: /data/wal  # Standard path for the chart
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
          - alert: NoiDRACData
            expr: (max(r730_idrac_idrac_system_health + 1) or on() vector(0)) == 0
            for: 30m
            labels:
              severity: info
            annotations:
              summary: "No iDRAC data for 30m - check Prometheus scraping"
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
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "GPU temp: {{ $value | printf \"%.0f\" }}°C (threshold: 65°C)"
          - alert: HighPowerUsage
            expr: nvidia_tesla_t4_DCGM_FI_DEV_POWER_USAGE > 50
            for: 30m
            labels:
              severity: info
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
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "UPS battery low: {{ $value | printf \"%.0f\" }} min remaining (threshold: 25 min)"
          - alert: PowerOutage
            expr: ups_upsInputVoltage < 150
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Power outage - input voltage: {{ $value | printf \"%.0f\" }}V (threshold: <150V)"
          - alert: HighPowerUsage
            expr: r730_idrac_idrac_power_control_consumed_watts > 200
            for: 60m
            labels:
              severity: info
            annotations:
              summary: "Server power: {{ $value | printf \"%.0f\" }}W (threshold: 200W)"
          - alert: UsingInverterEnergyForTooLong
            expr: automatic_transfer_switch_power_mode  > 0 # 1 = Inverter; 0 = Grid
            for: 24h
            labels:
              severity: info
            annotations:
              summary: "On inverter for >24h - check grid switchover"
      - name: Storage
        rules:
          - alert: NodeFilesystemFull
            expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.*"} / node_filesystem_size_bytes) * 100 < 10
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}% free (threshold: 10%)"
          - alert: PVFillingUp
            expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 95
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "PV {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }}: {{ $value | printf \"%.0f\" }}% used (threshold: 95%)"
          - alert: PVPredictedFull
            expr: predict_linear(kubelet_volume_stats_used_bytes[6h], 3600*24) > kubelet_volume_stats_capacity_bytes
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "PV {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }} predicted to fill within 24h"
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
              summary: "Fewer than 2 nodes have NFS activity for 10m — TrueNAS (10.0.10.15) may be down"
      - name: K8s Health
        rules:
          - alert: PodCrashLooping
            expr: increase(kube_pod_container_status_restarts_total[1h]) > 5 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.pod }}: {{ $value | printf \"%.0f\" }} restarts in 1h"
          - alert: ContainerOOMKilled
            expr: increase(container_oom_events_total{container!=""}[15m]) > 0 and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }}: OOM killed"
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
              summary: "Node {{ $labels.node }}: {{ $labels.condition }}"
          - alert: JobFailed
            expr: |
              kube_job_status_failed > 0
              and on(namespace, job_name)
              (time() - kube_job_status_start_time) < 3600
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Job {{ $labels.namespace }}/{{ $labels.job_name }}: {{ $value | printf \"%.0f\" }} failure(s)"
      - name: Infrastructure Health
        rules:
          - alert: HomeAssistantDown
            expr: up{job="haos"} == 0
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Home Assistant down: {{ $labels.instance }}"
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
            expr: (time() - kube_cronjob_status_last_successful_time{cronjob="backup-etcd", namespace="default"}) > 129600
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "etcd backup is {{ $value | humanizeDuration }} old (threshold: 36h)"
          - alert: EtcdBackupNeverSucceeded
            expr: kube_cronjob_status_last_successful_time{cronjob="backup-etcd", namespace="default"} == 0
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "etcd backup CronJob has never completed successfully"
          - alert: New Tailscale client
            expr: irate(headscale_machine_registrations_total{action="reauth"}[5m]) > 0
            for: 5m
            labels:
              severity: info
            annotations:
              summary: "New Tailscale client registered"
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
          - alert: MySQLDown
            expr: kube_statefulset_status_replicas_ready{namespace="dbaas", statefulset="mysql-cluster"} < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "MySQL InnoDB Cluster has no ready replicas"
          - alert: RedisDown
            expr: kube_statefulset_status_replicas_ready{namespace="redis", statefulset="redis-node"} < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Redis has no ready replicas"
          - alert: HeadscaleDown
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
            expr: (kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} or on() vector(0)) < 1
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
          - alert: MySQLOperatorDown
            expr: (kube_deployment_status_replicas_available{namespace="mysql-operator", deployment="mysql-operator"} or on() vector(0)) < 1
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "MySQL operator down — InnoDB Cluster management degraded"
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
          - alert: NodeHighCPUUsage
            expr: pve_cpu_usage_ratio * 100 > 60
            for: 6h
            labels:
              severity: info
            annotations:
              summary: "CPU usage on {{ $labels.node }}: {{ $value | printf \"%.0f\" }}% (threshold: 60%)"
          - alert: NodeLowFreeMemory
            expr: ((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) or on() vector(1)) * 100 > 95
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Memory usage on {{ $labels.node }}: {{ $value | printf \"%.0f\" }}% (threshold: 95%)"
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
          - alert: NodeMemoryPressureTrending
            expr: ((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100) > 85
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Memory usage on {{ $labels.instance }}: {{ $value | printf \"%.0f\" }}% (threshold: 85%)"
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
      - name: "Traefik Ingress"
        rules:
          - alert: TraefikDown
            expr: up{job="traefik"} == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Traefik pod {{ $labels.instance }} is down"
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
            expr: |
              (
                sum(rate(traefik_service_requests_total{code=~"4..", service!~".*nextcloud.*|.*grafana.*|.*linkwarden.*"}[5m])) by (service)
                / sum(rate(traefik_service_requests_total{service!~".*nextcloud.*|.*grafana.*|.*linkwarden.*"}[5m])) by (service)
                * 100
              ) > 30
              and sum(rate(traefik_service_requests_total{service!~".*nextcloud.*|.*grafana.*|.*linkwarden.*"}[5m])) by (service) > 0.1
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "4xx rate on {{ $labels.service }}: {{ $value | printf \"%.1f\" }}% (threshold: 30%)"
          - alert: HighServiceLatency
            expr: |
              histogram_quantile(0.99,
                sum(rate(traefik_service_request_duration_seconds_bucket[5m])) by (service, le)
              ) > 10
              and on() (time() - process_start_time_seconds{job="prometheus"}) > 900
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "p99 latency on {{ $labels.service }}: {{ $value | printf \"%.1f\" }}s (threshold: 10s)"
          - alert: TLSCertExpiringSoon
            expr: (traefik_tls_certs_not_after - time()) / 86400 < 7
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "TLS cert {{ $labels.cn }} expires in {{ $value | printf \"%.0f\" }} days"
          - alert: TraefikHighOpenConnections
            expr: sum(traefik_service_open_connections) by (service) > 500
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.service }} has {{ $value | printf \"%.0f\" }} open connections (threshold: 500)"
          - alert: ForwardAuthFallbackActive
            expr: |
              (kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} or on() vector(0)) < 1
              or (kube_deployment_status_replicas_available{namespace="authentik", deployment="goauthentik-server"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "ForwardAuth resilience proxy serving fallback - check Poison Fountain and Authentik"
          # - alert: OpenWRT High Memory Usage
          #   expr: 100 - ((openwrt_node_memory_MemAvailable_bytes * 100) / openwrt_node_memory_MemTotal_bytes) > 90
          #   for: 10m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: OpenWRT high memory usage. Can cause services getting stuck.
          # MailServerDown, HackmdDown, PrivatebinDown moved to "Application Health" group
          # New Tailscale client moved to "Infrastructure Health" group
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
            expr: |
              (
                kube_daemonset_status_desired_number_scheduled{namespace="metallb-system", daemonset="metallb-speaker"}
                - on(namespace, daemonset) kube_daemonset_status_number_ready{namespace="metallb-system", daemonset="metallb-speaker"}
              ) > 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "MetalLB speaker: {{ $value | printf \"%.0f\" }} pod(s) missing"
          - alert: MetalLBControllerDown
            expr: (kube_deployment_status_replicas_available{namespace="metallb-system", deployment="controller"} or on() vector(0)) < 1
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
          - alert: ISCSICSIControllerDown
            expr: (kube_deployment_status_replicas_available{namespace="iscsi-csi", deployment="democratic-csi-iscsi-controller"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "iSCSI CSI controller down — new iSCSI volume provisioning broken"
      - name: "Application Health"
        rules:
          - alert: MailServerDown
            expr: (kube_deployment_status_replicas_available{namespace="mailserver", deployment="mailserver"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Mail server has no available replicas - mail may not be received"
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

extraScrapeConfigs: |
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
  - job_name: 'caretta'
    static_configs:
        - targets:
          - "caretta-metrics.monitoring.svc.cluster.local:7117"
    metrics_path: '/metrics'
  - job_name: 'goflow2'
    static_configs:
        - targets:
          - "goflow2.monitoring.svc.cluster.local:8080"
    metrics_path: '/metrics'

