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

# 3. Install Tailscale and join tailnet
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    log "Installing Tailscale..."
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    log "Joining tailnet..."
    HOSTNAME_ARG=""
    [ -n "$TAILSCALE_HOSTNAME" ] && HOSTNAME_ARG="--hostname=${TAILSCALE_HOSTNAME}"

    sudo tailscale up \
        --authkey="${TAILSCALE_AUTH_KEY}" \
        --ssh \
        --accept-routes \
        ${HOSTNAME_ARG}

    log "Verifying Tailscale..."
    sleep 5
    if tailscale status --peers=false | grep -q "^100\."; then
        TAILSCALE_IP=$(tailscale ip -4)
        log "Tailscale active at ${TAILSCALE_IP}. Restricting SSH to Tailscale interface..."
        echo "ListenAddress ${TAILSCALE_IP}" | sudo tee /etc/ssh/sshd_config.d/00-tailscale-only.conf > /dev/null
        if sudo sshd -t; then
            sudo systemctl restart ssh
        else
            err "SSH config test failed! Reverting."
            sudo rm /etc/ssh/sshd_config.d/00-tailscale-only.conf && exit 1
        fi
    else
        err "Tailscale failed to start. Aborting SSH restriction." && exit 1
    fi
else
    log "No Tailscale auth key provided (TAILSCALE_AUTH_KEY unset). Skipping Tailscale setup."
fi

# 4. Finalize Firewall (UFW)
log "Configuring UFW..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
# Allow SSH over Tailscale (port 22 on the Tailscale interface is handled by
# sshd's ListenAddress above; UFW still needs to permit the port itself).
sudo ufw allow in on tailscale0 to any port 22
sudo ufw --force enable

echo "========================================="
echo "          Bootstrap Complete!            "
echo "========================================="
