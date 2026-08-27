#!/usr/bin/env bash
#
# ESCENARIO 1 - Maquina virtual local
# Despliegue y publicacion de un servicio mediante Docker Compose, Nginx y ngrok.
#
#   Cliente -> ngrok -> Nginx (proxy inverso) -> contenedores del compose
#
# El script levanta el docker-compose.yml que trae el propio repositorio del
# servicio, coloca delante un Nginx que actua como unico punto de entrada:
#
#     /       ->  contenedor del frontend
#     /api/   ->  contenedor del backend
#
# y publica ese proxy en Internet mediante un tunel de ngrok.
#
# Es parametrizable: todos los datos se solicitan durante la ejecucion, por
# lo que sirve para cualquier proyecto con docker-compose.yml. No hay rutas,
# puertos, nombres ni credenciales escritos en este archivo, y el token de
# ngrok tampoco.
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

# ---- apt --------------------------------------------------------------------
# DPkg::Lock::Timeout evita el cuelgue silencioso cuando unattended-upgrades
# tiene tomado el lock de dpkg al arrancar la maquina.
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

asegurar_repo_docker() {
    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        return 0
    fi
    paso "Anadiendo el repositorio oficial de Docker..."
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    [ -n "$codename" ] || error "no se pudo determinar el codename de la distribucion."

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
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

paso "Verificando utilidades base..."

# Solo se llama a apt si falta algo: en una maquina que ya las tiene, esto
# ahorra el `apt-get update` completo.
FALTANTES=()
for p in ca-certificates curl git iproute2 procps; do
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
# Killercoda y muchas imagenes de Ubuntu ya traen Docker: si esta, no se
# reinstala nada, que es lo que hacia que este paso tardara varios minutos.

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

    asegurar_repo_docker
    paso "Instalando Docker..."
    apt_update
    apt_install docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin

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

# Compose es imprescindible: el despliegue usa el docker-compose.yml del repo.
if $SUDO docker compose version >/dev/null 2>&1; then
    ok "Docker Compose disponible."
else
    paso "Falta el plugin de Docker Compose, instalando solo ese paquete..."
    asegurar_repo_docker
    apt_update
    apt_install docker-compose-plugin
    $SUDO docker compose version >/dev/null 2>&1 \
        || error "no se pudo instalar Docker Compose."
    ok "Docker Compose instalado."
fi

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

echo "  Docker:  $($SUDO docker --version)"
echo "  Compose: $($SUDO docker compose version --short 2>/dev/null || echo desconocida)"
echo "  ngrok:   $(ngrok version)"

# ============================================================================
#  2. Datos del despliegue
# ============================================================================

titulo "2. Datos del despliegue"

echo "  Responde los siguientes datos. Entre corchetes aparece el valor por"
echo "  defecto: pulsa Enter para aceptarlo."
echo ""

PROJECT="$(preguntar        'Nombre del proyecto' 'carrito')"
REPO_URL="$(preguntar       'URL del repositorio del servicio')"
COMPOSE_SUBDIR="$(preguntar 'Ruta del docker-compose.yml dentro del repo' '.')"
PROXY_PORT="$(preguntar_puerto 'Puerto del proxy inverso (Nginx)' '80')"

echo ""
echo "  Ahora los servicios del docker-compose.yml que Nginx debe publicar."
echo "  Son los nombres tal como aparecen bajo 'services:'."
echo ""

FRONT_SVC="$(preguntar  'Servicio del frontend (vacio si no hay)' 'frontend')"
[ "$FRONT_SVC" = "vacio" ] && FRONT_SVC=""
if [ -n "$FRONT_SVC" ]; then
    FRONT_PORT="$(preguntar_puerto "Puerto interno de $FRONT_SVC" '80')"
else
    FRONT_PORT=""
fi

BACK_SVC="$(preguntar        'Servicio del backend' 'backend')"
BACK_PORT="$(preguntar_puerto "Puerto interno de $BACK_SVC" '3000')"
API_PREFIX="$(preguntar      'Prefijo de las rutas del backend' '/api/')"

# Nginx exige que el prefijo empiece y termine en /
[[ "$API_PREFIX" == /* ]]  || API_PREFIX="/$API_PREFIX"
[[ "$API_PREFIX" == */ ]]  || API_PREFIX="$API_PREFIX/"

NGINX_CONTAINER="${PROJECT}-proxy"

if puerto_ocupado "$PROXY_PORT"; then
    aviso "el puerto $PROXY_PORT ya esta en uso; el arranque de Nginx puede fallar."
fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

WORKDIR="$TARGET_HOME/despliegue-$PROJECT"
SRC_DIR="$WORKDIR/src"
NGINX_CONF="$WORKDIR/nginx.conf"
NGROK_LOG="$WORKDIR/ngrok.log"

mkdir -p "$WORKDIR"

# ============================================================================
#  3. Datos de ngrok
# ============================================================================

titulo "3. Datos de ngrok"

# El token se lee con -s: no se muestra al digitarlo, no se imprime nunca y
# no queda en el codigo ni en ningun archivo del repositorio. ngrok lo guarda
# en su propio archivo de configuracion del usuario.
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

echo ""
paso "Ya no se piden mas datos: el resto del despliegue es automatico."

# ============================================================================
#  4. Clonado del repositorio
# ============================================================================

titulo "4. Codigo del servicio"

if [ -d "$SRC_DIR/.git" ]; then
    paso "El codigo ya existe, actualizando..."
    git -C "$SRC_DIR" pull --ff-only || aviso "no se pudo actualizar; se usa la copia local."
else
    rm -rf "$SRC_DIR"
    paso "Clonando $REPO_URL ..."
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

COMPOSE_DIR="$SRC_DIR/$COMPOSE_SUBDIR"
[ -d "$COMPOSE_DIR" ] || error "la ruta '$COMPOSE_SUBDIR' no existe dentro del repositorio."

COMPOSE_FILE=""
for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$COMPOSE_DIR/$f" ]; then
        COMPOSE_FILE="$COMPOSE_DIR/$f"
        break
    fi
done
[ -n "$COMPOSE_FILE" ] || error "no se encontro un archivo compose en $COMPOSE_DIR."

ok "Usando $COMPOSE_FILE"

compose() {
    $SUDO docker compose -p "$PROJECT" -f "$COMPOSE_FILE" \
        --project-directory "$COMPOSE_DIR" "$@"
}

# ============================================================================
#  5. Variables de entorno
# ============================================================================

titulo "5. Variables de entorno del servicio"

echo "  Se escriben en un archivo .env junto al docker-compose.yml, que Compose"
echo "  lee automaticamente. Formato CLAVE=VALOR, una por linea."
echo "  Ejemplos: DB_USER=admin   DB_PASSWORD=secreto   DB_NAME=tienda"
echo "  Deja la linea vacia y pulsa Enter para terminar (se usaran los valores"
echo "  por defecto del docker-compose.yml)."
echo ""

ENV_FILE="$COMPOSE_DIR/.env"

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
    rm -f "$ENV_FILE"
    ok "Sin variables: se usan los valores por defecto del compose."
else
    ok "$n_vars variable(s) guardadas en $ENV_FILE (permisos 600)."
fi

# ============================================================================
#  6. Despliegue con Docker Compose
# ============================================================================

titulo "6. Despliegue con Docker Compose"

echo ""
aviso "La construccion de las imagenes puede tardar varios minutos la"
aviso "primera vez (descarga de imagenes base y dependencias)."
echo ""

paso "Levantando los servicios..."
compose up -d --build --remove-orphans

ok "Servicios levantados."
echo ""
compose ps

# ============================================================================
#  7. Descubrimiento de contenedores y red
# ============================================================================

titulo "7. Contenedores y red"

# El nombre real del contenedor y de la red los decide Compose (prefijo de
# proyecto incluido), asi que se consultan en vez de suponerlos.
nombre_contenedor() {
    local svc="$1" cid=""
    cid="$(compose ps -q "$svc" 2>/dev/null | head -n 1)"
    [ -n "$cid" ] || error "el servicio '$svc' no existe o no esta levantado."
    $SUDO docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##'
}

red_contenedor() {
    local svc="$1" cid=""
    cid="$(compose ps -q "$svc" 2>/dev/null | head -n 1)"
    $SUDO docker inspect \
        -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid" \
        | awk '{print $1}'
}

BACK_CONTAINER="$(nombre_contenedor "$BACK_SVC")"
NETWORK_NAME="$(red_contenedor "$BACK_SVC")"
ok "Backend:  $BACK_CONTAINER (red $NETWORK_NAME)"

FRONT_CONTAINER=""
if [ -n "$FRONT_SVC" ]; then
    FRONT_CONTAINER="$(nombre_contenedor "$FRONT_SVC")"
    ok "Frontend: $FRONT_CONTAINER"
fi

[ -n "$NETWORK_NAME" ] || error "no se pudo determinar la red de Compose."

# ============================================================================
#  8. Nginx como proxy inverso
# ============================================================================

titulo "8. Proxy inverso (Nginx)"

# Nginx se une a la red de Compose y resuelve los contenedores por su nombre.
# proxy_pass sin ruta al final conserva la URI original, que es lo que el
# backend espera recibir.
{
    echo "server {"
    echo "    listen 80;"
    echo "    server_name _;"
    echo ""
    echo "    location ${API_PREFIX} {"
    echo "        proxy_pass http://${BACK_CONTAINER}:${BACK_PORT};"
    echo "        proxy_http_version 1.1;"
    echo "        proxy_set_header Host              \$host;"
    echo "        proxy_set_header X-Real-IP         \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_connect_timeout 30s;"
    echo "        proxy_read_timeout    60s;"
    echo "    }"
    echo ""
    echo "    location / {"
    if [ -n "$FRONT_CONTAINER" ]; then
        echo "        proxy_pass http://${FRONT_CONTAINER}:${FRONT_PORT};"
    else
        echo "        proxy_pass http://${BACK_CONTAINER}:${BACK_PORT};"
    fi
    echo "        proxy_http_version 1.1;"
    echo "        proxy_set_header Host              \$host;"
    echo "        proxy_set_header X-Real-IP         \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_set_header Upgrade    \$http_upgrade;"
    echo "        proxy_set_header Connection \"upgrade\";"
    echo "        proxy_connect_timeout 30s;"
    echo "        proxy_read_timeout    60s;"
    echo "    }"
    echo "}"
} > "$NGINX_CONF"

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

# Si la configuracion es invalida el contenedor arranca y muere enseguida.
sleep 2
if [ "$($SUDO docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER")" != "true" ]; then
    $SUDO docker logs "$NGINX_CONTAINER" >&2 || true
    error "Nginx no arranco. Revisa $NGINX_CONF"
fi

ok "Proxy inverso escuchando en el puerto $PROXY_PORT."

# ============================================================================
#  9. Validacion del despliegue
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

PROXY_OK="si"
API_OK="si"
esperar_http "http://127.0.0.1:${PROXY_PORT}/"            "el proxy inverso"      || PROXY_OK="no"
esperar_http "http://127.0.0.1:${PROXY_PORT}${API_PREFIX}" "el backend via proxy" || API_OK="no"

if [ "$PROXY_OK" = "no" ] || [ "$API_OK" = "no" ]; then
    aviso "revisa los logs con:"
    aviso "  docker logs $NGINX_CONTAINER"
    aviso "  docker compose -p $PROJECT logs"
fi

# ============================================================================
#  10. Publicacion mediante ngrok
# ============================================================================

titulo "10. Publicacion mediante ngrok"

paso "Registrando el token..."
ngrok config add-authtoken "$NGROK_TOKEN" >/dev/null
unset NGROK_TOKEN   # ya no se necesita en memoria
ok "Token registrado en la configuracion de ngrok."

# El plan gratuito solo permite un tunel simultaneo: se cierra el anterior.
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

  Proyecto ............ $PROJECT
  Compose ............. $COMPOSE_FILE
  Proxy inverso ....... $NGINX_CONTAINER (puerto $PROXY_PORT)
  Red Docker .......... $NETWORK_NAME
  Variables cargadas .. $n_vars

  Enrutamiento de Nginx:
    /             -> ${FRONT_CONTAINER:-$BACK_CONTAINER}:${FRONT_PORT:-$BACK_PORT}
    ${API_PREFIX}         -> ${BACK_CONTAINER}:${BACK_PORT}

  Flujo:  Cliente -> ngrok -> Nginx:$PROXY_PORT -> contenedores del compose

  Acceso a traves del proxy ....... http://localhost:$PROXY_PORT
  URL PUBLICA (ngrok) ............. $PUBLIC_URL

  Validaciones:  proxy=$PROXY_OK  api=$API_OK  publica=$PUBLICA_OK

  Archivos generados en $WORKDIR
    src/         codigo clonado del servicio
    nginx.conf   configuracion del proxy inverso
    ngrok.log    log del tunel

  Comandos utiles:
    docker compose -p $PROJECT ps
    docker compose -p $PROJECT logs -f
    docker logs -f $NGINX_CONTAINER
    tail -f $NGROK_LOG
    curl http://127.0.0.1:4040/api/tunnels
    curl -i http://127.0.0.1:$PROXY_PORT${API_PREFIX}

  La interfaz web de ngrok en http://localhost:4040 muestra cada peticion
  entrante: es la evidencia de que el trafico externo pasa por el tunel.

  Para detener todo:
    kill $NGROK_PID
    docker rm -f $NGINX_CONTAINER
    docker compose -p $PROJECT -f $COMPOSE_FILE down

  El tunel seguira activo mientras esta terminal permanezca abierta.

RESUMEN
