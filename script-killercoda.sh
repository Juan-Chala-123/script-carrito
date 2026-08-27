#!/bin/bash
# script-killercoda.sh
# Despliegue automatico con Docker Compose + Nginx como proxy inverso.
#
#   Cliente -> Nginx (proxy inverso) -> contenedores del docker-compose.yml
#
#     /       -> carrito-frontend
#     /api/   -> carrito-backend
#
# Todo entra por un unico puerto, asi que en Killercoda solo hay que exponer
# ese. Funciona como root y como usuario normal con sudo.

set -e

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Despliegue automatico${NC}"
echo -e "${GREEN}======================================${NC}"

REPO_URL="https://github.com/tadeo77789/carrito.git"
PROJECT_DIR="$HOME/carrito"
PROXY_CONF="$HOME/nginx-proxy.conf"
PROXY_NAME="carrito-proxy"
PUERTO_PUBLICO=8080          # puerto del proxy inverso: el unico que se expone

# Evita que apt espere indefinidamente si otro proceso tiene el lock de dpkg,
# que es lo habitual en una maquina recien arrancada.
APT_OPTS="-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3"

# =============================================
# 0. Privilegios
# =============================================
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    echo -e "\n👤 Ejecutando como root."
else
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}No eres root y sudo no esta instalado.${NC}"
        exit 1
    fi
    SUDO="sudo"
    echo -e "\n👤 Ejecutando como $(whoami), se usara sudo."
    sudo -v
fi

# =============================================
# 1. Instalar Docker
# =============================================
echo -e "\n${YELLOW}[1/5] Docker...${NC}"

if ! command -v docker &> /dev/null; then
    echo "Instalando Docker..."
    $SUDO apt-get update -qq $APT_OPTS
    $SUDO apt-get install -y $APT_OPTS ca-certificates curl gnupg lsb-release

    # Repositorio oficial
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    $SUDO apt-get update -qq $APT_OPTS
    $SUDO apt-get install -y $APT_OPTS docker-ce docker-ce-cli containerd.io docker-compose-plugin
    $SUDO systemctl start docker 2>/dev/null || $SUDO service docker start
    $SUDO systemctl enable docker 2>/dev/null || true
else
    echo -e "${GREEN}Docker OK: $($SUDO docker --version)${NC}"
fi

# El demonio tiene que estar arriba
if ! $SUDO docker info &> /dev/null; then
    $SUDO systemctl start docker 2>/dev/null || $SUDO service docker start || true
    $SUDO docker info &> /dev/null \
        || { echo -e "${RED}El demonio de Docker no responde${NC}"; exit 1; }
fi

# =============================================
# 2. docker compose (plugin)
# =============================================
echo -e "\n${YELLOW}[2/5] Docker Compose...${NC}"

# Solo se instala si falta de verdad. Si ya funciona no se llama a apt, que es
# la parte lenta y la que choca con el lock de dpkg.
if $SUDO docker compose version &> /dev/null; then
    echo -e "${GREEN}Compose OK: $($SUDO docker compose version --short)${NC}"
else
    echo "Instalando el plugin de Docker Compose..."
    case "$(dpkg --print-architecture)" in
        amd64) CARCH="x86_64" ;;
        arm64) CARCH="aarch64" ;;
        *) echo -e "${RED}Arquitectura no soportada${NC}"; exit 1 ;;
    esac

    # El binario va al directorio donde la CLI de Docker busca sus plugins.
    # Dejarlo en /usr/local/bin no habilita `docker compose`, solo el comando
    # antiguo `docker-compose`.
    # -f para que curl falle de verdad si la descarga no sale bien, en vez de
    # guardar la pagina de error dentro del archivo y marcarla como ejecutable.
    $SUDO install -m 0755 -d /usr/local/lib/docker/cli-plugins
    $SUDO curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${CARCH}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    $SUDO docker compose version &> /dev/null \
        || { echo -e "${RED}No se pudo instalar Docker Compose${NC}"; exit 1; }
    echo -e "${GREEN}Compose instalado: $($SUDO docker compose version --short)${NC}"
fi

# =============================================
# 3. Codigo del servicio
# =============================================
echo -e "\n${YELLOW}[3/5] Descargando el codigo...${NC}"

