#!/usr/bin/expect -f

set timeout -1
set le_dir "/tmp/le/"
set config_dir "$le_dir/out/config"
set pwd [pwd]

spawn certbot certonly --manual --preferred-challenge=dns --email me@viktorbarzin.me --server https://acme-v02.api.letsencrypt.org/directory --agree-tos --manual-public-ip-logging-ok -d *.viktorbarzin.me -d viktorbarzin.me --config-dir $config_dir --work-dir $le_dir/workdir --logs-dir $le_dir/logsdir --no-eff-email

set prompt "$"
set dns_file "$pwd/modules/kubernetes/bind/extra/viktorbarzin.me"
expect -re "Please deploy a DNS TXT" {
    set challenge [ exec sh -c "echo '$expect_out(buffer)' | tail -n 3 | head -n 1" ]
    set dns_record "_acme-challenge IN TXT \"$challenge\""
    puts $dns_record
    puts $dns_file

    # Check if dns record is not already present
    try {
        set results [exec grep -q $dns_record $dns_file]
        set status 0
    } trap CHILDSTATUS {results options} {
        set status [lindex [dict get $options -errorcode] 2]
    }
    if {$status != 0} {
        exec echo $dns_record | tee -a $dns_file
        puts "Teed into file"
    } else {
        puts "DNS record '$dns_record' already in file"
    } 
}

send -- "\r"
# Do the same for the 2nd dns record
expect -re "Before continuing, verify" { 
    set challenge [ exec sh -c "echo '$expect_out(buffer)' | tail -n 3 | head -n 1" ]
    set dns_record1 "_acme-challenge IN TXT \"$challenge\""
    puts $dns_record1
    puts $dns_file

    # Check if dns record is not already present
    try {
        set results [exec grep -q $dns_record1 $dns_file]
        set status 0
    } trap CHILDSTATUS {results options} {
        set status [lindex [dict get $options -errorcode] 2]
    }
    if {$status != 0} {
        exec echo $dns_record1 | tee -a $dns_file
        puts "Teed into file"
    } else {
        puts "DNS record '$dns_record1' already in file"
    } 
}

# Force deployment recreation
exec terraform taint module.kubernetes_cluster.module.bind.module.bind-public-deployment.kubernetes_deployment.bind
# Apply changes to configmap and redeploy
exec >@stdout 2>@stderr terraform apply -auto-approve -target=module.kubernetes_cluster.module.bind

# Wait for deployment update
# TODO: better to use k8s api. What we want is `kubectl rollout status deployment -l app=bind-public` as a curl
# exec bash -c 'while [[ $(kubectl get pods -l app=bind-public -o \'jsonpath={..status.conditions[\?(\@.type=="Ready")].status}\') != "True" ]]; do echo "waiting pod..." && sleep 1; done'
exec >@stdout echo 'Waiting for redeployment of bind...'
exec sleep 10

send -- "\r"

# Clean up
exec sed -i "s/$dns_record//g" "$dns_file"
exec sed -i "s/$dns_record1//g" "$dns_file"

# Success
expect ".*Congratulations!"

# Copy cert and key to secrets dir 
exec cp --remove-destination $config_dir/live/viktorbarzin.me/fullchain.pem ./secrets
exec cp --remove-destination $config_dir/live/viktorbarzin.me/privkey.pem ./secrets

puts "Done renewing cert. Output certificates stored in ./secrets\n"
