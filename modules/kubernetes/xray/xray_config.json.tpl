{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 7443,
      "protocol": "vless",
      "settings": {
        "clients": ${clients},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.cloudflare.com:443",
          "xver": 0,
          "serverNames": [
            "www.cloudflare.com"
          ],
          "privateKey": "${reality_private_key}",
          "shortIds": ${reality_short_ids}
        }
      }
    },
    {
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": ${clients},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/xray/tls.crt",
              "keyFile": "/etc/xray/tls.key"
            }
          ]
        },
        "wsSettings": {
          "path": "/ws"
        }
      }
    },
    {
      "port": 9443,
      "protocol": "vless",
      "settings": {
        "clients": ${clients},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/xray/tls.crt",
              "keyFile": "/etc/xray/tls.key"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/grpc-vpn"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
