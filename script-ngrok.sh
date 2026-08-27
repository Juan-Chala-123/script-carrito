#!/bin/bash
# script-ngrok.sh
# Despliegue con docker compose + Nginx como proxy inverso + publicacion
# en Internet mediante ngrok.
#
#   Cliente -> ngrok -> Nginx (proxy inverso) -> contenedores del compose
#
#     /       -> carrito-frontend
#     /api/   -> carrito-backend
#
# Funciona como usuario normal (con sudo) y tambien como root.

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Despliegue + Nginx + ngrok${NC}"
echo -e "${GREEN}======================================${NC}"

REPO_URL="https://github.com/tadeo77789/carrito.git"
PROJECT_DIR="$HOME/carrito"
NGROK_LOG="$HOME/ngrok.log"
PROXY_CONF="$HOME/nginx-proxy.conf"
PROXY_NAME="carrito-proxy"
PUERTO_PUBLICO=8080          # puerto del proxy inverso, es el que publica ngrok

# ----------------------------------------------------------------------------
# Privilegios: si ya somos root no hace falta sudo (y en muchas imagenes ni
# siquiera esta instalado). Si no, se pide la contrasena una sola vez.
# ----------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    echo "👤 Ejecutando como root."
else
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}No eres root y sudo no esta instalado.${NC}"
        exit 1
    fi
    SUDO="sudo"
    echo "👤 Ejecutando como $(whoami), se usara sudo."
    sudo -v
fi

# Instalar Docker si no existe
if ! command -v docker &> /dev/null; then
    echo "📦 Instalando Docker..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    $SUDO systemctl start docker || $SUDO service docker start
fi

# Instalar el plugin de Compose si Docker no lo trae
if ! $SUDO docker compose version &> /dev/null; then
    echo "📦 Instalando el plugin de Docker Compose..."
    case "$(dpkg --print-architecture)" in
        amd64) CARCH="x86_64" ;;
        arm64) CARCH="aarch64" ;;
        *) echo -e "${RED}Arquitectura no soportada${NC}"; exit 1 ;;
    esac
    $SUDO install -m 0755 -d /usr/local/lib/docker/cli-plugins
    $SUDO curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${CARCH}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

# Instalar ngrok si no existe
if ! command -v ngrok &> /dev/null; then
    echo "📦 Instalando ngrok..."
    case "$(dpkg --print-architecture)" in
        amd64) ARCH="amd64" ;;
        arm64) ARCH="arm64" ;;
        *) echo -e "${RED}Arquitectura no soportada por ngrok${NC}"; exit 1 ;;
    esac
    curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${ARCH}.tgz" -o /tmp/ngrok.tgz
    $SUDO tar -xzf /tmp/ngrok.tgz -C /usr/local/bin ngrok
    $SUDO chmod +x /usr/local/bin/ngrok
    rm -f /tmp/ngrok.tgz
fi

# ----------------------------------------------------------------------------
# Token de ngrok: se pide oculto y no queda escrito en el script.
# ngrok se ejecuta SIN sudo para que la configuracion y el tunel queden a
# nombre del usuario, no de root.
# ----------------------------------------------------------------------------
echo ""
read -rsp "🔑 Pega tu token de ngrok (no se vera al escribir): " NGROK_TOKEN
echo ""
if [ -z "$NGROK_TOKEN" ]; then
    echo -e "${RED}El token es obligatorio.${NC}"
    exit 1
fi
ngrok config add-authtoken "$NGROK_TOKEN" > /dev/null
unset NGROK_TOKEN
echo -e "${GREEN}Token registrado.${NC}"

# ----------------------------------------------------------------------------
# Codigo del servicio. Se usa reset --hard en lugar de pull para que la copia
# local quede siempre igual al repositorio, aunque se haya parcheado en una
# ejecucion anterior o el historial remoto haya cambiado.
# ----------------------------------------------------------------------------
if [ -d "$PROJECT_DIR/.git" ]; then
    echo "📥 Actualizando el codigo..."
    cd "$PROJECT_DIR"
    git fetch origin
    git reset --hard origin/main
else
    echo "📥 Clonando el repositorio..."
    git clone "$REPO_URL" "$PROJECT_DIR"
    cd "$PROJECT_DIR"
fi

# ----------------------------------------------------------------------------
# Ajuste local del frontend. NO modifica el repositorio: solo esta copia.
#
# El index.html pide la API en http://<host>:3000/api. Servido por ngrok eso
# falla por dos motivos: el puerto 3000 no esta dentro del tunel, y una pagina
# https no puede pedir recursos http (el navegador lo bloquea por contenido
# mixto). Apuntando a la ruta relativa /api, la peticion sale al mismo origen
# y es el proxy inverso quien la lleva al backend.
# ----------------------------------------------------------------------------
echo "🔧 Ajustando el frontend para que use el proxy inverso..."
sed -i 's|const API = .*|const API = "/api";|' frontend/index.html
grep -q 'const API = "/api";' frontend/index.html || {
    echo -e "${RED}No se pudo ajustar frontend/index.html${NC}"; exit 1; }

