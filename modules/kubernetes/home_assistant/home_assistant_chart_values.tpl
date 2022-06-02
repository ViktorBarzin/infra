# hostname: home-assistant

ingress:
  main:
    # -- Enables or disables the ingress
    enabled: true

    # -- Make this the primary ingress (used in probes, notes, etc...).
    # If there is more than 1 ingress, make sure that only 1 ingress is marked as primary.
    primary: true

    # -- Override the name suffix that is used for this ingress.
    nameOverride:

    # -- Provide additional annotations which may be required.
    annotations: #{}
      kubernetes.io/ingress.class                        : "nginx"
      nginx.ingress.kubernetes.io/force-ssl-redirect     : "true"
      nginx.ingress.kubernetes.io/auth-tls-verify-client : "on"
      nginx.ingress.kubernetes.io/auth-tls-secret        : ${client_certificate_secret_name}
      # kubernetes.io/ingress.class: nginx
      # kubernetes.io/tls-acme: "true"

    # -- Provide additional labels which may be required.
    labels: {}

    # -- Set the ingressClass that is used for this ingress.
    # Requires Kubernetes >=1.19
    ingressClassName:  # "nginx"

    ## Configure the hosts for the ingress
    hosts:
      -  # -- Host address. Helm template can be passed.
        host: home-assistant.viktorbarzin.me
        ## Configure the paths for the host
        paths:
          -  # -- Path.  Helm template can be passed.
            path: /
            # -- Ignored if not kubeVersion >= 1.14-0
            pathType: Prefix
            service:
              # -- Overrides the service name reference for this path
              name: home-assistant
              # -- Overrides the service port reference for this path
              port: 8123

    # -- Configure TLS for the ingress. Both secretName and hosts can process a Helm template.
    tls: #[]
      - secretName: ${tls_secret_name}
        hosts:
          - home-assistant.viktorbarzin.me

# -- Configure persistence for the chart here.
# Additional items can be added by adding a dictionary key similar to the 'config' key.
# [[ref]](http://docs.k8s-at-home.com/our-helm-charts/common-library-storage)
# @default -- See below
persistence:
  # -- Default persistence for configuration files.
  # @default -- See below
  config:
    # -- Enables or disables the persistence item
    enabled: false

    # -- Sets the persistence type
    # Valid options are pvc, emptyDir, hostPath, secret, configMap or custom
    type: configMap
    name: home-assistant-configmap

    # -- Where to mount the volume in the main container.
    # Defaults to `/<name_of_the_volume>`,
    # setting to '-' creates the volume but disables the volumeMount.
    mountPath:  /config
    # -- Specify if the volume should be mounted read-only.
    readOnly: true
