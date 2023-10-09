#!/usr/bin/expect -f

set timeout -1
set le_dir "/tmp/le/"
set config_dir "$le_dir/out/config"
set pwd [pwd]
set technitium_token "e28818f309a9ce7f72f0fcc867a365cf5d57b214751b75e2ef3ea74943ef23be"

spawn certbot certonly --manual --preferred-challenge=dns --email me@viktorbarzin.me --server https://acme-v02.api.letsencrypt.org/directory --agree-tos -d *.viktorbarzin.me -d viktorbarzin.me --config-dir $config_dir --work-dir $le_dir/workdir --logs-dir $le_dir/logsdir --no-eff-email

    # Create challenge TXT record
    curl "http://technitium-web.technitium.svc.cluster.local:5380/api/zones/records/add?token=$API_TOKEN&domain=_acme-challenge.\$CERTBOT_DOMAIN&type=TXT&ttl=60&text=\$CERTBOT_VALIDATION"

    # Sleep to make sure the change has time to propagate from primary to secondary name servers
    sleep 25
}
spawn /bin/sh 
send "echo \"$auth_contents\" > /root/certbot-auth.sh \r"
send "chmod 700 /root/certbot-auth.sh \r"
send "cat /root/certbot-auth.sh \r"
send "exit \r"

# Contents for certbot-cleanup
set cleanup_contents {#!/usr/bin/env sh
    exit 0  # DEBUG: TODO: Remove me
    # Generate API token from DNS web console
    API_TOKEN="e28818f309a9ce7f72f0fcc867a365cf5d57b214751b75e2ef3ea74943ef23be"

    # Delete challenge TXT record
    curl "http://technitium-web.technitium.svc.cluster.local:5380/api/zones/records/delete?token=$API_TOKEN&domain=_acme-challenge.\$CERTBOT_DOMAIN&type=TXT&text=\$CERTBOT_VALIDATION"
}
spawn /bin/sh 
send "echo \"$cleanup_contents\" > /root/certbot-cleanup.sh \r"
send "chmod 700 /root/certbot-cleanup.sh \r"
send "exit \r"

# Force deployment recreation
# exec terraform taint module.kubernetes_cluster.module.bind.module.bind-public-deployment.kubernetes_deployment.bind
exec terraform taint module.kubernetes_cluster.module.technitium.kubernetes_deployment.technitium
# set current_time [clock seconds]
# set formatted_time [clock format $current_time -format "+%Y-%m-%dT%TZ"]
# exec curl -X PATCH https://10.0.20.100:6443/apis/apps/v1/namespaces/technitium/deployments/technitium -H \"Authorization:Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" -H \"Content-Type:application/strategic-merge-patch+json\" -k -d '{\"spec\": {\"template\": {\"metadata\": { \"annotations\": {\"kubectl.kubernetes.io/restartedAt\": \"'$(date +%Y-%m-%dT%TZ)'\" }}}}}' 
# exec curl -X PATCH https://10.0.20.100:6443/apis/apps/v1/namespaces/technitium/deployments/technitium -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" -H "Content-Type: application/strategic-merge-patch+json" -k -d "{\"spec\": {\"template\": {\"metadata\": { \"annotations\": {\"kubectl.kubernetes.io/restartedAt\": \"$formatted_time\" }}}}}"
# exec terraform taint module.kubernetes_cluster.module.technitium.module.technitium.kubernetes_deployment.technitium
# Apply changes to configmap and redeploy
exec >@stdout 2>@stderr terraform apply -auto-approve -target=module.kubernetes_cluster.module.technitium

# Wait for deployment update
# TODO: better to use k8s api. What we want is `kubectl rollout status deployment -l app=bind-public` as a curl
# exec bash -c 'while [[ $(kubectl get pods -l app=bind-public -o \'jsonpath={..status.conditions[\?(\@.type=="Ready")].status}\') != "True" ]]; do echo "waiting pod..." && sleep 1; done'
exec >@stdout echo 'Waiting for redeployment of technitium...'
exec sleep 10

# spawn certbot certonly --manual --preferred-challenge=dns --email me@viktorbarzin.me --server https://acme-v02.api.letsencrypt.org/directory --agree-tos -d *.viktorbarzin.me -d viktorbarzin.me --config-dir $config_dir --work-dir $le_dir/workdir --logs-dir $le_dir/logsdir --no-eff-email

