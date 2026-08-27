# Script de despliegue: Docker + Nginx (proxy inverso) + ngrok

Script de automatización para desplegar y publicar un servicio de software
en un entorno Linux limpio (Killercoda, Ubuntu o Debian).

Todos los datos del despliegue se solicitan durante la ejecución, por lo que
el mismo script sirve para cualquier servicio que disponga de un `Dockerfile`.
No hay rutas, puertos, nombres ni credenciales escritos en el código.

## Arquitectura

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

## Requisitos

- Ubuntu / Debian / Killercoda, como `root` o con un usuario con `sudo`.
- Conexión a Internet.
- Un repositorio git con el código del servicio y su `Dockerfile`.
- Una cuenta de ngrok y su token de autenticación
  (https://dashboard.ngrok.com/get-started/your-authtoken).

Docker, Docker Compose y ngrok los instala el propio script si no están.

## Uso

```bash
git clone https://github.com/Juan-Chala-123/script-carrito.git
cd script-carrito
chmod +x script.sh
./script.sh
```

## Datos que solicita

### Del servicio

| Dato | Ejemplo | Por defecto |
| --- | --- | --- |
| Nombre del servicio | `carrito` | — |
| URL del repositorio git | `https://github.com/tadeo77789/carrito.git` | — |
| Ruta del Dockerfile dentro del repo | `.` o `backend` | `.` |
| Nombre de la imagen Docker | `carrito:latest` | `<servicio>:latest` |
| Nombre del contenedor | `carrito-app` | `<servicio>-app` |
| Puerto interno de la aplicación | `8080` | `8080` |
| Puerto del proxy inverso | `80` | `80` |

### Variables de entorno

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

### De ngrok

| Dato | Notas |
| --- | --- |
| Token de autenticación | Se digita **oculto** (`read -s`); no se muestra ni se registra |
| Puerto a publicar | Por defecto, el del proxy inverso |
| Dominio reservado | Opcional; con Enter se usa un dominio aleatorio |

El token nunca se escribe en el código ni en el `.env`. Se entrega a
`ngrok config add-authtoken`, que lo almacena en la configuración del usuario,
y se borra de memoria con `unset` inmediatamente después.

## Qué automatiza

1. Validación de dependencias e instalación de Docker y ngrok.
2. Arranque del demonio de Docker si no está activo.
3. Clonado del repositorio y construcción de la imagen.
4. Creación de la red Docker.
5. Carga de las variables de entorno.
6. Creación e inicio del contenedor del servicio.
7. Generación del `nginx.conf` y arranque del proxy inverso.
8. Registro del token e inicio del túnel de ngrok.
9. Validación del servicio, del proxy y de la publicación externa.
10. Presentación de la URL pública generada.

El script es reejecutable: elimina los contenedores previos con el mismo
nombre y reutiliza la red y el código ya clonado.

## Archivos generados

En `~/despliegue-<servicio>/`:

| Archivo | Contenido |
| --- | --- |
| `src/` | Código clonado del servicio |
| `.env` | Variables de entorno (permisos `600`) |
| `nginx.conf` | Configuración del proxy inverso |
| `ngrok.log` | Log del agente de ngrok |

## Verificación

```bash
docker ps                              # contenedores activos
docker logs -f <servicio>-app          # logs de la aplicación
docker logs -f <servicio>-nginx        # logs del proxy
curl http://127.0.0.1:4040/api/tunnels # estado del túnel y URL pública
```

El flujo completo se comprueba accediendo a la URL pública: la petición entra
por ngrok, pasa por Nginx y llega al contenedor del servicio. Las cabeceras
`X-Real-IP`, `X-Forwarded-For` y `X-Forwarded-Proto` que añade Nginx permiten
evidenciar el salto por el proxy.

## Detener el despliegue

```bash
pkill -f 'ngrok http'
docker rm -f <servicio>-app <servicio>-nginx
docker network rm <servicio>-net
```

El túnel de ngrok se mantiene activo mientras la terminal siga abierta.

## Notas

- El script funciona tanto como `root` como con `sudo`; detecta el caso y
  omite `sudo` cuando ya es root, ya que en entornos como Killercoda `sudo`
  puede no estar instalado.
- Si el puerto del proxy ya está ocupado, avisa antes de continuar.
- Con la cuenta gratuita de ngrok el navegador muestra una página intermedia
  de advertencia la primera vez. La validación interna del script la evita
  con la cabecera `ngrok-skip-browser-warning`.
