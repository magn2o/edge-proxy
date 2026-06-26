#!/usr/bin/env bash

set -e

echo "========================================="
echo "   Initializing Edge Proxy Bootstrap     "
echo "========================================="

echo "--> Updating package repositories..."
sudo apt-get update -y && sudo apt-get upgrade -y

if ! command -v docker &> /dev/null; then
    echo "--> Installing Docker and dependencies..."
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "--> Docker is already installed. Skipping..."
fi

echo "--> Setting up /opt/edge-proxy directories..."
sudo mkdir -p /opt/edge-proxy/conf.d
sudo mkdir -p /opt/edge-proxy/certbot/conf
sudo mkdir -p /opt/edge-proxy/certbot/www

DEPLOY_USER=$(whoami)
echo "--> Granting permissions for directory to user: $DEPLOY_USER"
sudo chown -R "$DEPLOY_USER":"$DEPLOY_USER" /opt/edge-proxy

if ! groups "$DEPLOY_USER" | grep &>/dev/null '\bdocker\b'; then
    echo "--> Adding $DEPLOY_USER to the docker group..."
    sudo usermod -aG docker "$DEPLOY_USER"
    echo "NOTE: You may need to log out and log back into your SSH terminal session for group changes to apply."
fi

echo "========================================="
echo "           Bootstrap Complete!           "
echo "========================================="