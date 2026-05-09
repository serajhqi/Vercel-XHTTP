#!/usr/bin/env bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

read -p "Enter domain (example: xray.example.com): " DOMAIN
read -p "Enter email: " EMAIL
read -p "Enter port (example: 2096): " PORT
read -p "Enter path (example: mypath): " PATH_NAME

# remove leading/trailing slashes
PATH_NAME=$(echo "$PATH_NAME" | sed 's#^/*##; s#/*$##')
PORT=${PORT:-2096}

echo "[1/10] Updating system..."

apt update && apt upgrade -y

echo "[2/10] Installing packages..."

apt install -y curl socat cron ufw

echo "[3/10] Installing Xray..."

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "[4/10] Checking Xray version..."

xray version

UUID=$(xray uuid)

echo ""
echo "Generated UUID:"
echo "$UUID"
echo ""

echo "[5/10] Enabling Xray service..."

systemctl enable xray

echo "[6/10] Configuring firewall..."

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow ${PORT}/tcp

ufw --force enable

echo "[7/10] Installing acme.sh..."

curl https://get.acme.sh | sh -s email="$EMAIL"

export PATH="$HOME/.acme.sh:$PATH"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "[8/10] Stopping services using port 80..."

systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true

systemctl stop nginx 2>/dev/null || true

echo "[9/10] Issuing TLS certificate..."

~/.acme.sh/acme.sh --issue \
  -d "$DOMAIN" \
  --standalone \
  -k ec-256

mkdir -p /etc/xray

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file /etc/xray/cert.pem \
  --key-file /etc/xray/key.pem \
  --reloadcmd "systemctl restart xray"

chown -R nobody:nogroup /etc/xray

chmod 644 /etc/xray/cert.pem
chmod 640 /etc/xray/key.pem

echo "[10/10] Creating Xray configuration..."

mkdir -p /var/log/xray

touch /var/log/xray/access.log
touch /var/log/xray/error.log

chown -R nobody:nogroup /var/log/xray

cp /usr/local/etc/xray/config.json \
   /usr/local/etc/xray/config.json.bak 2>/dev/null || true

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "xhttp-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "/etc/xray/cert.pem",
              "keyFile": "/etc/xray/key.pem"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/$PATH_NAME",
          "host": "$DOMAIN",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

echo ""
echo "Testing Xray configuration..."
echo ""

xray -test -config /usr/local/etc/xray/config.json

echo ""
echo "Restarting Xray..."
echo ""

systemctl restart xray

echo ""
echo "Waiting for Xray port..."
echo ""

until ss -tln | grep -q ":$PORT "; do
  sleep 1
done

echo ""
echo "Checking listening port..."
echo ""

ss -tlnp | grep "$PORT" || true

echo ""
echo "Local connectivity test..."
echo ""

curl -vk "https://127.0.0.1:$PORT/$PATH_NAME" || true

echo ""
echo "======================================"
echo "DOMAIN : $DOMAIN"
echo "PORT   : $PORT"
echo "UUID   : $UUID"
echo "PATH   : /$PATH_NAME"
echo ""
echo "VLESS URL:"
echo ""
echo "vless://$UUID@$DOMAIN:$PORT?security=tls&type=xhttp&path=%2F$PATH_NAME&host=$DOMAIN&sni=$DOMAIN#$DOMAIN"
echo "======================================"
