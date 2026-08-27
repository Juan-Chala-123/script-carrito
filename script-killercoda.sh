#!/usr/bin/env bash
#
# ESCENARIO 2 - Killercoda
# Despliegue automatizado de un servicio mediante Docker y Nginx.
#
#   Cliente -> Nginx (proxy inverso) -> Docker -> Servicio
#
# El script es parametrizable: todos los datos del despliegue se solicitan
# durante la ejecucion, por lo que sirve para cualquier servicio que tenga
# un Dockerfile. No hay rutas, puertos, nombres ni credenciales escritos
# en este archivo.
#
# Entorno objetivo: Killercoda / Ubuntu / Debian. Funciona como root o con sudo.
#
# Para el despliegue con publicacion externa mediante ngrok, usar
# script-ngrok.sh
#
# Uso:  ./script-killercoda.sh

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
#  Utilidades
# ============================================================================

titulo() {
    echo ""
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}

paso()  { echo "  -> $1"; }
ok()    { echo "  [OK] $1"; }
aviso() { echo "  [!] $1" >&2; }

error() {
    echo "" >&2
    echo "ERROR: $1" >&2
    exit 1
}

trap 'error "el script fallo en la linea $LINENO"' ERR

# Pregunta un dato. El prompt de `read -p` se escribe en stderr, por eso la
# respuesta se puede capturar con $(...) sin arrastrar el texto del prompt.
preguntar() {
    local prompt="$1" def="${2:-}" resp=""
    if [ -n "$def" ]; then
        read -rp "  $prompt [$def]: " resp || true
        echo "${resp:-$def}"
    else
        while true; do
            read -rp "  $prompt: " resp || true
            [ -n "$resp" ] && break
            aviso "este dato es obligatorio."
        done
        echo "$resp"
    fi
}

preguntar_puerto() {
    local prompt="$1" def="${2:-}" p=""
    while true; do
        p="$(preguntar "$prompt" "$def")"
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            echo "$p"
            return 0
        fi
        aviso "'$p' no es un puerto valido (1-65535)."
    done
}

puerto_ocupado() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN
    else
        return 1
    fi
}

# ---- apt --------------------------------------------------------------------
# DPkg::Lock::Timeout evita el cuelgue silencioso cuando unattended-upgrades
# tiene tomado el lock de dpkg al arrancar la maquina: sin el, apt espera
# indefinidamente y sin imprimir nada, que es lo que parece un script colgado.
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3)

# Killercoda y Ubuntu lanzan apt y unattended-upgrades al arrancar la maquina.
# Si se llama a apt mientras tanto, falla con "Could not get lock". En vez de
# abortar, se espera a que el otro proceso termine informando del progreso.
esperar_apt() {
    local espera=0 aviso_dado="no"

    command -v pgrep >/dev/null 2>&1 || return 0

    while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; do
        if [ "$aviso_dado" = "no" ]; then
            paso "Otro proceso de apt esta en ejecucion. Esperando a que termine..."
            paso "(es normal en una maquina recien arrancada)"
            aviso_dado="si"
        fi
        if [ "$espera" -ge 600 ]; then
            error "apt sigue bloqueado tras 10 minutos. Revisa con: ps aux | grep apt"
        fi
        sleep 5
        espera=$((espera + 5))
        if [ $((espera % 30)) -eq 0 ]; then
            echo "     ... $espera s"
        fi
    done

    if [ "$aviso_dado" = "si" ]; then
        ok "El otro proceso de apt termino, continuando."
    fi
}

apt_update()  { esperar_apt; $SUDO apt-get update -q "${APT_OPTS[@]}"; }
apt_install() { esperar_apt; $SUDO apt-get install -y -q --no-install-recommends "${APT_OPTS[@]}" "$@"; }

# ============================================================================
#  1. Validacion de dependencias
# ============================================================================

