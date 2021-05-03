# Helm values
# all values - https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml
alertmanager:
  persistentVolume:
    enabled: false
    #existingClaim: alertmanager-iscsi-pvc
    # storageClass: rook-cephfs
  strategy:
    type: Recreate
  ingress:
    enabled: "true"
    annotations:
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      # Enable client certificate authentication
      nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
      # Create the secret containing the trusted ca certificates
      nginx.ingress.kubernetes.io/auth-tls-secret: "default/ca-secret"
    tls:
      - secretName: "tls-secret"
        hosts:
          - "alertmanager.viktorbarzin.me"
    hosts:
      - "alertmanager.viktorbarzin.me"
alertmanagerFiles:
  alertmanager.yml:
    global:
      smtp_from: "alertmanager@viktorbarzin.me" 
      # smtp_smarthost: "smtp.viktorbarzin.me:587"
      smtp_smarthost: "mailserver.mailserver.svc.cluster.local:587"
      smtp_auth_username: "alertmanager@viktorbarzin.me"
      smtp_auth_password: "${alertmanager_mail_pass}"
      smtp_require_tls: true
    templates:
      - "/etc/alertmanager/template/*.tmpl"
    route:
      group_by: ["alertname"]
      group_wait: 3s
      group_interval: 5s
      repeat_interval: 1h
      receiver: SMTP_STARTTLS
    receivers:
      - name: 'SMTP_STARTTLS'
        email_configs:
          - to: "me@viktorbarzin.me"
            send_resolved: true
            tls_config:
              insecure_skip_verify: true

server:
  # Enable me to delete metrics
  extraFlags:
  #  - "web.enable-admin-api"
    - "storage.tsdb.allow-overlapping-blocks"
  persistentVolume:
    # enabled: false
    existingClaim: prometheus-iscsi-pvc
    # storageClass: rook-cephfs
  retention: "12w" # ~100GB storage
  strategy:
    type: Recreate
  ingress:
    enabled: "true"
    annotations:
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      # Enable client certificate authentication
      nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
      # Create the secret containing the trusted ca certificates
      nginx.ingress.kubernetes.io/auth-tls-secret: "default/ca-secret"
    tls:
      - secretName: "tls-secret"
        hosts:
          - "prometheus.viktorbarzin.me"
    hosts:
      - "prometheus.viktorbarzin.me"
  alertmanagers:
    - static_configs:
        - targets: 
          - "prometheus-alertmanager.monitoring.svc.cluster.local"
          # - "alertmanager.viktorbarzin.me"
      tls_config:
        insecure_skip_verify: true

serverFiles:
  # prometheus.yml: 
  #   alertingaaa:
  #     alertmanagers:
  #       - static_configs:
  #           targets: "alertmanager.viktorbarzin.lan"
  alerting_rules.yml:
    groups:
      - name: NodeDown
        rules:
        - alert: NodeDown
          expr: up{job="kubernetes-nodes"} == 0
          for: 1m
          labels:
            severity: page
          annotations:
            summary: Node {{$labels.instance}} down.
      - name: NodeHighCPUUsage
        rules:
        - alert: NodeHighCPUUsage
          expr: node_load1 > 2
          for: 10m
          labels:
            severity: page
          annotations:
            summary: "High CPU usage on node. Node load: {{ $value }}"
      # - name: PodStuckNotReady
      #   rules:
      #   - alert: PodStuckNotReady
      #     expr: kube_pod_status_ready{condition="true"} == 0
      #     for: 5m
      #     labels:
      #       severity: page
      #     annotations:
      #       summary: Pod stuck not ready.
      - name: ReadyPodsInDeploymentLessThanSpec
        rules:
        - alert: ReadyPodsInDeploymentLessThanSpec
          expr: kube_deployment_status_replicas_available - on(namespace, deployment) kube_deployment_spec_replicas < 0
          for: 10m
          labels:
            severity: page
          annotations:
            summary: Number of ready pods in deployment is less than what is defined in spec.
      - name: PowerOutage
        rules:
        - alert: PowerOutage
          expr:   r730_idrac_powerSupplyCurrentInputVoltage < 200
          labels:
            severity: page
          annotations:
            summary: Power voltage on a power supply is critically low indicating power outage.
      - name: HighPowerUsage
        rules:
        - alert: HighPowerUsage
          expr: (max(r730_idrac_amperageProbeReading) or on() vector(0)) > 112
          for: 30m
          labels:
            severity: page
          annotations:
            summary: "High Power usage. Baseline is 112W. Current reading: {{$value}}"
      - name: NoNodeLoadData
        rules:
        - alert: NoNodeLoadData
          expr: (node_load1 OR on() vector(0)) == 0
          for: 10m
          labels:
            severity: page
          annotations:
            summary: No node load data. Can signal that prometheus is not scraping
      - name: NoiDRACData
        rules:
        - alert: NoiDRACData
          expr: (max(r730_idrac_amperageProbeReading) or on() vector(0)) == 0
          for: 10m
          labels:
            severity: page
          annotations:
            summary: No iDRAC amperage reading. Can signal that prometheus is not scraping
      - name: OpenWRT High Memory Usage
        rules:
        - alert: OpenWRT High Memory Usage
          expr: 100 - ((openwrt_node_memory_MemAvailable_bytes * 100) / openwrt_node_memory_MemTotal_bytes) > 90
          for: 10m
          labels:
            severity: page
          annotations:
            summary: OpenWRT high memory usage. Can cause services getting stuck.

      - name: Mailserver Down
        rules:
        - alert: Mail server has no replicas available
          expr: (kube_deployment_status_replicas_available{namespace="mailserver"} or on() vector(0)) < 1
          for: 10m
          labels:
            severity: page
          annotations: 
            summary: Mail server has no available replicas. This means mail may not be received.
      - name: Hackmd Down
        rules:
        - alert: Hackmd has no replicas available
          expr: (kube_deployment_status_replicas_available{namespace="hackmd"} or on() vector(0)) < 1
          for: 1m
          labels:
            severity: page
          annotations: 
            summary: Hackmd has no available replicas. 
      - name: Privatebin Down
        rules:
        - alert: Privatebin has no replicas available
          expr: (kube_deployment_status_replicas_available{namespace="privatebin"} or on() vector(0)) < 1
          for: 10m
          labels:
            severity: page
          annotations: 
            summary: Privatebin has no available replicas. 
          
extraScrapeConfigs: |
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
    scrape_timeout: 2m
    metrics_path: /redfish
    static_configs:
      - targets:
        - idrac.viktorbarzin.lan
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
          - "home.viktorbarzin.lan:9100"
    metrics_path: '/metrics'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'home.viktorbarzin.lan:9100'
    metric_relabel_configs:
      - source_labels: [ __name__ ]
        target_label: '__name__'
        action: replace
        regex: '(.*)'
        replacement: 'openwrt_$${1}'
