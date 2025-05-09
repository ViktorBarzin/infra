replicaCount: 1

deployment:
  image: quay.io/go-skynet/local-ai:latest
  env:
    threads: 4
    context_size: 512
  modelsPath: "/models"

resources:
  {}
  # We usually recommend not to specify default resources and to leave this as a conscious
  # choice for the user. This also increases chances charts run on environments with little
  # resources, such as Minikube. If you do want to specify resources, uncomment the following
  # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
  # limits:
  #   cpu: 100m
  #   memory: 128Mi
  # requests:
  #   cpu: 100m
  #   memory: 128Mi

# Prompt templates to include
# Note: the keys of this map will be the names of the prompt template files
promptTemplates:
  {}
  # ggml-gpt4all-j.tmpl: |
  #   The prompt below is a question to answer, a task to complete, or a conversation to respond to; decide which and write an appropriate response.
  #   ### Prompt:
  #   {{.Input}}
  #   ### Response:

# Models to download at runtime
models:
  # Whether to force download models even if they already exist
  forceDownload: false

  # The list of URLs to download models from
  # Note: the name of the file will be the name of the loaded model
  list:
    - url:
        "https://gpt4all.io/models/ggml-gpt4all-j.bin"
        # basicAuth: base64EncodedCredentials

  # Persistent storage for models and prompt templates.
  # PVC and HostPath are mutually exclusive. If both are enabled,
  # PVC configuration takes precedence. If neither are enabled, ephemeral
  # storage is used.
  persistence:
    pvc:
      enabled: false
      size: 2Gi
      accessModes:
        - ReadWriteOnce

      annotations: {}

      # Optional
      storageClass: ~

    hostPath:
      enabled: false
      path: "/models"

service:
  type: ClusterIP
  port: 80
  annotations: {}
  # If using an AWS load balancer, you'll need to override the default 60s load balancer idle timeout
  # service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout: "1200"

ingress:
  enabled: true
  className: "nginx"
  annotations:
    {}
    # kubernetes.io/ingress.class: nginx
    # kubernetes.io/tls-acme: "true"
  hosts:
    - host: ai.viktorbarzin.me
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls:
    - secretName: "${tls_secret}"
      hosts:
        - ai.viktorbarzin.me

nodeSelector: {}

tolerations: []

affinity: {}
