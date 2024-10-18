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
  #   DB_HOSTNAME: "{{ .Release.Name }}-postgresql"
  #   DB_USERNAME: "{{ .Values.postgresql.global.postgresql.auth.username }}"
  #   DB_DATABASE_NAME: "{{ .Values.postgresql.global.postgresql.auth.database }}"
  #   # -- You should provide your own secret outside of this helm-chart and use `postgresql.global.postgresql.auth.existingSecret` to provide credentials to the postgresql instance
  #   DB_PASSWORD: "{{ .Values.postgresql.global.postgresql.auth.password }}"
  # TYPESENSE_ENABLED: "{{ .Values.typesense.enabled }}"
  # TYPESENSE_ENABLED: "1"
  #   TYPESENSE_API_KEY: "{{ .Values.typesense.env.TYPESENSE_API_KEY }}"
  #   TYPESENSE_HOST: '{{ printf "%s-typesense" .Release.Name }}'
  #   IMMICH_WEB_URL: '{{ printf "http://%s-web:3000" .Release.Name }}'
  # IMMICH_WEB_URL: "http://immich-web.immich.svc.cluster.local:3000"
  # IMMICH_WEB_URL: "http://immich-server.immich.svc.cluster.local:3001"
  #   IMMICH_SERVER_URL: '{{ printf "http://%s-server:3001" .Release.Name }}'
  IMMICH_SERVER_URL: "http://immich-server.immich.svc.cluster.local:3001"
  #   IMMICH_MACHINE_LEARNING_URL: '{{ printf "http://%s-machine-learning:3003" .Release.Name }}'
  IMMICH_MACHINE_LEARNING_URL: "http://immich-machine-learning.immich.svc.cluster.local:3003"

image:
  tag: v1.116.2
  # tag: v1.117.0 # not working
  # tag: v1.118.1

immich:
  persistence:
    # Main data store for all photos shared between different components.
    library:
      # Automatically creating the library volume is not supported by this chart
      # You have to specify an existing PVC to use
      existingClaim: immich

# Dependencies

postgresql:
  enabled: true
  image:
    repository: tensorchord/pgvecto-rs
    tag: pg14-v0.2.0
  global:
    postgresql:
      auth:
        username: immich
        database: immich
        password: "${postgresql_password}"

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

machine-learning:
  enabled: true
  image:
    repository: ghcr.io/immich-app/immich-machine-learning
    pullPolicy: IfNotPresent
  env:
    TRANSFORMERS_CACHE: /cache
  persistence:
    cache:
      enabled: true
      size: 10Gi
      # Optional: Set this to pvc to avoid downloading the ML models every start.
      type: emptyDir
      accessMode: ReadWriteMany
