# Diseño: SSH Port Forward (sub-proyecto B de Custom Tunnel)

**Fecha:** 2026-08-05
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature nueva (Rust: proceso gestionado; Dart: modo + routing; bridge: regen). Parte B de dos (A = diagnostics, ya hecho).

## Objetivo

IAP TCP forwarding no alcanza servicios ligados solo a `127.0.0.1` en la VM (IAP conecta a la IP interna). El **reenvío de puertos por SSH** sí: `gcloud compute ssh INSTANCE -- -L <local>:localhost:<remote> -N` porque `localhost` se resuelve **dentro** de la VM. Este trabajo añade un modo **"Reenvío SSH"** al diálogo Custom Tunnel que lanza y gestiona ese forward como un túnel más, reusando la UX y la infra del sub-proyecto A.

## Contexto

- **A (hecho):** el botón Custom Tunnel ya muestra el puerto local en éxito (+ Copiar) y un diálogo de error (con `localizedError`, detalle real de gcloud y botón Doctor). B reutiliza esa UX.
- **Precedente SSH:** la terminal SSH usa túnel IAP a :22 + cliente `ssh` por PTY; `gcloud.rs` ya invoca `gcloud compute ssh` (para terminal externa). SFTP usa `ssh2`/libssh2 nativo (`Session`, `userauth_*`) sobre el túnel IAP — base del trabajo futuro.
- **Gestión de túneles:** `start_gcloud` + `TUNNELS: Mutex<HashMap<String, IapTunnel>>` + `get_free_port` + el reaper backend-agnóstico. B se apoya en todo esto.

## Decisiones

| Decisión | Elección |
|---|---|
| Mecanismo | **`gcloud compute ssh … -- -L … -N`** como `Child` gestionado (Enfoque 1), fuerza `--tunnel-through-iap` |
| UI | Un **selector de modo** en el diálogo Custom Tunnel: "Directo (IAP)" (default) vs "Reenvío SSH" |
| Puerto local | Auto-asignado (`get_free_port`), mostrado como en A |
| Gestión | Registrado en `TUNNELS` como `IapTunnel{ Backend::Gcloud(child) }`, con **clave con prefijo de modo** (`sshfwd:instance:remote_port`) para coexistir con IAP |
| Reaper / stop / health | Reutilizados sin cambios (operan sobre `IapTunnel`/`local_port`, agnósticos de la clave) |
| Bridge | Nuevas fns `start_ssh_forward` + `stop_ssh_forward` → **regen del bridge** |
| Feedback | Reusa la UX de A; en modo SSH forward se **suprime** la pista de localhost (el forward ya es la solución) |
| Trabajo futuro | Migrar a forward **nativo `ssh2`** para quitar la dependencia de gcloud (documentado) |

## Diseño

### 1. UX — modo en el diálogo Custom Tunnel (`overview_tab.dart`)

- El diálogo (`_showCustomTunnelDialog`) gana un selector de modo arriba (dos opciones): **Directo (IAP)** (por defecto) y **Reenvío SSH** con la línea *"Para servicios que escuchan solo en 127.0.0.1 en la VM (IAP no los alcanza)."*
- El diálogo pasa a devolver **puerto + modo** (hoy solo `Future<int?>`): un pequeño record/objeto `({int port, bool sshForward})?`.
- El handler del botón enruta según el modo:
  - **Directo** → `connect(...)` (camino IAP actual).
  - **Reenvío SSH** → nuevo camino que llama a la fn de reenvío SSH.
- **Éxito/fallo:** idénticos a A (SnackBar "Túnel listo en 127.0.0.1:<local>" + Copiar; diálogo de error con `localizedError` + detalle + Doctor). En modo SSH forward, `isBackendUnreachable`/la pista de localhost **no** se muestra.

### 2. Rust — `start_ssh_forward` (`native/src/tunnel.rs`)

Nueva función que refleja `start_gcloud`:
- `let local = get_free_port()?;`
- Spawn `Child`: `gcloud compute ssh <instance> --tunnel-through-iap --zone=<zone> --project=<project> -- -L <local>:localhost:<remote> -N`, `stdout=null`, `stderr=piped`; `child.stderr.take()` para el handle.
- Construye `IapTunnel { local_port: local, backend: Backend::Gcloud(child), last_active: now }`.
- Espera de arranque como `start_gcloud`: 1s + `is_process_alive()`; luego bucle de ~10s hasta `is_port_listening()`. En fallo, drena la stderr (`drain_stderr`, de A) y devuelve el error real; en éxito **reengancha** la stderr al hijo (evita SIGPIPE, como en A) y devuelve `Ok(tunnel)`.
- Un helper **puro** construye los args (`ssh_forward_args(instance, zone, project, local, remote) -> Vec<String>`), testeable.

