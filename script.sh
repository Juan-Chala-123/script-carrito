#!/usr/bin/env bash
#
# Instala Docker + Docker Compose y despliega el proyecto "carrito".
# Probado en Ubuntu/Debian (usa apt-get y el repositorio oficial de Docker).
#
# Funciona tanto como root (root directo, contenedor, VPS) como con un
# usuario normal que tenga permisos de sudo.
#
# Uso:  ./script.sh          despliega en primer plano (logs en pantalla)
#       ./script.sh -d       despliega en segundo plano

set -Eeuo pipefail

REPO_URL="https://github.com/tadeo77789/carrito.git"
REPO_DIR="carrito"
COMPOSE_ARGS=(up --build)

export DEBIAN_FRONTEND=noninteractive

case "${1:-}" in
    -d|--detach) COMPOSE_ARGS+=(-d) ;;
    "")          ;;
    *)           echo "Uso: $0 [-d|--detach]" >&2; exit 1 ;;
esac

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

# --- Privilegios ------------------------------------------------------------
# Si ya somos root no hace falta sudo (y a menudo ni siquiera está instalado).

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    echo "Ejecutando como root."
else
    command -v sudo >/dev/null 2>&1 \
        || error "no eres root y sudo no está instalado."
    SUDO="sudo"
    sudo -v   # pide la contraseña una sola vez, al principio
fi

command -v apt-get >/dev/null 2>&1 \
    || error "este script requiere apt-get (Ubuntu/Debian)."

# --- Usuario y directorio de destino ----------------------------------------
# Si se invocó con sudo, el destino es el usuario real, no root.

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

# Ejecuta un comando como TARGET_USER (o directo, si ya somos ese usuario).
run_as_target() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        "$@"
    else
        runuser -u "$TARGET_USER" -- "$@"
    fi
}

# --- Instalación de Docker --------------------------------------------------

if command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1; then
    titulo "Docker ya está instalado, se omite la instalación"
else
    titulo "Instalando Docker"

    # Paquetes antiguos que entran en conflicto con docker-ce.
    $SUDO apt-get remove -y \
        docker.io \
        docker-doc \
        docker-compose \
        docker-compose-v2 \
        podman-docker \
        containerd \
        runc || true

    $SUDO apt-get update
    $SUDO apt-get install -y ca-certificates curl git

    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    [ -n "$codename" ] || error "no se pudo determinar el codename de la distribución."

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    $SUDO apt-get update
    $SUDO apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

echo ""
echo "Docker:         $($SUDO docker --version)"
echo "Docker Compose: $($SUDO docker compose version)"

# --- Permisos ---------------------------------------------------------------

titulo "Configurando permisos"

if [ "$TARGET_USER" = "root" ]; then
    echo "El usuario es root: ya tiene acceso al socket de Docker."
elif id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    echo "El usuario $TARGET_USER ya pertenece al grupo docker."
else
    $SUDO usermod -aG docker "$TARGET_USER"
    echo "Usuario $TARGET_USER añadido al grupo docker."
    echo "NOTA: cierra sesión y vuelve a entrar para usar docker sin sudo."
fi

# --- Repositorio ------------------------------------------------------------

titulo "Clonando repositorio"

command -v git >/dev/null 2>&1 || $SUDO apt-get install -y git

PROJECT_DIR="$TARGET_HOME/$REPO_DIR"

if [ -d "$PROJECT_DIR/.git" ]; then
    echo "El repositorio ya existe, actualizando..."
    run_as_target git -C "$PROJECT_DIR" pull --ff-only \
        || echo "AVISO: no se pudo actualizar; se usa la copia local."
elif [ -e "$PROJECT_DIR" ]; then
    error "$PROJECT_DIR existe pero no es un repositorio git. Muévelo o bórralo."
else
    run_as_target git clone "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"
echo "Repositorio listo en: $PROJECT_DIR"

# --- Despliegue -------------------------------------------------------------

titulo "Ejecutando Docker Compose"

compose_file=""
for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$f" ]; then
        compose_file="$f"
        break
    fi
done

[ -n "$compose_file" ] || error "no se encontró un archivo compose en $PROJECT_DIR."
echo "Usando: $compose_file"

$SUDO docker compose "${COMPOSE_ARGS[@]}"
