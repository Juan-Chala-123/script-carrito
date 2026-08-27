#!/bin/bash
# deploy-final.sh

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Despliegue automático FINAL${NC}"
echo -e "${GREEN}======================================${NC}"

REPO_URL="https://github.com/tadeo77789/carrito.git"
PROJECT_DIR="/root/carrito"

# =============================================
# 1. Instalar DOCKER (el correcto)
# =============================================
echo -e "\n${YELLOW}[1/3] Instalando Docker...${NC}"

if ! command -v docker &> /dev/null; then
    echo "Instalando Docker..."
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Repositorio oficial
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
    
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl start docker
    systemctl enable docker
else
    echo -e "${GREEN}Docker OK: $(docker --version)${NC}"
fi

# =============================================
# 2. VERIFICAR docker compose (plugin)
# =============================================
echo -e "\n${YELLOW}[2/3] Verificando docker compose (plugin)...${NC}"

# Forzar instalación del plugin correcto
echo "Instalando plugin docker compose..."
apt-get install -y docker-compose-plugin 2>/dev/null || true

# Verificar que funciona
if docker compose version &> /dev/null; then
    echo -e "${GREEN}✅ docker compose plugin OK: $(docker compose version)${NC}"
else
    echo "❌ Falló el plugin, instalando binario alternativo..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    # Crear alias para que docker compose funcione
    ln -sf /usr/local/bin/docker-compose /usr/local/bin/docker-compose-plugin
    echo -e "${GREEN}✅ docker-compose binario instalado${NC}"
fi

# =============================================
# 3. CLONAR Y DESPLEGAR
# =============================================
echo -e "\n${YELLOW}[3/3] Desplegando...${NC}"

cd /root
if [ -d "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"
    git pull --ff-only || true
else
    git clone --depth 1 "$REPO_URL"
    cd "$PROJECT_DIR"
fi

# VER IMPORTANTE: Ver qué compose usar
if command -v docker-compose &> /dev/null; then
    echo "Usando docker-compose (binario)"
    docker-compose down 2>/dev/null || true
    docker-compose up --build -d
elif docker compose version &> /dev/null; then
    echo "Usando docker compose (plugin)"
    docker compose down 2>/dev/null || true
    docker compose up -d --build
else
    echo -e "${RED}❌ No hay Docker Compose disponible${NC}"
    exit 1
fi

echo -e "\n${GREEN}======================================${NC}"
echo -e "${GREEN}✅ ¡DESPLIEGUE EXITOSO!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "Contenedores en ejecución:"
docker ps
