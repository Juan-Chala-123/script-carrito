#!/usr/bin/env bash
#
# ESCENARIO 1 - Maquina virtual local
# Despliegue y publicacion de un servicio mediante Docker, Nginx y ngrok.
#
#   Cliente -> ngrok -> Nginx (proxy inverso) -> Docker -> Servicio
#
# El script es parametrizable: todos los datos del despliegue se solicitan
# durante la ejecucion, por lo que sirve para cualquier servicio que tenga
# un Dockerfile. Ningun dato del despliegue ni el token de ngrok quedan
# escritos en este archivo.
#
# Entorno objetivo: Ubuntu / Debian. Funciona como root o con sudo.
#
# Para el despliegue en Killercoda sin publicacion externa, usar
# script-killercoda.sh
#
# Uso:  ./script-ngrok.sh

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

paso "Instalando utilidades base..."
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq ca-certificates curl git iproute2 procps >/dev/null
ok "curl, git y utilidades disponibles."

# ---- Docker ----------------------------------------------------------------

if command -v docker >/dev/null 2>&1 && $SUDO docker compose version >/dev/null 2>&1; then
    ok "Docker ya esta instalado."
else
    paso "Instalando Docker desde el repositorio oficial..."

    $SUDO apt-get remove -y -qq \
        docker.io docker-doc docker-compose docker-compose-v2 \
        podman-docker containerd runc >/dev/null 2>&1 || true

    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    [ -n "$codename" ] || error "no se pudo determinar el codename de la distribucion."

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null

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

# ---- ngrok -----------------------------------------------------------------

if command -v ngrok >/dev/null 2>&1; then
    ok "ngrok ya esta instalado."
else
    paso "Instalando ngrok..."
    case "$(dpkg --print-architecture)" in
        amd64) NGROK_ARCH="amd64" ;;
        arm64) NGROK_ARCH="arm64" ;;
        *)     error "arquitectura no soportada para ngrok: $(dpkg --print-architecture)" ;;
    esac
    curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${NGROK_ARCH}.tgz" \
        -o /tmp/ngrok.tgz
    $SUDO tar -xzf /tmp/ngrok.tgz -C /usr/local/bin ngrok
    $SUDO chmod +x /usr/local/bin/ngrok
    rm -f /tmp/ngrok.tgz
    ok "ngrok instalado."
fi

echo "  ngrok:   $(ngrok version)"

# ============================================================================
#  2. Datos del servicio (seccion 7.1 de la actividad)
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
NGROK_LOG="$WORKDIR/ngrok.log"

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
#  4. Datos de ngrok (seccion 7.2 de la actividad)
# ============================================================================

titulo "4. Datos de ngrok"

# El token se lee con -s: no se muestra al digitarlo, no se imprime nunca y
# no queda en el codigo ni en el .env. ngrok lo guarda en su propio archivo
# de configuracion del usuario.
NGROK_TOKEN=""
while [ -z "$NGROK_TOKEN" ]; do
    read -rsp "  Token de autenticacion de ngrok (no se mostrara): " NGROK_TOKEN || true
    echo ""
    [ -z "$NGROK_TOKEN" ] && aviso "el token es obligatorio."
done
ok "Token recibido (oculto)."

NGROK_PORT="$(preguntar_puerto 'Puerto que se publicara mediante ngrok' "$PROXY_PORT")"
NGROK_DOMAIN="$(preguntar 'Dominio reservado de ngrok (Enter para uno aleatorio)' 'ninguno')"
[ "$NGROK_DOMAIN" = "ninguno" ] && NGROK_DOMAIN=""

# ============================================================================
#  5. Construccion de la imagen
# ============================================================================

titulo "5. Construccion de la imagen Docker"

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
#  6. Red Docker
# ============================================================================

titulo "6. Red Docker"

if $SUDO docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    ok "La red $NETWORK_NAME ya existe."
else
    $SUDO docker network create "$NETWORK_NAME" >/dev/null
    ok "Red $NETWORK_NAME creada."
fi

# ============================================================================
#  7. Contenedor del servicio
# ============================================================================

titulo "7. Contenedor del servicio"

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
#  8. Nginx como proxy inverso
# ============================================================================

