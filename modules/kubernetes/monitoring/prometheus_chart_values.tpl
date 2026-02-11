# Helm values
# all values - https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml
alertmanager:
  persistentVolume:
    enabled: true
    existingClaim: alertmanager-pvc
    #existingClaim: alertmanager-iscsi-pvc
    # storageClass: rook-cephfs
  strategy:
    type: Recreate
  baseURL: "https://alertmanager.viktorbarzin.me"
  ingress:
    enabled: true
    ingressClassName: "traefik"
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: "traefik-rate-limit@kubernetescrd,traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd"
      traefik.ingress.kubernetes.io/router.entrypoints: "websecure"
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
      # group_by: ["alertname"]
      group_by: [] # disable grouping
      group_wait: 3s
      group_interval: 5s # how long to wait before sending new alert for the same group
      repeat_interval: 1h
      receiver: ALL
    receivers:
      - name: ALL
        # email_configs:
        #   - to: "me@viktorbarzin.me"
        #     send_resolved: true
        #     tls_config:
        #       insecure_skip_verify: true
        slack_configs:
          - send_resolved: true
            channel: "#alerts"
            color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
            title: '{{ range .Alerts }}[{{ toUpper .Status }}] {{ .Labels.alertname }}{{ end }}'
            text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'
            # text: "<!channel> {{ .CommonAnnotations.summary }}:\n{{ .CommonAnnotations.description }}"
  # web.external-url seems to be hardcoded, edited deployment manually
  # extraArgs:
  #   web.external-url: "https://prometheus.viktorbarzin.me"
