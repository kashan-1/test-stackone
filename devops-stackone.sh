#!/bin/bash

set -e

# ---------------- Load ENV ----------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/env/stackone.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ENV file missing: $ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# ---------------- Variables ----------------
USER_NAME=$(whoami)
HOSTS_FILE="/etc/hosts"
HOSTS_BACKUP="${HOSTS_FILE}.bak_devops_stackone"
NGINX_BACKUP_DIR="/etc/nginx/sites-available/bak_devops_stackone"

# SSL variables
SSL_DIR="/etc/ssl/stackone"
CERT_NAME="stackone"

# ---------------- Docker Helper ----------------
docker_compose_run() {
    if docker info >/dev/null 2>&1; then
        docker compose "$@"
    else
        sudo docker compose "$@"
    fi
}

# ---------------- Rollback ----------------
rollback() {
    echo "⚠ Rolling back StackOne..."

    read -p "⚠ Full cleanup (remove docker/nginx)? [y/N]: " full_cleanup
    full_cleanup=${full_cleanup:-N}

    if [ -f "$SCRIPT_DIR/$DOCKER_COMPOSE_FILE" ]; then
        docker_compose_run -f "$SCRIPT_DIR/$DOCKER_COMPOSE_FILE" down --volumes --remove-orphans || true
    fi

    if [ -f "$HOSTS_BACKUP" ]; then
        sudo cp "$HOSTS_BACKUP" "$HOSTS_FILE"
    fi

    sudo rm -rf /etc/nginx/sites-enabled/* || true
    sudo rm -rf /etc/nginx/sites-available/* || true

    if [[ "$full_cleanup" =~ [Yy] ]]; then
        sudo apt purge -y nginx docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
        sudo rm -rf /var/lib/docker || true
    fi

    sudo rm -rf "$SSL_DIR" || true

    echo "Rollback complete"
}

# ---------------- SSL ----------------
generate_ssl_cert() {
    sudo mkdir -p "$SSL_DIR"

    # 1 Create local CA if not exists
    if [ ! -f "$SSL_DIR/localCA.key" ]; then
        echo "Creating local CA..."
        sudo openssl genrsa -out "$SSL_DIR/localCA.key" 4096
        sudo openssl req -x509 -new -nodes -key "$SSL_DIR/localCA.key" \
            -sha256 -days 825 -out "$SSL_DIR/localCA.crt" \
            -subj "/C=US/ST=Local/L=Local/O=StackOne CA/CN=StackOne Local CA"
    fi

    # 2 Create certificate for hosts
    cat > "$SSL_DIR/$CERT_NAME.cnf" <<EOF
    [req]
    default_bits = 2048
    prompt = no
    default_md = sha256
    distinguished_name = dn

    [dn]
    C=US
    ST=Local
    L=Local
    O=StackOne
    CN=*.local

    [ext]
    subjectAltName = $(for host in $HOSTS_ENTRIES; do echo -n "DNS:$host,"; done)DNS:localhost
EOF

    sudo openssl genrsa -out "$SSL_DIR/$CERT_NAME.key" 2048

    sudo openssl req -new -key "$SSL_DIR/$CERT_NAME.key" \
        -out "$SSL_DIR/$CERT_NAME.csr" -config "$SSL_DIR/$CERT_NAME.cnf"

    sudo openssl x509 -req -in "$SSL_DIR/$CERT_NAME.csr" -CA "$SSL_DIR/localCA.crt" \
        -CAkey "$SSL_DIR/localCA.key" -CAcreateserial -out "$SSL_DIR/$CERT_NAME.crt" \
        -days 825 -sha256 -extfile "$SSL_DIR/$CERT_NAME.cnf" -extensions ext

    echo "SSL cert generated: $SSL_DIR/$CERT_NAME.crt (signed by local CA)"
    echo "To fix browser 'Not Secure' on Windows, import $SSL_DIR/localCA.crt into Trusted Root Certificates"
}

# ---------------- NGINX ----------------
install_nginx_safe() {

    sudo apt update
    sudo apt install -y nginx
    sudo mkdir -p "$NGINX_BACKUP_DIR"

    generate_ssl_cert

    for host in $HOSTS_ENTRIES; do

        ROOT_DIR="/var/www/${host%%.*}"
        sudo mkdir -p "$ROOT_DIR"
        sudo chown -R www-data:www-data "$ROOT_DIR"

        if [ -f "$SCRIPT_DIR/$INDEX_FILE" ]; then
            sudo cp "$SCRIPT_DIR/$INDEX_FILE" "$ROOT_DIR/index.html"
        fi

        CONFIG_FILE="/etc/nginx/sites-available/$host"

        # -------- routing mode --------
        MODE="static"
        UPSTREAM=""

        case "$host" in
            tools.local)
                MODE="static"
                ;;
            jenkins.local)
                MODE="proxy"
                UPSTREAM="http://127.0.0.1:8080"
                ;;
            grafana.local)
                MODE="proxy"
                UPSTREAM="http://127.0.0.1:3000"
                ;;
            prometheus.local)
                MODE="proxy"
                UPSTREAM="http://127.0.0.1:9090"
                ;;
            node-exporter.local)
                MODE="proxy"
                UPSTREAM="http://127.0.0.1:9100"
                ;;
        esac

        # -------- nginx config --------
        if [ "$MODE" = "static" ]; then

sudo tee "$CONFIG_FILE" > /dev/null <<EOF
server {
    listen 80;
    server_name $host;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $host;

    root $ROOT_DIR;
    index index.html;

    ssl_certificate $SSL_DIR/$CERT_NAME.crt;
    ssl_certificate_key $SSL_DIR/$CERT_NAME.key;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

        else

sudo tee "$CONFIG_FILE" > /dev/null <<EOF
server {
    listen 80;
    server_name $host;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $host;

    ssl_certificate $SSL_DIR/$CERT_NAME.crt;
    ssl_certificate_key $SSL_DIR/$CERT_NAME.key;

    location / {
        proxy_pass $UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

        fi

        sudo ln -sf "$CONFIG_FILE" "/etc/nginx/sites-enabled/$host"
        sudo cp "$CONFIG_FILE" "$NGINX_BACKUP_DIR/"
    done
    echo "==> Setting up VS Code Server..."
    bash vs-server/install-code-server.sh
    sudo nginx -t
    sudo systemctl enable nginx
    sudo systemctl restart nginx

}


# ---------------- Docker ----------------
install_docker_safe() {

    sudo apt install -y ca-certificates curl gnupg

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg || true

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    sudo usermod -aG docker "$USER_NAME"
}

# ---------------- Hosts ----------------
update_hosts_safe() {
    for host in $HOSTS_ENTRIES; do
        if ! grep -q "$host" "$HOSTS_FILE"; then
            echo "127.0.0.1 $host" | sudo tee -a "$HOSTS_FILE" >/dev/null
        fi
    done
}

# ---------------- Install ----------------
install_stack() {

    echo "🚀 Installing StackOne..."

    [ ! -f "$HOSTS_BACKUP" ] && sudo cp "$HOSTS_FILE" "$HOSTS_BACKUP"

    sudo apt update
    sudo apt upgrade -y

    install_nginx_safe
    install_docker_safe
    update_hosts_safe

    if [ -f "$SCRIPT_DIR/$DOCKER_COMPOSE_FILE" ]; then
        docker_compose_run -f "$SCRIPT_DIR/$DOCKER_COMPOSE_FILE" up -d
    else
        echo "⚠ docker-compose.yml missing"
    fi

    echo "*** Installation complete ✔ ***"
    echo "Please re-login for docker group access."
}

# ---------------- Menu ----------------
while true; do
    echo ""
    echo "===== DevOps StackOne ====="
    echo "1) Install"
    echo "2) Rollback"
    echo "3) Exit"
    echo "==========================="

    read -p "Choice: " choice

    case $choice in
        1) install_stack ;;
        2) rollback ;;
        3) exit 0 ;;
        *) echo "Invalid" ;;
    esac
done