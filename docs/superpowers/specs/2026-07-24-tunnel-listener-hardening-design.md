# Diseño: Endurecimiento del listener del túnel IAP (minimizar ventana) — seguridad

**Fecha:** 2026-07-24
**Rama:** `security/loopback-listener`
**Estado:** Aprobado

## Objetivo

Reducir la ventana de exposición del túnel IAP local frente a un proceso del **mismo UID** (amenaza T1 del threat model). El túnel es un puerto TCP en loopback al que conectan clientes externos (RDP/VNC) y los consumidores internos (terminal SSH, SFTP). TCP en loopback **no tiene ACL por proceso**, así que cualquier proceso del mismo UID puede conectar al puerto autenticado mientras esté abierto. Como el aislamiento fuerte (network namespace) es pesado y probablemente privilegiado, y la ofuscación (aleatorizar IP/puerto) es **teatro** contra un atacante que enumera sockets con `ss`/`/proc/net/tcp`, el alcance de v1 es **minimizar el tiempo de vida del túnel** y **documentar honestamente el residual** — sin teatro.

## Contexto del código actual

- Motor por defecto (y único en `main`): **gcloud**. `start_tunnel` (`native/src/tunnel.rs:73`) elige un puerto libre con `get_free_port()` (`:296`, bind efímero a `127.0.0.1:0`, lo suelta) y lanza `gcloud compute start-iap-tunnel … --local-host-port=localhost:PORT` (`:97`). **Es gcloud quien bindea y sirve el socket**; LCC no controla el listener y gcloud no ofrece socket Unix ni auth por conexión.
- Estado global `TUNNELS: Mutex<HashMap<String, IapTunnel>>` (`:65`). `start_tunnel` es idempotente (reusa el túnel existente). `stop_tunnel(instance, remote_port)` (`:175`) mata el proceso gcloud (SIGKILL vía `IapTunnel::drop`/`kill`) y lo quita del mapa.
- **`stop_tunnel` solo se llama desde el lado Dart** (`native/src/api.rs:194`, `disconnect`). No hay idle-timeout, reaper, ni conteo de conexiones. Para clientes externos (RDP/VNC) LCC **no ve** cuándo cierra el cliente, así que un túnel puede quedar abierto mucho más de lo necesario.
- El motor nativo (que sí permitiría a LCC controlar el socket) vive en `feature/native-iap-tunnel`, sin mergear — fuera de esta base.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Aislamiento fuerte (network namespace) | **Fuera de v1** (pesado, privilegios; documentado como futuro, ligado al motor nativo) |
| Aleatorizar dirección/puerto loopback | **Rechazado** — teatro contra enumeración same-UID |
| Mecanismo v1 | **Reaper de túneles inactivos** (cerrar túneles sin conexión establecida) + cierre en fallo de lanzamiento + documentación |
| `IDLE_TIMEOUT` | **120 s** sin ninguna conexión establecida → cerrar |
| `POLL_INTERVAL` del reaper | **30 s** |
| Criterio de "en uso" | ≥1 conexión TCP **ESTABLISHED** en loopback que involucre el puerto (una sesión viva la mantiene aunque esté inactiva) |

## 1. Reaper de túneles inactivos

Un hilo en segundo plano (arrancado una sola vez, de forma perezosa al crear el primer túnel) recorre `TUNNELS` cada `POLL_INTERVAL` (30 s):

- Cada `IapTunnel` gana un campo `last_active: std::time::Instant`, inicializado a `Instant::now()` al crearse (esto da a un túnel recién creado una gracia completa de `IDLE_TIMEOUT` para recibir su primera conexión).
- En cada pasada, para cada túnel se comprueba si su `local_port` tiene **alguna conexión establecida** en loopback (ver §1.1). Si la hay → `last_active = Instant::now()`.
- Si `now - last_active > IDLE_TIMEOUT` (120 s) → se cierra ese túnel (`stop_tunnel`-equivalente: kill + quitar del mapa) y se registra en el log el motivo (`idle reap`).

**Seguridad sin romper UX:** una sesión RDP/VNC/SSH/SFTP viva mantiene su conexión TCP en `ESTABLISHED` aunque no fluyan datos, así que el reaper **solo cierra túneles con cero conexiones** — nunca una sesión en uso. Los 120 s toleran huecos breves (p. ej. SFTP que cierra y reabre su sesión libssh2 entre operaciones).

### 1.1 Detección de conexión (núcleo puro y testeable)

