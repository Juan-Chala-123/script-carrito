#!/bin/bash

set -e

echo "======================================"
echo " Instalando Docker"
echo "======================================"

sudo apt-get remove -y \
    docker.io \
    docker-doc \
    docker-compose \
    podman-docker \
    containerd \
    runc || true

sudo apt-get update

sudo apt-get install -y ca-certificates curl git

sudo install -m 0755 -d /etc/apt/keyrings

sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo ""
echo "Docker instalado:"
sudo docker --version

echo ""
echo "Docker Compose instalado:"
sudo docker compose version

echo ""
echo "======================================"
echo " Configurando permisos"
echo "======================================"

# Usuario que ejecutó sudo, no necesariamente root
DOCKER_USER="${SUDO_USER:-$USER}"

sudo usermod -aG docker "$DOCKER_USER"

echo ""
echo "======================================"
echo " Clonando repositorio"
echo "======================================"

cd "$HOME"

if [ -d "carrito" ]; then
    echo "El directorio carrito ya existe."
    cd carrito
else
    git clone https://github.com/tadeo77789/carrito.git
    cd carrito
fi

echo "Repositorio listo."

echo ""
echo "======================================"
echo " Ejecutando Docker Compose"
echo "======================================"

sudo docker compose up --build