titulo "8. Proxy inverso (Nginx)"

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
#  9. Validacion del servicio y del proxy
# ============================================================================

titulo "9. Validacion del despliegue"

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
#  10. Tunel ngrok
# ============================================================================

titulo "10. Publicacion mediante ngrok"

paso "Registrando el token..."
ngrok config add-authtoken "$NGROK_TOKEN" >/dev/null
unset NGROK_TOKEN   # ya no se necesita en memoria
ok "Token registrado en la configuracion de ngrok."

pkill -f 'ngrok (http|start)' >/dev/null 2>&1 || true
sleep 1

ngrok_args=(http "$NGROK_PORT" --log=stdout --log-format=logfmt)
[ -n "$NGROK_DOMAIN" ] && ngrok_args+=(--domain="$NGROK_DOMAIN")

paso "Abriendo el tunel hacia el puerto $NGROK_PORT ..."
nohup ngrok "${ngrok_args[@]}" > "$NGROK_LOG" 2>&1 &
NGROK_PID=$!

# La URL publica se consulta a la API local del agente (puerto 4040).
PUBLIC_URL=""
for _ in $(seq 1 30); do
    if ! kill -0 "$NGROK_PID" 2>/dev/null; then
        echo ""
        tail -n 20 "$NGROK_LOG" >&2
        error "el agente de ngrok termino inesperadamente (ver $NGROK_LOG)."
    fi
    PUBLIC_URL="$(curl -s --max-time 3 http://127.0.0.1:4040/api/tunnels \
        | grep -o '"public_url":"https:[^"]*"' \
        | head -n 1 | cut -d'"' -f4 || true)"
    [ -n "$PUBLIC_URL" ] && break
    sleep 2
done

if [ -z "$PUBLIC_URL" ]; then
    tail -n 20 "$NGROK_LOG" >&2
    error "no se pudo obtener la URL publica de ngrok."
fi
ok "Tunel establecido (PID $NGROK_PID)."

# ---- Validacion de la publicacion externa ----------------------------------

paso "Validando el acceso externo ..."
PUBLICA_OK="no"
for _ in $(seq 1 10); do
    if codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
            -H 'ngrok-skip-browser-warning: true' "$PUBLIC_URL" 2>/dev/null)"; then
        ok "La URL publica responde (HTTP $codigo)."
        PUBLICA_OK="si"
        break
    fi
    sleep 2
done
[ "$PUBLICA_OK" = "si" ] || aviso "la URL publica no respondio; revisa $NGROK_LOG"

# ============================================================================
#  11. Resumen
# ============================================================================

titulo "Despliegue finalizado"

cat <<RESUMEN

  Servicio ............ $SERVICE_NAME
  Imagen .............. $IMAGE_NAME
  Contenedor .......... $CONTAINER_NAME
  Red Docker .......... $NETWORK_NAME
  Proxy inverso ....... $NGINX_CONTAINER (puerto $PROXY_PORT)
  Variables cargadas .. $n_vars

  Flujo:  Cliente -> ngrok -> Nginx:$PROXY_PORT -> $CONTAINER_NAME:$APP_PORT

  Acceso directo al servicio ...... http://localhost:$APP_PORT
  Acceso a traves del proxy ....... http://localhost:$PROXY_PORT
  URL PUBLICA (ngrok) ............. $PUBLIC_URL

  Validaciones:  servicio=$SERVICIO_OK  proxy=$PROXY_OK  publica=$PUBLICA_OK

  Archivos generados en $WORKDIR
    .env         variables de entorno (permisos 600)
    nginx.conf   configuracion del proxy inverso
    ngrok.log    log del tunel

  Comandos utiles:
    docker ps
    docker logs -f $CONTAINER_NAME
    docker logs -f $NGINX_CONTAINER
    tail -f $NGROK_LOG
    curl http://127.0.0.1:4040/api/tunnels

  Para detener todo:
    kill $NGROK_PID
    docker rm -f $CONTAINER_NAME $NGINX_CONTAINER
    docker network rm $NETWORK_NAME

  El tunel seguira activo mientras esta terminal permanezca abierta.

RESUMEN