# set prompt "$"
# set dns_file "$pwd/modules/kubernetes/bind/extra/viktorbarzin.me"
# # expect -re "Please deploy a DNS TXT record under the name" {
# expect -re "Press Enter to Continue" {
#     set challenge [ exec sh -c "echo '$expect_out(buffer)' | tail -n 4 | head -n 1" ]
#     set dns_record "_acme-challenge IN TXT \"$challenge\""
#     puts "\nChallenge: '$challenge'"
#     # send \x03
#     puts "Dns file: '$dns_file'"

#     # Check if dns record is not already present
#     try {
#         set results [exec grep -q $dns_record $dns_file]
#         set status 0
#     } trap CHILDSTATUS {results options} {
#         set status [lindex [dict get $options -errorcode] 2]
#     }
#     if {$status != 0} {
#         exec echo $dns_record | tee -a $dns_file
#         puts "Teed into file"
#     } else {
#         puts "DNS record '$dns_record' already in file"
#     } 
# }

# send -- "\r"
# # Do the same for the 2nd dns record
# expect -re "\[a-zA-Z0-9_-\]{43}" {
#     set challenge $expect_out(0,string)
#     # set challenge [ exec sh -c "echo $expect_out(0, buffer) | tail -n 8 | head -n 1" ]
#     set dns_record1 "_acme-challenge IN TXT \"$challenge\""
#     puts "Challenge: '$challenge'"
#     puts "Dns record: '$dns_record1'"
#     puts "Dns file: '$dns_file'"

#     # Check if dns record is not already present
#     try {
#         set results [exec grep -q $dns_record1 $dns_file]
#         set status 0
#     } trap CHILDSTATUS {results options} {
#         set status [lindex [dict get $options -errorcode] 2]
#     }
#     if {$status != 0} {
#         exec echo $dns_record1 | tee -a $dns_file
#         puts "Teed into file"
#     } else {
#         puts "DNS record '$dns_record1' already in file"
#     } 
# }

# # Force deployment recreation
# # exec terraform taint module.kubernetes_cluster.module.bind.module.bind-public-deployment.kubernetes_deployment.bind
# exec terraform taint module.kubernetes_cluster.module.technitium.kubernetes_deployment.technitium
# # set current_time [clock seconds]
# # set formatted_time [clock format $current_time -format "+%Y-%m-%dT%TZ"]
# # exec curl -X PATCH https://10.0.20.100:6443/apis/apps/v1/namespaces/technitium/deployments/technitium -H \"Authorization:Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\" -H \"Content-Type:application/strategic-merge-patch+json\" -k -d '{\"spec\": {\"template\": {\"metadata\": { \"annotations\": {\"kubectl.kubernetes.io/restartedAt\": \"'$(date +%Y-%m-%dT%TZ)'\" }}}}}' 
# # exec curl -X PATCH https://10.0.20.100:6443/apis/apps/v1/namespaces/technitium/deployments/technitium -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" -H "Content-Type: application/strategic-merge-patch+json" -k -d "{\"spec\": {\"template\": {\"metadata\": { \"annotations\": {\"kubectl.kubernetes.io/restartedAt\": \"$formatted_time\" }}}}}"
# # exec terraform taint module.kubernetes_cluster.module.technitium.module.technitium.kubernetes_deployment.technitium
# # Apply changes to configmap and redeploy
# exec >@stdout 2>@stderr terraform apply -auto-approve -target=module.kubernetes_cluster.module.technitium

# # Wait for deployment update
# # TODO: better to use k8s api. What we want is `kubectl rollout status deployment -l app=bind-public` as a curl
# # exec bash -c 'while [[ $(kubectl get pods -l app=bind-public -o \'jsonpath={..status.conditions[\?(\@.type=="Ready")].status}\') != "True" ]]; do echo "waiting pod..." && sleep 1; done'
# exec >@stdout echo 'Waiting for redeployment of technitium...'
# exec sleep 10

# send -- "\r"

# # Clean up
# exec sed -i "s/$dns_record//g" "$dns_file"
# exec sed -i "s/$dns_record1//g" "$dns_file"

# Success
expect ".*Congratulations!"

# Copy cert and key to secrets dir 
exec cp --remove-destination $config_dir/live/viktorbarzin.me/fullchain.pem ./secrets
exec cp --remove-destination $config_dir/live/viktorbarzin.me/privkey.pem ./secrets

puts "Done renewing cert. Output certificates stored in ./secrets\n"