# reset --hard en lugar de pull: deja la copia local siempre igual al
# repositorio, aunque se haya parcheado en una ejecucion anterior o el
# historial remoto haya cambiado. Con `git pull ... || true` un fallo pasaba
# desapercibido y el despliegue continuaba con codigo viejo.
if [ -d "$PROJECT_DIR/.git" ]; then
    cd "$PROJECT_DIR"
    git fetch origin
    git reset --hard origin/main
else
    git clone "$REPO_URL" "$PROJECT_DIR"
    cd "$PROJECT_DIR"
fi

# ---------------------------------------------
# Ajuste local del frontend. NO modifica el repositorio: solo esta copia.
#
# El index.html pide la API en http://<host>:3000/api. Eso no funciona detras
# del proxy https de Killercoda: el navegador bloquea la peticion por
# contenido mixto (Mixed Block), y ademas Killercoda no usa :3000 sino un
# hostname distinto para cada puerto. Con la ruta relativa /api la peticion
# sale al mismo origen y la enruta el proxy inverso.
# ---------------------------------------------
echo "Ajustando el frontend para que use el proxy inverso..."
sed -i 's|const API = .*|const API = "/api";|' frontend/index.html
grep -q 'const API = "/api";' frontend/index.html \
    || { echo -e "${RED}No se pudo ajustar frontend/index.html${NC}"; exit 1; }

# =============================================
# 4. Desplegar
# =============================================
echo -e "\n${YELLOW}[4/5] Desplegando...${NC}"

$SUDO docker compose down 2>/dev/null || true
$SUDO docker compose up -d --build

echo -e "${GREEN}Contenedores levantados${NC}"
$SUDO docker compose ps

# =============================================
# 5. Nginx como proxy inverso
# =============================================
echo -e "\n${YELLOW}[5/5] Configurando Nginx como proxy inverso...${NC}"

# La red la crea Compose con el prefijo del proyecto, asi que se consulta en
# vez de suponerla.
RED_COMPOSE=$($SUDO docker inspect -f \
    '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' carrito-frontend)

if [ -z "$RED_COMPOSE" ]; then
    echo -e "${RED}No se pudo determinar la red de Compose${NC}"
    exit 1
fi

# proxy_pass sin ruta al final conserva la URI original (/api/productos llega
# tal cual), que es lo que espera Express.
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

# Con una configuracion invalida el contenedor arranca y muere enseguida.
sleep 2
if [ "$($SUDO docker inspect -f '{{.State.Running}}' $PROXY_NAME)" != "true" ]; then
    echo -e "${RED}Nginx no arranco:${NC}"
    $SUDO docker logs "$PROXY_NAME"
    exit 1
fi
echo -e "${GREEN}Proxy inverso escuchando en el puerto ${PUERTO_PUBLICO}${NC}"

# Comprobacion real: la API debe responder a traves del proxy
API_OK="no"
for i in $(seq 1 15); do
    if curl -fs "http://127.0.0.1:${PUERTO_PUBLICO}/api/productos" > /dev/null; then
        API_OK="si"
        break
    fi
    sleep 2
done

echo ""
echo -e "${GREEN}======================================${NC}"
if [ "$API_OK" = "si" ]; then
    echo -e "${GREEN}✅ ¡DESPLIEGUE EXITOSO!${NC}"
else
    echo -e "${YELLOW}⚠️  DESPLEGADO, PERO LA API NO RESPONDE${NC}"
fi
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "  Flujo:  Cliente -> Nginx:${PUERTO_PUBLICO} -> frontend / backend -> db"
echo ""
echo -e "  Local:  http://localhost:${PUERTO_PUBLICO}"
echo ""
echo -e "${YELLOW}  En Killercoda: menu 'Traffic / Ports' -> Custom Ports${NC}"
echo -e "${YELLOW}  y expon UNICAMENTE el puerto ${PUERTO_PUBLICO}.${NC}"
echo -e "${YELLOW}  Ya no hace falta abrir el 3000: todo pasa por el proxy.${NC}"
echo ""

if [ "$API_OK" = "no" ]; then
    echo -e "${YELLOW}  Revisa con:${NC}"
    echo "    $SUDO docker compose -f $PROJECT_DIR/docker-compose.yml logs"
    echo "    $SUDO docker logs $PROXY_NAME"
    echo ""
fi

echo "Contenedores en ejecucion:"
$SUDO docker ps
