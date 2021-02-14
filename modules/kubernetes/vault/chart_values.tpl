injector:
  metrics:
    enabled: true
server:
  enabled: true
  volumes:
    - name: data
      emptyDir: {}
  ingress:
    enabled: true
    annotations:
      "kubernetes.io/ingress.class": "nginx"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client": "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret": "default/ca-secret"
    hosts:
      - host: "${host}"
        paths:
          - /
    tls:
      - secretName: ${tls_secret_name}
        hosts:
            - "${host}"
ui:
  enabled: true
