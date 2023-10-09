#!/usr/bin/env sh

set -e


export le_dir="/tmp/le/"
export config_dir="$le_dir/out/config"
export technitium_token="$TECHNITIUM_API_KEY"
export certbot_auth="$le_dir/certbot_auth.sh"
export certbot_cleanup="$le_dir/certbot_cleanup.sh"

mkdir $le_dir
echo "Creating $certbot_auth"
cat << EOF > $certbot_auth
#!/usr/bin/env sh
# Generate API token from DNS web console
API_TOKEN="$technitium_token"

# Create challenge TXT record
curl "http://technitium-web.technitium.svc.cluster.local:5380/api/zones/records/add?token=\$API_TOKEN&domain=_acme-challenge.\$CERTBOT_DOMAIN&type=TXT&ttl=60&text=\$CERTBOT_VALIDATION"

# Sleep to make sure the change has time to propagate from primary to secondary name servers
sleep 25
EOF

chmod 700 $certbot_auth
cat $certbot_auth


echo "Creating $certbot_cleanup"
cat << EOF > $certbot_cleanup
#!/usr/bin/env sh
# Generate API token from DNS web console
API_TOKEN="$technitium_token"

# Delete challenge TXT record
curl "http://technitium-web.technitium.svc.cluster.local:5380/api/zones/records/delete?token=\$API_TOKEN&domain=_acme-challenge.\$CERTBOT_DOMAIN&type=TXT&text=\$CERTBOT_VALIDATION"
EOF

chmod 700 $certbot_cleanup
cat $certbot_cleanup


echo "Executing certbot renew command"
certbot certonly --manual --preferred-challenges=dns --email me@viktorbarzin.me --server https://acme-v02.api.letsencrypt.org/directory --agree-tos --manual-auth-hook $certbot_auth --config-dir $config_dir --work-dir $le_dir/workdir --logs-dir $le_dir/logsdir --no-eff-email --manual-cleanup-hook $certbot_cleanup -d viktorbarzin.me -d *.viktorbarzin.me

exec cp --remove-destination $config_dir/live/viktorbarzin.me/fullchain.pem ./secrets
exec cp --remove-destination $config_dir/live/viktorbarzin.me/privkey.pem ./secrets

echo "Done renewing cert. Output certificates stored in ./secrets\n"
ls ./secrets