### 3. Clave que distingue IAP vs SSH forward

- Helper `make_ssh_forward_key(instance, remote_port) -> "sshfwd:{instance}:{remote_port}"` (Rust y Dart).
- `start_ssh_forward` inserta bajo esa clave; un IAP y un SSH forward al mismo `instancia:puerto` coexisten en `TUNNELS`.
- El **reaper** itera todas las entradas de `TUNNELS` y reapea por `local_port`/`last_active` — no parsea claves, así que recoge ambos tipos sin cambios. `touch_tunnel_by_local_port` (por puerto local) también es agnóstico.

### 4. API / bridge + Dart

- **Bridge (regen):** `pub fn start_ssh_forward(project, zone, instance, remote_port) -> Result<u16, TunnelFailure>` (misma forma y mapeo de error que `start_connection`) y `pub fn stop_ssh_forward(instance, remote_port) -> Result<()>`.
- **Dart (`ConnectionsNotifier`):** un método para el reenvío SSH (p. ej. `connectSshForward(...)`) con **single-flight** (como `connect`), que llama a `startSshForward`, guarda el estado bajo la clave `sshfwd:…` y expone el puerto local; `disconnect` enruta a `stopSshForward` cuando la clave tiene prefijo `sshfwd:`.
- **Gestor de Túneles:** `parseTunnelKey` reconoce el prefijo; la fila etiqueta **"SSH forward"** para distinguir del IAP.

### 5. Trabajo futuro (documentado)

Sustituir el `gcloud compute ssh -- -L` por un **forward nativo con `ssh2`** sobre el túnel IAP a :22 (como ya hace SFTP: `Session` + `userauth_agent`/`userauth_pubkey_file` + un listener local que abre canales `direct-tcpip` a `localhost:<remote>`), para **eliminar la dependencia de gcloud** en el reenvío. Se anota también en el roadmap del proyecto.

## Verificación

- **Unit (Rust):** `ssh_forward_args(...)` produce exactamente los argumentos esperados (incl. `--tunnel-through-iap`, `-N`, `-L <local>:localhost:<remote>`). `make_ssh_forward_key` con el prefijo.
- **Unit (Dart):** la clave `sshfwd:…` y su `parseTunnelKey`; el routing del modo (el diálogo devuelve el modo correcto).
- **Compilación:** `cargo build` debug+release; regen del bridge additive (`git diff --stat lib/src/bridge/`); `flutter gen-l10n`, `flutter analyze` (0 errores), `flutter test`, `flutter build linux`.
- **QA manual (el objetivo de B):** con un servicio ligado a `127.0.0.1:<puerto>` en la VM (el caso del 8443), elegir **Reenvío SSH** → el túnel se crea, muestra el puerto local, y el cliente conecta al servicio (lo que IAP directo no lograba). Aparece en el Gestor etiquetado "SSH forward"; se puede parar; el reaper lo recoge si queda inactivo.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `gcloud compute ssh` requiere provisión de claves / primer uso lento | Es lo que ya hace la terminal SSH y el comando que le funcionó al usuario; el arranque tolera hasta ~10s como en `start_gcloud`; en fallo se muestra la stderr real (de A) |
| Colisión de clave IAP vs SSH forward al mismo puerto | Prefijo `sshfwd:` en la clave — coexisten |
| Fuga del proceso `ssh -N` si no se gestiona | Registrado en `TUNNELS`: aparece en el Gestor (stop) y el reaper lo recoge si queda inactivo |
| SIGPIPE por cerrar la stderr en éxito | Se reengancha al hijo, igual que el fix de A |

## Fuera de alcance

- El forward **nativo `ssh2`** (trabajo futuro; este spec usa gcloud).
- Elegir el puerto **local** a mano (auto-asignado; posible mejora futura).
- Reenvío **remoto** (`-R`) o dinámico (`-D`); solo `-L`.