Función pura `fn port_has_active_connection(proc_tcp: &str, proc_tcp6: &str, port: u16) -> bool`:
- Parsea el contenido de `/proc/net/tcp` y `/proc/net/tcp6`.
- Devuelve `true` si existe alguna fila en estado **`01` (ESTABLISHED)** cuya dirección **local o remota** tenga como puerto `port` y como dirección una de loopback (`127.0.0.0/8` en v4; `::1` o `::ffff:127.0.0.1` en v6). (Se contempla v6 porque `--local-host-port=localhost:PORT` puede resolver a `::1` según el sistema.)
- Ignora sockets en `LISTEN` (`0A`): el propio gcloud escucha ahí siempre; lo que indica uso es una conexión establecida.

El caller lee los ficheros (`std::fs::read_to_string`) y llama a esta función, de modo que la lógica de parseo se prueba con fixtures sin depender del sistema.

Función pura `fn should_reap(last_active: Instant, now: Instant, idle_timeout: Duration) -> bool` → `now.duration_since(last_active) > idle_timeout`.

## 2. Cierre en fallo de lanzamiento

Cuando LCC abre un túnel y el lanzamiento del cliente externo (RDP/VNC) o la conexión interna fallan, cerrar el túnel **de inmediato** (best-effort) en vez de esperar al reaper. Se audita el camino de lanzamiento; donde la estructura lo permita (el código que abre el túnel y luego lanza) se añade el `stop_tunnel` en el error. El reaper es la **red de seguridad** si algún camino se escapa.

## 3. Documentación honesta (threat model)

Actualizar `docs/THREAT_MODEL.md` T1 con el razonamiento preciso:
- **gcloud es dueño del socket** (motor por defecto): LCC no puede inyectar socket Unix ni auth por conexión.
- La **enumeración same-UID** (`ss`, `/proc/net/tcp`) derrota cualquier ofuscación de IP/puerto → no se aleatoriza (sería teatro).
- El **network namespace** es el único control fuerte real y queda **fuera de v1** (pesado, probablemente privilegios; candidato futuro ligado al motor nativo).
- El residual queda **acotado** por el reaper (`IDLE_TIMEOUT` 120 s) + la vida mínima del túnel + el cierre en fallo de lanzamiento.

## 4. Verificación

- **Unit (Rust):** `port_has_active_connection` con fixtures de `/proc/net/tcp` y `/proc/net/tcp6` — casos: puerto con fila ESTABLISHED (loopback v4) → `true`; solo LISTEN → `false`; puerto ausente → `false`; ESTABLISHED en tcp6 (`::1`) → `true`; puerto distinto → `false`. Y `should_reap` con `last_active`/`now`/`timeout`.
- **Manual (QA):** abrir un túnel y **no** conectar ningún cliente → se cierra a los ~120 s (log `idle reap`); abrir una sesión SSH/SFTP/RDP viva y dejarla inactiva > 120 s → **no** se cierra; cerrar el cliente externo → el túnel se reapea en ≤ 150 s; el ref-count/disconnect explícito sigue cerrando de inmediato como hoy.
- No debe haber deadlock entre el reaper y `start_tunnel`/`stop_tunnel` (todos toman brevemente el lock de `TUNNELS`).

## Fuera de alcance

- **Network namespace** / aislamiento real del listener (futuro, probablemente con el motor nativo).
- **Aleatorizar** la dirección/puerto loopback (teatro contra same-UID).
- Cambiar el motor por defecto o el mecanismo de túnel.
- Rastrear el ciclo de vida del proceso cliente externo (LCC no lo controla; el reaper por conexión es el sustituto).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| El reaper cierra una sesión viva por error | Solo cierra túneles con **cero** conexiones ESTABLISHED; una sesión viva mantiene la conexión; 120 s de margen para huecos |
| Parseo frágil de `/proc/net/tcp` | Lógica pura testeada con fixtures (v4/v6, ESTABLISHED/LISTEN/ausente) |
| Deadlock reaper ↔ start/stop | Secciones críticas cortas; el reaper no mantiene el lock mientras mata procesos largos (recolecta ids/puertos bajo lock, actúa fuera si hace falta) |
| Un cliente lento en conectar tras el lanzamiento se reapea | La gracia inicial de 120 s desde la creación cubre el arranque del cliente |
| `/proc/net/tcp` no existe (no-Linux) | LCC es Linux (host); en su ausencia el reaper trata "sin datos" de forma conservadora (no reapear) para no cerrar túneles en uso |
