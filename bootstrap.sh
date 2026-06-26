#!/usr/bin/env bash

set -e

echo "========================================="
echo "   Initializing Edge Proxy Bootstrap     "
echo "========================================="

echo "--> Updating package repositories..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# 1. Install Docker
if ! command -v docker &> /dev/null; then
    echo "--> Installing Docker..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# 2. Setup directories and permissions
echo "--> Setting up /opt/edge-proxy..."
sudo mkdir -p /opt/edge-proxy/{conf.d,certbot/conf,certbot/www}
DEPLOY_USER=$(whoami)
sudo chown -R "$DEPLOY_USER":"$DEPLOY_USER" /opt/edge-proxy
if ! groups "$DEPLOY_USER" | grep &>/dev/null '\bdocker\b'; then
    sudo usermod -aG docker "$DEPLOY_USER"
fi


# Add cloudflare gpg key
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

# Add this repo to your apt repositories
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

# install cloudflared
sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install cloudflared

# 3. Setup Cloudflare Tunnel and SSH hardening
CF_TOKEN="$1"
if [ -n "$CF_TOKEN" ]; then
    echo "--> Installing and configuring Cloudflare Tunnel..."
    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
    sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install cloudflared
    
    sudo cloudflared service install "$CF_TOKEN"
    sudo systemctl start cloudflared
    
    echo "--> Verifying tunnel..."
    sleep 10
    if systemctl is-active --quiet cloudflared; then
        echo "--> Tunnel healthy. Restricting SSH to localhost..."
        echo "ListenAddress 127.0.0.1" | sudo tee /etc/ssh/sshd_config.d/00-tunnel-only.conf > /dev/null
        if sudo sshd -t; then
            sudo systemctl restart ssh
        else
            echo "⚠️ SSH config test failed! Reverting."
            sudo rm /etc/ssh/sshd_config.d/00-tunnel-only.conf && exit 1
        fi
    else
        echo "⚠️ Cloudflared failed to start. Aborting SSH restriction." && exit 1
    fi
else
    echo "--> No Cloudflare token provided. Skipping tunnel setup."
fi

# 4. Finalize Firewall (UFW)
echo "--> Configuring UFW..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "========================================="
echo "          Bootstrap Complete!            "
echo "========================================="