# Scripts de despliegue: Docker + Nginx (proxy inverso) + ngrok

Actividad de aprendizaje: despliegue y publicación de un servicio mediante
Docker, proxy inverso y ngrok.

El repositorio contiene **dos scripts**, uno por escenario:

| Script | Escenario | Publicación externa |
| --- | --- | --- |
| `script-ngrok.sh` | Máquina virtual local | Sí, mediante ngrok |
| `script-killercoda.sh` | Killercoda | No |

Ambos son parametrizables: todos los datos del despliegue se solicitan durante
la ejecución, por lo que el mismo script sirve para cualquier servicio que
disponga de un `Dockerfile`. No hay rutas, puertos, nombres ni credenciales
escritos en el código.

## Arquitectura

### Escenario 1 — máquina virtual local (`script-ngrok.sh`)

```text
                 INTERNET
                     │
                     ▼
                  ngrok            túnel público
                     │
                     ▼
              ┌──────────────┐
              │    Nginx     │     contenedor, publica el puerto del proxy
              │ Proxy inverso│
              └──────┬───────┘
                     │             red Docker interna (DNS por nombre)
                     ▼
              ┌──────────────┐
              │   Servicio   │     contenedor construido desde el Dockerfile
              └──────────────┘
```

### Escenario 2 — Killercoda (`script-killercoda.sh`)

```text
                  Cliente
                     │
                     ▼
              ┌──────────────┐
              │    Nginx     │
              │ Proxy inverso│
              └──────┬───────┘
                     │             red Docker interna (DNS por nombre)
                     ▼
              ┌──────────────┐
              │   Servicio   │
              └──────────────┘
```

Para acceder desde el navegador en Killercoda se usa el menú **Traffic /
Ports** de su interfaz, seleccionando el puerto del proxy inverso.

## Requisitos

- Ubuntu / Debian / Killercoda, como `root` o con un usuario con `sudo`.
- Conexión a Internet.
- Un repositorio git con el código del servicio y su `Dockerfile`.
- Solo para `script-ngrok.sh`: cuenta de ngrok y su token de autenticación
  (https://dashboard.ngrok.com/get-started/your-authtoken).

Docker y ngrok los instalan los propios scripts si no están. Si la máquina ya
trae Docker —como los entornos de Killercoda— la instalación se omite por
completo y el despliegue arranca en segundos.

No se instala Docker Compose: los scripts usan `docker build` y `docker run`
directamente, así que no hace falta.

## Uso

```bash
git clone https://github.com/Juan-Chala-123/script-carrito.git
cd script-carrito
chmod +x script-ngrok.sh script-killercoda.sh
```

En la máquina virtual local:

```bash
./script-ngrok.sh
```

En Killercoda:

```bash
./script-killercoda.sh
```

## Datos que solicitan

### Del servicio (ambos scripts)

| Dato | Ejemplo | Por defecto |
| --- | --- | --- |
| Nombre del servicio | `carrito` | — |
| URL del repositorio git | `https://github.com/tadeo77789/carrito.git` | — |
| Ruta del Dockerfile dentro del repo | `.` o `backend` | `.` |
| Nombre de la imagen Docker | `carrito:latest` | `<servicio>:latest` |
| Nombre del contenedor | `carrito-app` | `<servicio>-app` |
| Puerto interno de la aplicación | `8080` | `8080` |
| Puerto del proxy inverso | `80` | `80` |

El **puerto interno** debe coincidir con el que expone el `Dockerfile` del
servicio. Si no coincide, Nginx devolverá `502 Bad Gateway`.

### Variables de entorno (ambos scripts)

Se introducen en formato `CLAVE=VALOR`, una por línea, y se termina con una
línea vacía. Por ejemplo:

```text
DB_HOST=db
DB_PORT=5432
DB_NAME=carrito
DB_USER=admin
DB_PASSWORD=secreto
API_URL=http://api
SPRING_PROFILES_ACTIVE=prod
```

Se guardan en `~/despliegue-<servicio>/.env` con permisos `600` y se pasan al
contenedor con `--env-file`. Cada servicio aporta las suyas.

### De ngrok (solo `script-ngrok.sh`)

| Dato | Notas |
| --- | --- |
| Token de autenticación | Se digita **oculto** (`read -s`); no se muestra ni se registra |
| Puerto a publicar | Por defecto, el del proxy inverso |
| Dominio reservado | Opcional; con Enter se usa un dominio aleatorio |

El token nunca se escribe en el código ni en el `.env`. Se entrega a
`ngrok config add-authtoken`, que lo almacena en la configuración del usuario,
y se borra de memoria con `unset` inmediatamente después.

## Qué automatizan

Pasos comunes a los dos scripts:

1. Validación de dependencias e instalación de Docker.
2. Arranque del demonio de Docker si no está activo.
3. Clonado del repositorio y construcción de la imagen.
4. Creación de la red Docker.
5. Carga de las variables de entorno.
6. Creación e inicio del contenedor del servicio.
7. Generación del `nginx.conf` y arranque del proxy inverso.
8. Validación del servicio y del proxy.

`script-ngrok.sh` añade además:

9. Instalación de ngrok y registro del token.
10. Apertura del túnel.
11. Validación de la publicación externa.
12. Presentación de la URL pública generada.

Los scripts son reejecutables: eliminan los contenedores previos con el mismo
nombre y reutilizan la red y el código ya clonado.

## Archivos generados

En `~/despliegue-<servicio>/`:

| Archivo | Contenido |
| --- | --- |
| `src/` | Código clonado del servicio |
| `.env` | Variables de entorno (permisos `600`) |
| `nginx.conf` | Configuración del proxy inverso |
| `ngrok.log` | Log del agente de ngrok (solo `script-ngrok.sh`) |

## Verificación

```bash
docker ps                              # contenedores activos
docker logs -f <servicio>-app          # logs de la aplicación
docker logs -f <servicio>-nginx        # logs del proxy
curl -I http://127.0.0.1:<puerto-proxy>
```

Solo en el escenario con ngrok:

```bash
curl http://127.0.0.1:4040/api/tunnels # estado del túnel y URL pública
```

El agente de ngrok expone también una interfaz web en `http://localhost:4040`
donde se ve cada petición entrante con sus cabeceras: es la evidencia más
directa de que la solicitud externa pasó por ngrok antes de llegar a Nginx.

Las cabeceras `X-Real-IP`, `X-Forwarded-For` y `X-Forwarded-Proto` que añade
Nginx permiten evidenciar el salto por el proxy inverso.

## Detener el despliegue

```bash
docker rm -f <servicio>-app <servicio>-nginx
docker network rm <servicio>-net
```

Y, en el escenario con ngrok:

```bash
pkill -f 'ngrok http'
```

## Notas

- Los scripts funcionan tanto como `root` como con `sudo`; detectan el caso y
  omiten `sudo` cuando ya son root, ya que en entornos como Killercoda `sudo`
  puede no estar instalado.
- Si el puerto del proxy ya está ocupado, avisan antes de continuar.
- Con la cuenta gratuita de ngrok el navegador muestra una página intermedia
  de advertencia la primera vez. La validación interna del script la evita
  con la cabecera `ngrok-skip-browser-warning`.
- ngrok permite un solo túnel simultáneo en el plan gratuito; el script cierra
  cualquier agente anterior antes de abrir el suyo.
