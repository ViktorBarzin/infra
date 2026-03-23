version: 0.1
log:
  fields:
    service: registry-${name}
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
  maintenance:
    uploadpurging:
      enabled: true
      age: 24h
      interval: 4h
      dryrun: false
http:
  addr: :5000
  draintimeout: 60s
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
proxy:
  remoteurl: ${remote_url}
  ttl: 168h
