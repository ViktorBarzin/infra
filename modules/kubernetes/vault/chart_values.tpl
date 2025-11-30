global:
  namespace: "vault"
  image:
    repository: "hashicorp/vault-k8s"
    tag: "1.7.0"
  agentImage:
    repository: "hashicorp/vault"
    tag: "1.20.4"
injector:
  metrics:
    enabled: true
server:
  image:
    repository: "hashicorp/vault"
    tag: "1.20.4"
  enabled: true
  volumes:
    - name: data
      emptyDir: {}
  ingress:
    enabled: false
ui:
  enabled: true