# Desplegar con docker compose
echo "🚀 Desplegando..."
$SUDO docker compose down 2>/dev/null || true
$SUDO docker compose up -d --build

echo -e "${GREEN}✅ Contenedores levantados${NC}"
$SUDO docker compose ps

# ----------------------------------------------------------------------------
# Nginx como proxy inverso, unico punto de entrada.
# Se une a la red que crea Compose y resuelve los contenedores por su nombre.
# proxy_pass sin ruta al final conserva la URI original (/api/productos llega
# tal cual), que es lo que espera Express.
# ----------------------------------------------------------------------------
echo "🔀 Configurando Nginx como proxy inverso..."

RED_COMPOSE=$($SUDO docker inspect -f \
    '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' carrito-frontend)

if [ -z "$RED_COMPOSE" ]; then
    echo -e "${RED}No se pudo determinar la red de Compose${NC}"
    exit 1
fi

cat > "$PROXY_CONF" <<'NGINXCONF'
server {
    listen 80;
    server_name _;

    location /api/ {
        proxy_pass http://carrito-backend:3000;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://carrito-frontend:80;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINXCONF

$SUDO docker rm -f "$PROXY_NAME" > /dev/null 2>&1 || true
$SUDO docker run -d \
    --name "$PROXY_NAME" \
    --network "$RED_COMPOSE" \
    --restart unless-stopped \
    -p "${PUERTO_PUBLICO}:80" \
    -v "$PROXY_CONF:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine > /dev/null

sleep 2
if [ "$($SUDO docker inspect -f '{{.State.Running}}' $PROXY_NAME)" != "true" ]; then
    echo -e "${RED}Nginx no arranco:${NC}"
    $SUDO docker logs "$PROXY_NAME"
    exit 1
fi
echo -e "${GREEN}✅ Proxy inverso escuchando en el puerto ${PUERTO_PUBLICO}${NC}"

# Comprobacion: la API debe responder a traves del proxy
if curl -fs "http://127.0.0.1:${PUERTO_PUBLICO}/api/productos" > /dev/null; then
    echo -e "${GREEN}✅ La API responde a traves del proxy${NC}"
else
    echo -e "${YELLOW}⚠️  La API aun no responde; puede que la base este arrancando.${NC}"
fi

# ----------------------------------------------------------------------------
# Tunel de ngrok
# ----------------------------------------------------------------------------
echo ""
echo "🌐 Publicando el puerto ${PUERTO_PUBLICO} con ngrok..."
pkill -f 'ngrok http' 2>/dev/null || true   # el plan gratuito solo permite un tunel
sleep 1
nohup ngrok http "$PUERTO_PUBLICO" --log=stdout > "$NGROK_LOG" 2>&1 &
NGROK_PID=$!

# La URL publica se consulta a la API local del agente (puerto 4040)
PUBLIC_URL=""
for i in $(seq 1 30); do
    if ! kill -0 "$NGROK_PID" 2>/dev/null; then
        echo -e "${RED}El agente de ngrok se detuvo. Log:${NC}"
        tail -n 20 "$NGROK_LOG"
        exit 1
    fi
    PUBLIC_URL=$(curl -s --max-time 3 http://127.0.0.1:4040/api/tunnels \
        | grep -o '"public_url":"https:[^"]*"' | head -n 1 | cut -d'"' -f4)
    [ -n "$PUBLIC_URL" ] && break
    sleep 2
done

if [ -z "$PUBLIC_URL" ]; then
    echo -e "${RED}No se pudo obtener la URL publica. Log:${NC}"
    tail -n 20 "$NGROK_LOG"
    exit 1
fi

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} 🎉 Aplicacion publicada${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "  Flujo:  Cliente -> ngrok -> Nginx:${PUERTO_PUBLICO} -> contenedores"
echo ""
echo -e "  URL publica:  ${GREEN}${PUBLIC_URL}${NC}"
echo -e "  Local:        http://localhost:${PUERTO_PUBLICO}"
echo -e "  Panel ngrok:  http://localhost:4040"
echo ""
echo -e "${YELLOW}  El tunel sigue activo mientras esta terminal este abierta.${NC}"
echo -e "${YELLOW}  Para detenerlo:   kill ${NGROK_PID}${NC}"
echo -e "${YELLOW}  Para bajar todo:  ${SUDO} docker rm -f ${PROXY_NAME} && cd ${PROJECT_DIR} && ${SUDO} docker compose down${NC}"
echo ""
