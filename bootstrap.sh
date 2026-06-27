#!/usr/bin/env bash

set -euo pipefail

log() { echo "--> $*"; }
err() { echo "⚠️  $*" >&2; }

echo "========================================="
echo "   Initializing Edge Proxy Bootstrap     "
echo "========================================="

log "Updating package repositories..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y

if [ "${SKIP_UPGRADE:-0}" != "1" ]; then
    log "Upgrading installed packages (set SKIP_UPGRADE=1 to skip)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi

# 1. Install Docker
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# 2. Setup directories and permissions
log "Setting up /opt/edge-proxy..."
sudo mkdir -p /opt/edge-proxy/{conf.d,certbot/conf,certbot/www}
DEPLOY_USER=$(whoami)
sudo chown -R "$DEPLOY_USER":"$DEPLOY_USER" /opt/edge-proxy
if ! groups "$DEPLOY_USER" | grep -q '\bdocker\b'; then
    sudo usermod -aG docker "$DEPLOY_USER"
fi

# 3. Setup Cloudflare Tunnel and SSH hardening
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    log "Installing and configuring Cloudflare Tunnel..."

    if ! command -v cloudflared &> /dev/null; then
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
    fi

    if ! systemctl is-enabled --quiet cloudflared 2>/dev/null; then
        sudo cloudflared service install "$CF_TUNNEL_TOKEN"
    fi
    sudo systemctl start cloudflared

    log "Verifying tunnel..."
    sleep 10
    if systemctl is-active --quiet cloudflared; then
        log "Tunnel healthy. Restricting SSH to localhost..."
        echo "ListenAddress 127.0.0.1" | sudo tee /etc/ssh/sshd_config.d/00-tunnel-only.conf > /dev/null
        if sudo sshd -t; then
            sudo systemctl restart ssh
        else
            err "SSH config test failed! Reverting."
            sudo rm /etc/ssh/sshd_config.d/00-tunnel-only.conf && exit 1
        fi
    else
        err "Cloudflared failed to start. Aborting SSH restriction." && exit 1
    fi
else
    log "No Cloudflare tunnel token provided (CF_TUNNEL_TOKEN unset). Skipping tunnel setup."
fi

# 4. Finalize Firewall (UFW)
log "Configuring UFW..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "========================================="
echo "          Bootstrap Complete!            "
echo "========================================="