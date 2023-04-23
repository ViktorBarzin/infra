tls:
  useSelfSigned: true
credentials:
  root:
    password: ${root_password}
    user: root
serverInstances: 1
podSpec:
 containers:
 - name: mysql
   resources:
     requests:
       memory: "1024Mi"  # adapt to your needs
       cpu: "1800m"      # adapt to your needs
     limits:
       memory: "2048Mi"  # adapt to your needs
       cpu: "3600m"      # adapt to your needs
