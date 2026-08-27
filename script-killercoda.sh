#!/bin/bash
# deploy-plugin.sh

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Despliegue automático (ROOT)${NC}"
echo -e "${GREEN}======================================${NC}"

REPO_URL="https://github.com/tadeo77789/carrito.git"
PROJECT_DIR="/root/carrito"

# Instalar Docker si no existe
if ! command -v docker &> /dev/null; then
    echo "📦 Instalando Docker..."
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl start docker
fi

# Clonar repositorio
cd /root
if [ -d "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"
    git pull --ff-only || true
else
    git clone --depth 1 "$REPO_URL"
    cd "$PROJECT_DIR"
fi

# Desplegar con docker compose (plugin)
echo "🚀 Desplegando..."
docker compose down 2>/dev/null || true
docker compose up -d --build

echo -e "${GREEN}✅ ¡Despliegue exitoso!${NC}"
docker compose ps
