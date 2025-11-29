This contains the setup for setting up a remote machine that serves a keyfile for decrypting a luks volume

1. Install nginx
```
sudo apt update
sudo apt install nginx apache2-utils -y
```

2. Create User for basic auth

```
sudo htpasswd -c /etc/nginx/.htpasswd truenas
```

3. Create secure directory and key file

```
sudo mkdir -p /srv/keys
head -c 128 /dev/urandom | sudo tee /srv/keys/truenas.key >/dev/null
```

4. Create rate limit zone
```
# /etc/nginx/conf.d/ratelimit.conf

# Allow only 3 key requests per minute per IP
limit_req_zone $binary_remote_addr zone=keylimit:10m rate=3r/m;
```

5. Configure nginx virtual host
```
# /etc/nginx/sites-available/keyserver.conf

server {
    listen 443 ssl;
    server_name <ip address here>;

    # TLS certificate and key (we will set these in the next step)
    ssl_certificate     /etc/ssl/certs/keyserver.crt;
    ssl_certificate_key /etc/ssl/private/keyserver.key;

    # Enforce strong TLS
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # Rate limiting zone created earlier
    limit_req zone=keylimit burst=2 nodelay;

    location /keys/ {
        alias /srv/keys/;

        # Basic auth
        auth_basic           "Restricted";
        auth_basic_user_file /etc/nginx/.htpasswd;

        # Disable directory listing
        autoindex off;

        # Prevent caching
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
    }
}
```

6. Enable the host:
```
sudo ln -s /etc/nginx/sites-available/keyserver.conf /etc/nginx/sites-enabled/
```

7. Disable default host:
```
sudo rm /etc/nginx/sites-enabled/default
```
