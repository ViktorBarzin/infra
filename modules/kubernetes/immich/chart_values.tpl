## This chart relies on the common library chart from bjw-s
## You can find it at https://github.com/bjw-s/helm-charts/tree/main/charts/library/common
## Refer there for more detail about the supported values

# These entries are shared between all the Immich components
defaultPodOptions:
  annotations:
    diun.enable: "true"

env:
  # REDIS_HOSTNAME: '{{ printf "%s-redis-master" .Release.Name }}'
  REDIS_HOSTNAME: "redis.redis.svc.cluster.local"
  # DB_HOSTNAME: "postgresql.dbaas"
  # DB_USERNAME: "immich"
  # DB_DATABASE_NAME: "immich"
  # #   # -- You should provide your own secret outside of this helm-chart and use `postgresql.global.postgresql.auth.existingSecret` to provide credentials to the postgresql instance
  # DB_PASSWORD: "${postgresql_password}"
  # TYPESENSE_ENABLED: "{{ .Values.typesense.enabled }}"
  # TYPESENSE_ENABLED: "1"
  #   TYPESENSE_API_KEY: "{{ .Values.typesense.env.TYPESENSE_API_KEY }}"
  #   TYPESENSE_HOST: '{{ printf "%s-typesense" .Release.Name }}'
  #   IMMICH_WEB_URL: '{{ printf "http://%s-web:3000" .Release.Name }}'
  # IMMICH_WEB_URL: "http://immich-web.immich.svc.cluster.local:3000"
  # IMMICH_WEB_URL: "http://immich-server.immich.svc.cluster.local:3001"
  #   IMMICH_SERVER_URL: '{{ printf "http://%s-server:3001" .Release.Name }}'
  # IMMICH_SERVER_URL: "http://immich-server.immich.svc.cluster.local:3001"
  # IMMICH_SERVER_URL: "http://immich-server.immich.svc.cluster.local:2283"
  #   IMMICH_MACHINE_LEARNING_URL: '{{ printf "http://%s-machine-learning:3003" .Release.Name }}'
  # IMMICH_MACHINE_LEARNING_URL: "http://immich-machine-learning.immich.svc.cluster.local:3003"

image:
  tag: v2.2.1

immich:
  persistence:
    # Main data store for all photos shared between different components.
    library:
      # Automatically creating the library volume is not supported by this chart
      # You have to specify an existing PVC to use
      existingClaim: immich

redis:
  enabled: false
  architecture: standalone
  auth:
    enabled: false

# Immich components

server:
  enabled: true
  image:
    repository: ghcr.io/immich-app/immich-server
    pullPolicy: IfNotPresent

# increase liveliness and readiness checks to allow enough time for downloading models
machine-learning:
  enabled: true
  image:
    repository: ghcr.io/immich-app/immich-machine-learning
    pullPolicy: IfNotPresent
  env:
    TRANSFORMERS_CACHE: /cache
    # MACHINE_LEARNING_PRELOAD__CLIP:  immich-app/ViT-H-14-378-quickgelu__dfn5b # too big(?)
    # MACHINE_LEARNING_PRELOAD__CLIP: immich-app/ViT-L-16-SigLIP-384__webli # too big(?)
    #MACHINE_LEARNING_PRELOAD__CLIP: ViT-B-32__openai # too big(?)
    MACHINE_LEARNING_PRELOAD__CLIP: ViT-B-16-SigLIP2__webli
  persistence:
    cache:
      enabled: true
      size: 10Gi
      # Optional: Set this to pvc to avoid downloading the ML models every start.
      type: emptyDir
      accessMode: ReadWriteMany
