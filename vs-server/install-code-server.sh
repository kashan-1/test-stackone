#!/bin/bash

set -e

PORT=8081
USER_NAME=$(whoami)
NGINX_FILE="/etc/nginx/sites-enabled/code.local"

echo "🚀 Installing code-server..."

# Install code-server
curl -fsSL https://code-server.dev/install.sh | sh

echo "==> Creating config directory..."
mkdir -p ~/.config/code-server

echo "==> Writing configuration..."
cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:$PORT
auth: password
cert: false
EOF

echo "==> Generating random password..."
PASSWORD=$(openssl rand -base64 12)
echo "password: $PASSWORD" >> ~/.config/code-server/config.yaml

echo "==> Enabling service..."
sudo systemctl enable code-server@$USER_NAME
sudo systemctl restart code-server@$USER_NAME

echo "==> Configuring NGINX..."

# Ensure nginx is installed
if ! command -v nginx >/dev/null 2>&1; then
    echo "ERROR: NGINX is not installed. Please install nginx first."
    exit 1
fi

# Remove existing file content
sudo rm -f $NGINX_FILE

# Create new nginx config
sudo tee $NGINX_FILE > /dev/null <<'EOF'
server {
    listen 80;
    server_name code.local;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name code.local;

    ssl_certificate /etc/ssl/stackone/stackone.crt;
    ssl_certificate_key /etc/ssl/stackone/stackone.key;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        proxy_buffering off;
    }
}
EOF

echo "==> Testing nginx configuration..."
sudo nginx -t

echo "==> Reloading nginx..."
sudo systemctl reload nginx

echo "==> Configuring firewall..."

if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 80
    sudo ufw allow 443
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    sudo firewall-cmd --add-service=http --permanent
    sudo firewall-cmd --add-service=https --permanent
    sudo firewall-cmd --reload
fi

echo "Done ✔"
echo ""
echo "Access VS Code in browser:"
echo "https://code.local"
echo ""
echo "Password:"
echo "$PASSWORD"