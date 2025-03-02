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
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      # Enable client certificate authentication
      # nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
      # Create the secret containing the trusted ca certificates
      # nginx.ingress.kubernetes.io/auth-tls-secret: "default/ca-secret"
      # nginx.ingress.kubernetes.io/auth-url: "https://oauth2.viktorbarzin.me/oauth2/auth"
      # nginx.ingress.kubernetes.io/auth-signin: "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
      nginx.ingress.kubernetes.io/auth-url: "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx"
      nginx.ingress.kubernetes.io/auth-signin: "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri"
      nginx.ingress.kubernetes.io/auth-response-headers: "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
      nginx.ingress.kubernetes.io/auth-snippet: "proxy_set_header X-Forwarded-Host $http_host;"
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
            title: "{{ range .Alerts }}[{{ toUpper .Status }}]{{ .Annotations.summary }}\n{{ end }}"
            text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
            # text: "<!channel> {{ .CommonAnnotations.summary }}:\n{{ .CommonAnnotations.description }}"
  # web.external-url seems to be hardcoded, edited deployment manually
  # extraArgs:
  #   web.external-url: "https://prometheus.viktorbarzin.me"
server:
  # Enable me to delete metrics
  extraFlags:
    #  - "web.enable-admin-api"
    - "web.enable-lifecycle"
    - "storage.tsdb.allow-overlapping-blocks"
    # - "storage.tsdb.retention.size=1GB"
  persistentVolume:
    # enabled: false
    existingClaim: prometheus-iscsi-pvc
    # storageClass: rook-cephfs
  retention: "12w"
  strategy:
    type: Recreate
  baseURL: "https://prometheus.viktorbarzin.me"
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      # Enable client certificate authentication
      # nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
      # Create the secret containing the trusted ca certificates
      # nginx.ingress.kubernetes.io/auth-tls-secret: "default/ca-secret"
      # nginx.ingress.kubernetes.io/auth-url: "https://oauth2.viktorbarzin.me/oauth2/auth"
      # nginx.ingress.kubernetes.io/auth-signin: "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
      "nginx.ingress.kubernetes.io/auth-url": "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx"
      "nginx.ingress.kubernetes.io/auth-signin": "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri"
      "nginx.ingress.kubernetes.io/auth-response-headers": "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
      "nginx.ingress.kubernetes.io/auth-snippet": "proxy_set_header X-Forwarded-Host $http_host;"

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
      - name: Cluster
        rules:
          - alert: LowVoltage
            expr: ups_upsInputVoltage < 205
            for: 10m
            labels:
              severity: page
            annotations:
              summary: "Low input voltage - {{ $value }}"
          - alert: OnBattery
            expr: ups_upsSecondsOnBattery > 0
            for: 30m
            labels:
              severity: critical
            annotations:
              summary: "UPS on battery for {{ $value }} seconds"
          - alert: LowUPBattery
            expr: ups_upsEstimatedMinutesRemaining < 25
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "UPS battery running out - {{ $value }} minutes remaining"
          - alert: NodeDown
            expr: (up{job="kubernetes-nodes"} or on() vector(0)) == 0
            for: 1m
            labels:
              severity: page
            annotations:
              summary: Node {{$labels.instance}} down.
          - alert: NodeHighCPUUsage
            expr: node_load1 > 2
            for: 20m
            labels:
              severity: page
            annotations:
              summary: "High CPU usage on {{ $labels.node }} - {{ $value }}"
          - alert: NodeLowFreeMemory
            expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) or on() vector(1)) > 0.9
            for: 10m
            labels:
              severity: page
            annotations:
              summary: "Low free memory on {{ $labels.node }} - {{ $value }}"
          # - name: PodStuckNotReady
          #   rules:
          #   - alert: PodStuckNotReady
          #     expr: kube_pod_status_ready{condition="true"} == 0
          #     for: 5m
          #     labels:
          #       severity: page
          #     annotations:
          #       summary: Pod stuck not ready.
          - alert: ReadyPodsInDeploymentLessThanSpec
            expr: kube_deployment_status_replicas_available - on(namespace, deployment) kube_deployment_spec_replicas < 0
            for: 10m
            labels:
              severity: page
            annotations:
              summary: Number of ready pods in {{ $labels.deployment }} is less than what is defined in spec.
          - alert: PowerOutage
            expr: ups_upsInputVoltage < 150
            labels:
              severity: page
            annotations:
              summary: Power voltage on a power supply is {{ $value }} indicating power outage.
          - alert: HighPowerUsage
            expr: (max_over_time(r730_idrac_redfish_chassis_power_average_consumed_watts[20m])) > 133
            for: 60m
            labels:
              severity: page
            annotations:
              summary: "High server power usage - {{$value}} watts"
          - alert: NoNodeLoadData
            expr: (node_load1 OR on() vector(0)) == 0
            for: 10m
            labels:
              severity: page
            annotations:
              summary: No node load data. Can signal that prometheus is not scraping
          - alert: NoiDRACData
            expr: (max(r730_idrac_redfish_chassis_power_average_consumed_watts) or on() vector(0)) == 0
            for: 10m
            labels:
              severity: page
            annotations:
              summary: No iDRAC amperage reading. Can signal that prometheus is not scraping
          - alert: HighIngressPermissionErrors
            expr: (sum(rate(nginx_ingress_controller_requests{status=~"4.*"}[2m])) by (ingress) / sum(rate(nginx_ingress_controller_requests[2m])) by (ingress)  * 100) > 10
            for: 10m
            labels:
              severity: page
            annotations:
              summary: "High permission error rate for {{ $labels.ingress }}: {{ $value }}%."
          - alert: HighIngressServerErrors
            expr: (sum(rate(nginx_ingress_controller_requests{status=~"5.*"}[2m])) by (ingress) / sum(rate(nginx_ingress_controller_requests[2m])) by (ingress)  * 100) > 10
            for: 20m
            labels:
              severity: page
            annotations:
              summary: "High server failiure rate for {{ $labels.ingress }}: {{ $value }}%."
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
              summary: New tailscale client registered

extraScrapeConfigs: |
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
    static_configs:
        - targets:
          - "idrac.viktorbarzin.lan:161"
    metrics_path: '/snmp'
    params:
      module: [dell_idrac]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'prometheus-snmp-exporter.monitoring.svc.cluster.local:9116'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'r730_idrac_$${1}'
  - job_name: 'redfish-idrac'
    scrape_interval: 5m
    scrape_timeout: 4m
    metrics_path: /redfish
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
