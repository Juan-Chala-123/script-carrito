# Scripts de despliegue: Docker Compose + Nginx (proxy inverso) + ngrok

Actividad de aprendizaje: despliegue y publicación de un servicio mediante
Docker, proxy inverso y ngrok.

Los scripts levantan el `docker-compose.yml` que trae el propio repositorio del
servicio y colocan delante un **Nginx que actúa como único punto de entrada**:

```text
/        ->  contenedor del frontend
/api/    ->  contenedor del backend
```

El repositorio contiene **dos scripts**, uno por escenario:

| Script | Escenario | Publicación externa |
| --- | --- | --- |
| `script-ngrok.sh` | Máquina virtual local | Sí, mediante ngrok |
| `script-killercoda.sh` | Killercoda | No |

Ambos son parametrizables: todos los datos se solicitan durante la ejecución,
por lo que sirven para cualquier proyecto que tenga un `docker-compose.yml`.
No hay rutas, puertos, nombres ni credenciales escritos en el código.

## Arquitectura

### Escenario 1 — máquina virtual local (`script-ngrok.sh`)

```text
                 INTERNET
                     │
                     ▼
                  ngrok                  túnel público
                     │
                     ▼
              ┌──────────────┐
              │    Nginx     │           único punto de entrada
              │ Proxy inverso│
              └──┬────────┬──┘
            /    │        │   /api/
                 ▼        ▼
         ┌───────────┐  ┌──────────┐
         │ frontend  │  │ backend  │──┐   red creada por Compose
         └───────────┘  └──────────┘  │
                                      ▼
                                 ┌─────────┐
                                 │   db    │
                                 └─────────┘
```

### Escenario 2 — Killercoda (`script-killercoda.sh`)

Idéntico, sin la capa de ngrok. Para acceder desde el navegador se usa el menú
**Traffic / Ports** de la interfaz de Killercoda, seleccionando el puerto del
proxy inverso.

## Por qué un único punto de entrada

Es lo que hace que la aplicación funcione a través de la URL pública. Si el
frontend llamara a la API en un host y puerto absolutos (`http://<host>:3000`),
al abrirlo por `https://…ngrok-free.app` el navegador intentaría alcanzar un
puerto que no está en el túnel, y además bloquearía la petición por contenido
mixto (`https` → `http`).

Con el proxy delante, el frontend pide `/api/...` al **mismo origen** y es
Nginx quien decide a qué contenedor va cada ruta.

## Requisitos

