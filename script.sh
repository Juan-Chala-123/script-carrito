#!/usr/bin/env bash
#
# Instala Docker + Docker Compose y despliega el proyecto "carrito".
# Probado en Ubuntu/Debian (usa apt-get y el repositorio oficial de Docker).
#
# Uso:  ./script.sh          (como usuario normal con permisos de sudo)
#       ./script.sh -d       (levanta los contenedores en segundo plano)

set -Eeuo pipefail

REPO_URL="https://github.com/tadeo77789/carrito.git"
REPO_DIR="carrito"
COMPOSE_ARGS=(up --build)

if [ "${1:-}" = "-d" ] || [ "${1:-}" = "--detach" ]; then
    COMPOSE_ARGS+=(-d)
fi

titulo() {
    echo ""
    echo "======================================"
    echo " $1"
    echo "======================================"
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}

trap 'error "el script falló en la línea $LINENO"' ERR

# --- Comprobaciones previas -------------------------------------------------

[ "$(id -u)" -ne 0 ] || error "no ejecutes este script con sudo; hazlo como tu usuario normal."

command -v apt-get >/dev/null 2>&1 || error "este script requiere apt-get (Ubuntu/Debian)."
command -v sudo    >/dev/null 2>&1 || error "sudo no está instalado."

# Pide la contraseña una sola vez, al principio.
sudo -v

# --- Instalación de Docker --------------------------------------------------

if command -v docker >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1; then
    titulo "Docker ya está instalado, se omite la instalación"
else
    titulo "Instalando Docker"

    # Paquetes antiguos que entran en conflicto con docker-ce.
    sudo apt-get remove -y \
        docker.io \
        docker-doc \
        docker-compose \
        docker-compose-v2 \
        podman-docker \
        containerd \
        runc || true

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl git

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    [ -n "$codename" ] || error "no se pudo determinar el codename de la distribución."

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

echo ""
echo "Docker:         $(sudo docker --version)"
echo "Docker Compose: $(sudo docker compose version)"

# --- Permisos ---------------------------------------------------------------

titulo "Configurando permisos"

# El usuario que invocó sudo, no root.
DOCKER_USER="${SUDO_USER:-$USER}"

if id -nG "$DOCKER_USER" | tr ' ' '\n' | grep -qx docker; then
    echo "El usuario $DOCKER_USER ya pertenece al grupo docker."
else
    sudo usermod -aG docker "$DOCKER_USER"
    echo "Usuario $DOCKER_USER añadido al grupo docker."
    echo "NOTA: cierra sesión y vuelve a entrar para usar docker sin sudo."
fi

# --- Repositorio ------------------------------------------------------------

titulo "Clonando repositorio"

cd "$HOME"

if [ -d "$REPO_DIR/.git" ]; then
    echo "El repositorio ya existe, actualizando..."
    cd "$REPO_DIR"
    git pull --ff-only || echo "AVISO: no se pudo actualizar; se usa la copia local."
elif [ -e "$REPO_DIR" ]; then
    error "$HOME/$REPO_DIR existe pero no es un repositorio git. Muévelo o bórralo."
else
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi

echo "Repositorio listo en: $(pwd)"

# --- Despliegue -------------------------------------------------------------

titulo "Ejecutando Docker Compose"

if ! ls compose.yaml compose.yml docker-compose.yaml docker-compose.yml >/dev/null 2>&1; then
    error "no se encontró un archivo compose en $(pwd)."
fi

sudo docker compose "${COMPOSE_ARGS[@]}"
