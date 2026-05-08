#!/usr/bin/env bash

set -e

if ! command -v uuidgen >/dev/null 2>&1; then
  echo "uuidgen is not installed"
  exit 1
fi

read -p "Enter domain: " DOMAIN
read -p "Enter email: " EMAIL
read -p "Enter path: " PATH_NAME

UUID=$(uuidgen)

XRAY_DIR="/usr/local/etc/xray"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

echo "[1/5] Installing nginx and certbot..."
apt update
apt install -y nginx certbot python3-certbot-nginx curl socat

echo "[2/5] Configuring nginx..."

cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        return 200 'ok';
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN

nginx -t
systemctl restart nginx

echo "[3/5] Requesting SSL certificate..."

certbot certonly \
  --nginx \
  --agree-tos \
  --no-eff-email \
  --email "$EMAIL" \
  -d "$DOMAIN" \
  --non-interactive

echo "[4/5] Creating Xray configuration..."

mkdir -p $XRAY_DIR

cat > $XRAY_DIR/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$DOMAIN",
          "certificates": [
            {
              "certificateFile": "$CERT_DIR/fullchain.pem",
              "keyFile": "$CERT_DIR/privkey.pem"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/$PATH_NAME"
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
EOF

echo "[5/5] Restarting Xray..."

systemctl restart xray || true
systemctl enable xray || true

echo ""
echo "======================================"
echo "UUID: $UUID"
echo "DOMAIN: $DOMAIN"
echo "PATH: /$PATH_NAME"
echo "======================================"