titulo "1. Validacion de dependencias"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    paso "Ejecutando como root."
else
    command -v sudo >/dev/null 2>&1 || error "no eres root y sudo no esta instalado."
    SUDO="sudo"
    paso "Ejecutando como $(id -un), se usara sudo."
    sudo -v
fi

command -v apt-get >/dev/null 2>&1 || error "este script requiere apt-get (Ubuntu/Debian)."

paso "Verificando utilidades base..."

# Solo se llama a apt si falta algo: en una maquina que ya las tiene, esto
# ahorra el `apt-get update` completo.
FALTANTES=()
for p in ca-certificates curl git iproute2; do
    dpkg -s "$p" >/dev/null 2>&1 || FALTANTES+=("$p")
done

if [ ${#FALTANTES[@]} -eq 0 ]; then
    ok "Utilidades base ya presentes."
else
    paso "Instalando: ${FALTANTES[*]}"
    apt_update
    apt_install "${FALTANTES[@]}"
    ok "Utilidades base instaladas."
fi

# ---- Docker ----------------------------------------------------------------
# Killercoda y muchas imagenes de Ubuntu ya traen Docker. Antes se comprobaba
# con `docker compose version`, heredado de una version anterior del script:
# como aqui no se usa Compose, esa condicion daba falso en maquinas que SI
# tenian Docker y disparaba una reinstalacion completa de varios minutos.

if command -v docker >/dev/null 2>&1; then
    ok "Docker ya esta instalado, se omite la instalacion."
else
    echo ""
    aviso "Docker no esta instalado. La descarga puede tardar varios minutos."
    aviso "Vera el progreso de apt; no interrumpa el proceso."
    echo ""

    # Solo se desinstala lo que realmente este puesto.
    CONFLICTOS=()
    for p in docker.io docker-doc docker-compose docker-compose-v2 \
             podman-docker containerd runc; do
        if dpkg -s "$p" >/dev/null 2>&1; then CONFLICTOS+=("$p"); fi
    done
    if [ ${#CONFLICTOS[@]} -gt 0 ]; then
        paso "Eliminando paquetes en conflicto: ${CONFLICTOS[*]}"
        esperar_apt
        $SUDO apt-get remove -y -q "${APT_OPTS[@]}" "${CONFLICTOS[@]}" || true
    fi

    paso "Anadiendo el repositorio oficial de Docker..."
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    [ -n "$codename" ] || error "no se pudo determinar el codename de la distribucion."

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Solo lo imprescindible: el script usa `docker build` y `docker run`,
    # no Docker Compose, asi que docker-compose-plugin no se instala.
    paso "Instalando Docker..."
    apt_update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin

    ok "Docker instalado."
fi

# El demonio debe estar corriendo (en Killercoda no siempre arranca solo).
if ! $SUDO docker info >/dev/null 2>&1; then
    paso "Iniciando el demonio de Docker..."
    $SUDO systemctl start docker >/dev/null 2>&1 \
        || $SUDO service docker start >/dev/null 2>&1 \
        || true
    $SUDO docker info >/dev/null 2>&1 || error "el demonio de Docker no esta disponible."
fi

echo "  Docker:  $($SUDO docker --version)"

# ============================================================================
#  2. Datos del servicio
# ============================================================================

titulo "2. Datos del servicio"

echo "  Responde los siguientes datos. Entre corchetes aparece el valor por"
echo "  defecto: pulsa Enter para aceptarlo."
echo ""

SERVICE_NAME="$(preguntar    'Nombre del servicio')"
REPO_URL="$(preguntar        'URL del repositorio git del servicio')"
BUILD_CONTEXT="$(preguntar   'Ruta del Dockerfile dentro del repo' '.')"
IMAGE_NAME="$(preguntar      'Nombre de la imagen Docker' "${SERVICE_NAME}:latest")"
CONTAINER_NAME="$(preguntar  'Nombre del contenedor' "${SERVICE_NAME}-app")"
APP_PORT="$(preguntar_puerto 'Puerto interno de la aplicacion' '8080')"
PROXY_PORT="$(preguntar_puerto 'Puerto del proxy inverso (Nginx)' '80')"

NETWORK_NAME="${SERVICE_NAME}-net"
NGINX_CONTAINER="${SERVICE_NAME}-nginx"

if puerto_ocupado "$PROXY_PORT"; then
    aviso "el puerto $PROXY_PORT ya esta en uso; el arranque de Nginx puede fallar."
fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

WORKDIR="$TARGET_HOME/despliegue-$SERVICE_NAME"
SRC_DIR="$WORKDIR/src"
ENV_FILE="$WORKDIR/.env"
NGINX_CONF="$WORKDIR/nginx.conf"

mkdir -p "$WORKDIR"

# ============================================================================
#  3. Variables de entorno del servicio
# ============================================================================

titulo "3. Variables de entorno del servicio"

echo "  Introduce las variables en formato CLAVE=VALOR, una por linea."
echo "  Ejemplos: DB_HOST=db        DB_PORT=5432    DB_NAME=carrito"
echo "            DB_USER=admin     DB_PASSWORD=secreto"
echo "            API_URL=http://api  SPRING_PROFILES_ACTIVE=prod"
echo "  Deja la linea vacia y pulsa Enter para terminar."
echo ""

# El archivo puede contener contrasenas: se crea con permisos restrictivos.
: > "$ENV_FILE"
chmod 600 "$ENV_FILE"

n_vars=0
while true; do
    read -rp "  VAR $((n_vars + 1)): " linea || true
    [ -z "$linea" ] && break
    if [[ "$linea" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
        echo "$linea" >> "$ENV_FILE"
        n_vars=$((n_vars + 1))
    else
        aviso "formato invalido, usa CLAVE=VALOR."
    fi
done

if [ "$n_vars" -eq 0 ]; then
    ok "Sin variables de entorno."
else
    ok "$n_vars variable(s) guardadas en $ENV_FILE (permisos 600)."
fi

# ============================================================================
#  4. Construccion de la imagen
# ============================================================================

titulo "4. Construccion de la imagen Docker"

if [ -d "$SRC_DIR/.git" ]; then
    paso "El codigo ya existe, actualizando..."
    git -C "$SRC_DIR" pull --ff-only || aviso "no se pudo actualizar; se usa la copia local."
else
    rm -rf "$SRC_DIR"
    paso "Clonando $REPO_URL ..."
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

CONTEXT_DIR="$SRC_DIR/$BUILD_CONTEXT"
[ -d "$CONTEXT_DIR" ] || error "la ruta '$BUILD_CONTEXT' no existe dentro del repositorio."
[ -f "$CONTEXT_DIR/Dockerfile" ] || error "no se encontro un Dockerfile en $CONTEXT_DIR."

paso "Construyendo la imagen $IMAGE_NAME ..."
$SUDO docker build -t "$IMAGE_NAME" "$CONTEXT_DIR"
ok "Imagen $IMAGE_NAME construida."

# ============================================================================
#  5. Red Docker
# ============================================================================

titulo "5. Red Docker"

if $SUDO docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    ok "La red $NETWORK_NAME ya existe."
else
    $SUDO docker network create "$NETWORK_NAME" >/dev/null
    ok "Red $NETWORK_NAME creada."
fi

# ============================================================================
#  6. Contenedor del servicio
# ============================================================================

titulo "6. Contenedor del servicio"

# Se elimina cualquier contenedor previo con el mismo nombre para que el
# script se pueda reejecutar las veces que haga falta.
$SUDO docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

run_args=(
    -d
    --name "$CONTAINER_NAME"
    --network "$NETWORK_NAME"
    --restart unless-stopped
    -p "${APP_PORT}:${APP_PORT}"
)
[ "$n_vars" -gt 0 ] && run_args+=(--env-file "$ENV_FILE")

paso "Iniciando el contenedor $CONTAINER_NAME ..."
$SUDO docker run "${run_args[@]}" "$IMAGE_NAME" >/dev/null
ok "Contenedor $CONTAINER_NAME en ejecucion."

# ============================================================================
#  7. Nginx como proxy inverso
# ============================================================================

titulo "7. Proxy inverso (Nginx)"

# Nginx resuelve el nombre del contenedor por DNS dentro de la red Docker.
cat > "$NGINX_CONF" <<NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://${CONTAINER_NAME}:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 30s;
        proxy_read_timeout    60s;
    }
}
NGINXCONF

ok "Configuracion generada en $NGINX_CONF"

$SUDO docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true

paso "Iniciando Nginx en el puerto $PROXY_PORT ..."
$SUDO docker run -d \
    --name "$NGINX_CONTAINER" \
    --network "$NETWORK_NAME" \
    --restart unless-stopped \
    -p "${PROXY_PORT}:80" \
    -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine >/dev/null

ok "Proxy inverso escuchando en el puerto $PROXY_PORT."

# ============================================================================
#  8. Validacion del despliegue
# ============================================================================

titulo "8. Validacion del despliegue"

# Se usa el codigo de salida de curl, no su salida: ante un fallo de conexion
# curl imprime "000" Y ademas sale con error, asi que un `|| echo 000` daria
# "000000" y el despliegue se reportaria como correcto sin serlo.
esperar_http() {
    local url="$1" etiqueta="$2" intentos="${3:-30}" codigo=""
    paso "Validando $etiqueta ($url) ..."
    for _ in $(seq 1 "$intentos"); do
        if codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null)"; then
            ok "$etiqueta responde (HTTP $codigo)."
            return 0
        fi
        sleep 2
    done
    aviso "$etiqueta no respondio tras $((intentos * 2))s."
    return 1
}

SERVICIO_OK="si"
PROXY_OK="si"
esperar_http "http://127.0.0.1:${APP_PORT}"   "el servicio"      || SERVICIO_OK="no"
esperar_http "http://127.0.0.1:${PROXY_PORT}" "el proxy inverso" || PROXY_OK="no"

[ "$SERVICIO_OK" = "no" ] && aviso "revisa los logs con: docker logs $CONTAINER_NAME"
[ "$PROXY_OK" = "no" ]    && aviso "revisa los logs con: docker logs $NGINX_CONTAINER"

# ============================================================================
#  9. Resumen
# ============================================================================

titulo "Despliegue finalizado"

cat <<RESUMEN

  Servicio ............ $SERVICE_NAME
  Imagen .............. $IMAGE_NAME
  Contenedor .......... $CONTAINER_NAME
  Red Docker .......... $NETWORK_NAME
  Proxy inverso ....... $NGINX_CONTAINER (puerto $PROXY_PORT)
  Variables cargadas .. $n_vars

  Flujo:  Cliente -> Nginx:$PROXY_PORT -> $CONTAINER_NAME:$APP_PORT

  Acceso directo al servicio ...... http://localhost:$APP_PORT
  Acceso a traves del proxy ....... http://localhost:$PROXY_PORT

  Validaciones:  servicio=$SERVICIO_OK  proxy=$PROXY_OK

  En Killercoda, para abrir el puerto $PROXY_PORT desde el navegador usa el
  menu "Traffic / Ports" de la interfaz y selecciona ese puerto.

  Archivos generados en $WORKDIR
    .env         variables de entorno (permisos 600)
    nginx.conf   configuracion del proxy inverso

  Comandos utiles:
    docker ps
    docker logs -f $CONTAINER_NAME
    docker logs -f $NGINX_CONTAINER
    curl -I http://127.0.0.1:$PROXY_PORT

  Para detener todo:
    docker rm -f $CONTAINER_NAME $NGINX_CONTAINER
    docker network rm $NETWORK_NAME

RESUMEN