- Ubuntu / Debian / Killercoda, como `root` o con un usuario con `sudo`.
- Conexión a Internet.
- Un repositorio git con el servicio y su `docker-compose.yml`.
- Solo para `script-ngrok.sh`: cuenta de ngrok y su token de autenticación
  (https://dashboard.ngrok.com/get-started/your-authtoken).

Docker, Docker Compose y ngrok los instalan los propios scripts si no están.

Si la máquina ya trae Docker —como los entornos de Killercoda— la instalación
se omite y el despliegue arranca en segundos. Y si trae Docker pero de una
versión anterior a `docker compose`, se instala **solo el plugin de Compose**
descargando su binario, sin reinstalar Docker ni pasar por `apt`: son unos
segundos en lugar de varios minutos.

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

### Del despliegue (ambos scripts)

| Dato | Por defecto | Para `carrito` |
| --- | --- | --- |
| Nombre del proyecto | `carrito` | `carrito` |
| URL del repositorio | — | `https://github.com/tadeo77789/carrito.git` |
| Ruta del `docker-compose.yml` dentro del repo | `.` | `.` |
| Puerto del proxy inverso | `80` | `80` |
| Servicio del frontend | `frontend` | `frontend` |
| Puerto interno del frontend | `80` | `80` |
| Servicio del backend | `backend` | `backend` |
| Puerto interno del backend | `3000` | `3000` |
| Prefijo de las rutas del backend | `/api/` | `/api/` |

Los nombres de servicio son los que aparecen bajo `services:` en el
`docker-compose.yml`. Los nombres reales de los contenedores y de la red los
descubre el script consultando a Compose, porque llevan el prefijo del
proyecto.

Si el proyecto no tiene frontend, se deja ese campo vacío y Nginx enruta `/`
al backend.

### Variables de entorno (ambos scripts)

Se introducen en formato `CLAVE=VALOR`, una por línea, y se termina con una
línea vacía. Se escriben en un `.env` junto al `docker-compose.yml`, con
permisos `600`, que Compose lee automáticamente.

Para `carrito`:

```text
DB_USER=admin
DB_PASSWORD=unaClaveSegura
DB_NAME=tienda
```

Si no se introduce ninguna, se usan los valores por defecto del
`docker-compose.yml`.

### De ngrok (solo `script-ngrok.sh`)

| Dato | Notas |
| --- | --- |
| Token de autenticación | Se digita **oculto** (`read -s`); no se muestra ni se registra |
| Puerto a publicar | Por defecto, el del proxy inverso |
| Dominio reservado | Opcional; con Enter se usa un dominio aleatorio |

El token nunca se escribe en el código ni en ningún archivo del repositorio.
Se entrega a `ngrok config add-authtoken`, que lo almacena en la configuración
del usuario, y se borra de memoria con `unset` inmediatamente después.

Los datos de ngrok se piden al principio, junto con los del despliegue, para
que el resto del proceso corra sin intervención.

## Qué automatizan

Pasos comunes a los dos scripts:

1. Validación de dependencias e instalación de Docker y Docker Compose.
2. Arranque del demonio de Docker si no está activo.
3. Clonado del repositorio del servicio.
4. Escritura del `.env` con las variables de entorno.
5. `docker compose up -d --build` de todos los servicios.
6. Descubrimiento de los nombres reales de contenedores y de la red.
7. Generación del `nginx.conf` y arranque del proxy inverso en esa red.
8. Validación del proxy y del backend a través del proxy.

`script-ngrok.sh` añade además:

9. Instalación de ngrok y registro del token.
10. Apertura del túnel y validación de la publicación externa.
11. Presentación de la URL pública generada.

Los scripts son reejecutables: recrean el contenedor del proxy y reutilizan
el código ya clonado.

## Archivos generados

En `~/despliegue-<proyecto>/`:

| Archivo | Contenido |
| --- | --- |
| `src/` | Código clonado del servicio |
| `src/.env` | Variables de entorno (permisos `600`) |
| `nginx.conf` | Configuración del proxy inverso |
| `ngrok.log` | Log del agente de ngrok (solo `script-ngrok.sh`) |

## Verificación

```bash
docker compose -p <proyecto> ps        # contenedores del servicio
docker compose -p <proyecto> logs -f   # logs de la aplicación
docker logs -f <proyecto>-proxy        # logs del proxy inverso
curl -i http://127.0.0.1:<puerto>/api/productos
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
docker rm -f <proyecto>-proxy
docker compose -p <proyecto> -f ~/despliegue-<proyecto>/src/docker-compose.yml down
```

Y, en el escenario con ngrok:

```bash
pkill -f 'ngrok http'
```

## Notas

- Los scripts funcionan tanto como `root` como con `sudo`; detectan el caso y
  omiten `sudo` cuando ya son root, ya que en entornos como Killercoda `sudo`
  puede no estar instalado.
- Si otro proceso de `apt` está en ejecución —habitual en una máquina recién
  arrancada—, esperan a que termine en lugar de fallar con
  «Could not get lock /var/lib/dpkg/lock-frontend».
- Si el puerto del proxy ya está ocupado, avisan antes de continuar.
- Con la cuenta gratuita de ngrok el navegador muestra una página intermedia
  de advertencia la primera vez. La validación interna del script la evita
  con la cabecera `ngrok-skip-browser-warning`.
- ngrok permite un solo túnel simultáneo en el plan gratuito; el script cierra
  cualquier agente anterior antes de abrir el suyo.
