version: 0.1
log:
  fields:
    service: registry-${name}
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
    maxsize: 5GiB
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
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
proxy:
  remoteurl: ${remote_url}
