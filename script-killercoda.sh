#!/bin/bash

# =============================================
# Script simple de despliegue (versión ROOT)
# =============================================

set -e

# Colores para mejor visualización
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Despliegue automático (ROOT)${NC}"
echo -e "${GREEN}======================================${NC}"

# Variables
REPO_URL="https://github.com/tadeo77789/carrito.git"
PROJECT_DIR="/root/carrito"  # Directorio para root

# =============================================
# 1. Instalar Docker si no está presente
# =============================================
echo -e "\n${YELLOW}[1/4] Verificando Docker...${NC}"

if ! command -v docker &> /dev/null; then
    echo "Docker no está instalado. Instalando..."
    
    # Desinstalar versiones antiguas
    apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
    
    # Instalar dependencias
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Añadir repositorio Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Instalar Docker
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Iniciar Docker
    systemctl start docker
    systemctl enable docker
    
    echo -e "${GREEN}Docker instalado: $(docker --version)${NC}"
else
    echo -e "${GREEN}Docker ya está instalado: $(docker --version)${NC}"
fi

# =============================================
# 2. Verificar Docker Compose
# =============================================
echo -e "\n${YELLOW}[2/4] Verificando Docker Compose...${NC}"

if ! docker compose version &> /dev/null; then
    echo "Docker Compose no está disponible. Instalando..."
    
    # Descargar Docker Compose directamente
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    echo -e "${GREEN}Docker Compose instalado: $(docker-compose --version)${NC}"
else
    echo -e "${GREEN}Docker Compose disponible: $(docker compose version)${NC}"
fi

# =============================================
# 3. Clonar repositorio
# =============================================
echo -e "\n${YELLOW}[3/4] Preparando repositorio...${NC}"

cd /root

if [ -d "$PROJECT_DIR" ]; then
    echo "El directorio $PROJECT_DIR ya existe."
    echo "  - Usando repositorio existente"
    cd "$PROJECT_DIR"
    git pull --ff-only || echo "No se pudo actualizar, usando versión local"
else
    echo "Clonando repositorio desde $REPO_URL..."
    git clone --depth 1 "$REPO_URL"
    cd "$PROJECT_DIR"
fi

echo -e "${GREEN}Repositorio listo en: $PROJECT_DIR${NC}"

# =============================================
# 4. Ejecutar Docker Compose
# =============================================
echo -e "\n${YELLOW}[4/4] Desplegando con Docker Compose...${NC}"

# Verificar que existe docker-compose.yml
if [ ! -f "docker-compose.yml" ] && [ ! -f "compose.yml" ]; then
    echo -e "${RED}Error: No se encontró docker-compose.yml en el repositorio${NC}"
    exit 1
fi

# Detener contenedores anteriores (si existen)
docker compose down 2>/dev/null || true

# Construir y levantar
echo "Construyendo y levantando contenedores..."
if docker compose up --build -d; then
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}✅ ¡Despliegue exitoso!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo "Contenedores en ejecución:"
    docker compose ps
    echo ""
    echo "Para ver logs: docker compose logs -f"
    echo "Para detener: docker compose down"
else
    echo -e "\n${RED}❌ Error al levantar los contenedores${NC}"
    echo "Ver logs con: docker compose logs"
    exit 1
fi
