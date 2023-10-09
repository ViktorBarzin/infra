#!/usr/bin/env sh

set -e


export le_dir="/tmp/le/"
export config_dir="$le_dir/out/config"
export technitium_token="e28818f309a9ce7f72f0fcc867a365cf5d57b214751b75e2ef3ea74943ef23be"
export certbot_auth="$le_dir/certbot_auth.sh"
export certbot_cleanup="$le_dir/certbot_cleanup.sh"

mkdir $le_dir
cat << EOF > $certbot_auth
#!/usr/bin/env sh
# Generate API token from DNS web console
API_TOKEN="e28818f309a9ce7f72f0fcc867a365cf5d57b214751b75e2ef3ea74943ef23be"

# Create challenge TXT record
curl "http://technitium-web.technitium.svc.cluster.local:5380/api/zones/records/add?token=\$API_TOKEN&domain=_acme-challenge.\$CERTBOT_DOMAIN&type=TXT&ttl=60&text=\$CERTBOT_VALIDATION"

# Sleep to make sure the change has time to propagate from primary to secondary name servers
sleep 25
EOF

chmod 700 $certbot_auth
cat $certbot_auth


cat << EOF > $certbot_cleanup
#!/usr/bin/env sh
# Generate API token from DNS web console
API_TOKEN="e28818f309a9ce7f72f0fcc867a365cf5d57b214751b75e2ef3ea74943ef23be"

# Delete challenge TXT record
curl "http://technitium-web.technitium.svc.cluster.local:5380/api/zones/records/delete?token=\$API_TOKEN&domain=_acme-challenge.\$CERTBOT_DOMAIN&type=TXT&text=\$CERTBOT_VALIDATION"
EOF

chmod 700 $certbot_cleanup
cat $certbot_cleanup


certbot certonly --manual --preferred-challenges=dns --email me@viktorbarzin.me --server https://acme-v02.api.letsencrypt.org/directory --agree-tos --manual-auth-hook $certbot_auth --config-dir $config_dir --work-dir $le_dir/workdir --logs-dir $le_dir/logsdir --no-eff-email --manual-cleanup-hook $certbot_cleanup -d viktorbarzin.me -d *.viktorbarzin.me

exec cp --remove-destination $config_dir/live/viktorbarzin.me/fullchain.pem ./secrets
exec cp --remove-destination $config_dir/live/viktorbarzin.me/privkey.pem ./secrets

echo "Done renewing cert. Output certificates stored in ./secrets\n"
ls ./secrets