# prometheus-node-exporter:
#   enabled: true
server:
  # Enable me to delete metrics
  extraFlags:
    # - "web.enable-admin-api"
    - "web.enable-lifecycle"
    - "storage.tsdb.allow-overlapping-blocks"
    # - "storage.tsdb.retention.size=1GB"
    - "storage.tsdb.wal-compression"
  persistentVolume:
    # enabled: false
    existingClaim: prometheus-iscsi-pvc
    # storageClass: rook-cephfs
  retention: "52w"
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
            expr: node_hwmon_temp_celsius{instance="pve-node-r730"} * on(chip) group_left(chip_name) node_hwmon_chip_names{instance="pve-node-r730"} > 60
            for: 30m
            labels:
              severity: page
            annotations:
              summary: "CPU temp: {{ $value | printf \"%.0f\" }}°C (threshold: 60°C)"
          - alert: SSDHighWriteRate
            expr: rate(node_disk_written_bytes_total{job="proxmox-host", device="sdb"}[2m]) / 1024 / 1024 > 2 # sdb is SSD; value in MB
            for: 10m
            labels:
              severity: page
            annotations:
              summary: "SSD write rate: {{ $value | printf \"%.1f\" }} MB/s (threshold: 2 MB/s)"
          - alert: HDDHighWriteRate
            expr: rate(node_disk_written_bytes_total{job="proxmox-host", device="sdc"}[2m]) / 1024 / 1024 > 10 # sdc is 11TB HDD; value in MB
            for: 20m
            labels:
              severity: page
            annotations:
              summary: "HDD write rate: {{ $value | printf \"%.1f\" }} MB/s (threshold: 10 MB/s)"
          - alert: NoiDRACData
            expr: (max(r730_idrac_idrac_system_health + 1) or on() vector(0)) == 0
            for: 30m
            labels:
              severity: page
            annotations:
              summary: "No iDRAC data for 30m - check Prometheus scraping"
          - alert: HighSystemLoad
            expr: scalar(node_load1{instance="pve-node-r730"}) * 100 / count(count(node_cpu_seconds_total{instance="pve-node-r730"}) by (cpu)) > 50
            for: 30m
            labels:
              severity: page
            annotations:
              summary: "System load: {{ $value | printf \"%.0f\" }}% (threshold: 50%)"
      - name: Nvidia Tesla T4 GPU
        rules:
          - alert: HighGPUTemp
            expr: nvidia_tesla_t4_DCGM_FI_DEV_GPU_TEMP > 65
            for: 1m
            labels:
              severity: page
            annotations:
              summary: "GPU temp: {{ $value | printf \"%.0f\" }}°C (threshold: 65°C)"
          - alert: HighPowerUsage
            expr: nvidia_tesla_t4_DCGM_FI_DEV_POWER_USAGE > 50
            for: 30m
            labels:
              severity: page
            annotations:
              summary: "GPU power: {{ $value | printf \"%.0f\" }}W (threshold: 50W)"
          - alert: HighUtilization
            expr: nvidia_tesla_t4_DCGM_FI_DEV_GPU_UTIL > 50
            for: 30m
            labels:
              severity: page
            annotations:
              summary: "GPU util: {{ $value | printf \"%.0f\" }}% (threshold: 50%)"
          - alert: HighMemoryUsage
            expr: nvidia_tesla_t4_DCGM_FI_DEV_FB_USED / 1024 > 12
            for: 5m
            labels:
              severity: page
            annotations:
              summary: "VRAM used: {{ $value | printf \"%.1f\" }} GB (threshold: 12 GB)"
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
            labels:
              severity: page
            annotations:
              summary: "Power outage - input voltage: {{ $value | printf \"%.0f\" }}V (threshold: <150V)"
          - alert: HighPowerUsage
            expr: r730_idrac_idrac_power_control_consumed_watts > 200
            for: 60m
            labels:
              severity: page
            annotations:
              summary: "Server power: {{ $value | printf \"%.0f\" }}W (threshold: 200W)"
          - alert: UsingInverterEnergyForTooLong
            expr: automatic_transfer_switch_power_mode  > 0 # 1 = Inverter; 0 = Grid
            for: 24h
            labels:
              severity: page
            annotations:
              summary: "On inverter for >24h - check grid switchover"
      - name: Cluster
        rules:
          - alert: NodeDown
            expr: (up{job="kubernetes-nodes"} or on() vector(0)) == 0
            for: 1m
            labels:
              severity: page
            annotations:
              summary: "Node down: {{ $labels.instance }}"
          - alert: DockerRegistryDown
            expr: (registry_process_start_time_seconds or on() vector(0)) == 0
            for: 10m
            labels:
              severity: page
            annotations:
              summary: "Docker registry down for 10m"
          - alert: RegistryLowCacheHitRate
            expr: (sum by (job) (rate(registry_registry_storage_cache_total{type="Hit"}[15m]))) / (sum by (job) (rate(registry_registry_storage_cache_total{type="Request"}[15m]))) * 100 < 50
            for: 12h
            labels:
              severity: page
            annotations:
              summary: "Registry cache hit rate: {{ $value | printf \"%.0f\" }}% (threshold: 50%)"
          - alert: NodeHighCPUUsage
            expr: pve_cpu_usage_ratio * 100 > 30
            for: 6h
            labels:
              severity: page
            annotations:
              summary: "CPU usage on {{ $labels.node }}: {{ $value | printf \"%.0f\" }}% (threshold: 30%)"
          - alert: NodeLowFreeMemory
            expr: ((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) or on() vector(1)) * 100 > 95
            for: 10m
            labels:
              severity: page
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
            for: 15m
            labels:
              severity: page
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.deployment }}: {{ $value | printf \"%.0f\" }} replica(s) unavailable"
          - alert: StatefulSetReplicasMismatch
            expr: |
              (
                kube_statefulset_replicas
                - on(namespace, statefulset) kube_statefulset_status_replicas_ready
              ) > 0
            for: 15m
            labels:
              severity: page
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.statefulset }}: {{ $value | printf \"%.0f\" }} replica(s) unavailable"
          - alert: DaemonSetMissingPods
            expr: |
              (
                kube_daemonset_status_desired_number_scheduled
                - on(namespace, daemonset) kube_daemonset_status_number_ready
              ) > 0
            for: 15m
            labels:
              severity: page
            annotations:
              summary: "{{ $labels.namespace }}/{{ $labels.daemonset }}: {{ $value | printf \"%.0f\" }} pod(s) missing"
          - alert: NoNodeLoadData
            expr: (node_load1 OR on() vector(0)) == 0
            for: 10m
            labels:
              severity: page
            annotations:
              summary: "No node load data for 10m - check Prometheus scraping"
          - alert: HighIngressPermissionErrors
            expr: (sum(rate(nginx_ingress_controller_requests{status=~"4.*", ingress!="nextcloud", ingress!="grafana"}[2m])) by (ingress) / sum(rate(nginx_ingress_controller_requests[2m])) by (ingress)  * 100) > 10
            for: 20m
            labels:
              severity: page
            annotations:
              summary: "4xx rate on {{ $labels.ingress }}: {{ $value | printf \"%.1f\" }}% (threshold: 10%)"
          - alert: HighIngressServerErrors
            expr: (sum(rate(nginx_ingress_controller_requests{status=~"5.*", ingress!="nextcloud", ingress!="grafana", ingress!="matrix"}[2m])) by (ingress) / sum(rate(nginx_ingress_controller_requests[2m])) by (ingress)  * 100)  > 10
            for: 20m
            labels:
              severity: page
            annotations:
              summary: "5xx rate on {{ $labels.ingress }}: {{ $value | printf \"%.1f\" }}% (threshold: 10%)"
          # - alert: OpenWRT High Memory Usage
          #   expr: 100 - ((openwrt_node_memory_MemAvailable_bytes * 100) / openwrt_node_memory_MemTotal_bytes) > 90
          #   for: 10m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: OpenWRT high memory usage. Can cause services getting stuck.
          # - alert: Mail server has no replicas available
          #   expr: (kube_deployment_status_replicas_available{namespace="mailserver"} or on() vector(0)) < 1
          #   for: 10m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: Mail server has no available replicas. This means mail may not be received.
          # - alert: Hackmd has no replicas available
          #   expr: (kube_deployment_status_replicas_available{namespace="hackmd"} or on() vector(0)) < 1
          #   for: 1m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: Hackmd has no available replicas.
          # - alert: Privatebin has no replicas available
          #   expr: (kube_deployment_status_replicas_available{namespace="privatebin"} or on() vector(0)) < 1
          #   for: 10m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: Privatebin has no available replicas.
          # - name: London OpenWRT Down
          #   rules:
          #     - alert: OpenWRT client unreachable
          #       expr: (openwrt_node_openwrt_info or on() vector(0)) == 0
          #       for: 10m
          #       labels:
          #         severity: page
          #       annotations:
          #         summary: London OpenWRT router unreachable through VPN
          # - alert: OpenWRT high system load
          #   expr: openwrt_node_load1 > 0.9
          #   for: 15m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: High system load on OpenWRT
          # - alert: Finance app webhook exceptions
          #   expr: changes(webhook_failure_total[5m]) >= 1
          #   for: 1m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: Finance app webhook exceptions
          # - alert: Finance app unhandled exceptions
          #   expr: changes(flask_http_request_exceptions_total[5m]) >= 1
          #   for: 1m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: Finance app unhandled exceptions
          - alert: New Tailscale client
            expr: irate(headscale_machine_registrations_total{action="reauth"}[5m]) > 0
            labels:
              severity: page
            annotations:
              summary: "New Tailscale client registered"

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
          - "idrac.viktorbarzin.lan:161"
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
          - "ups.viktorbarzin.lan:161"
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
          - "ha-sofia.viktorbarzin.lan:8123"
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
    
