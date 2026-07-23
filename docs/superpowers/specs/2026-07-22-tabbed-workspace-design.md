# Diseño: Workspace de sesiones en pestañas + terminal SSH embebida — 27H1

**Fecha:** 2026-07-22
**Rama:** `27H1`
**Estado:** Aprobado

## Objetivo

Convertir el panel derecho del dashboard —hoy función pura de la VM seleccionada en el sidebar— en un **workspace de pestañas** donde cada pestaña es una sesión (Overview, terminal SSH embebida, o navegador SFTP) que **sobrevive a cambiar la selección del sidebar**. Permite tener varias sesiones SSH a distintas VMs abiertas a la vez, como iTerm/VS Code / IAP Desktop.

## Contexto del código actual

- Raíz del dashboard: `Row(ResourceTree(300px) | VerticalDivider | InstanceDetailPane)` en `lib/main.dart:437`.
- `InstanceDetailPane` (`lib/main.dart:2030`) se reconstruye entero según `multiProjectSelectedInstanceProvider` — este acoplamiento es lo que se elimina.
- SSH hoy lanza `gnome-terminal` externo (`native/src/gcloud.rs:368`) — exclusivo de Linux; la terminal embebida lo reemplaza.
- Túneles: `startConnection`/tunnel manager existentes (`gcloud_provider.dart`), con conteo de salud ya presente.
- `main.dart` tiene 4768 líneas; el workspace nace en su propio módulo, no dentro de él.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Terminal | PTY local (`flutter_pty` 0.4.2) ejecutando el `ssh` del sistema sobre el túnel IAP, renderizado con `xterm` 4.0.0 |
| Tipos de pestaña (v1) | Overview, SSH, SFTP. RDP/VNC siguen lanzando cliente externo |
| Modelo | Sidebar = lanzador; pestañas independientes que persisten al cambiar selección |
| Cierre de app con sesiones vivas | Confirmar ("N sesiones activas, ¿cerrar?"); sin restauración al reabrir |
| Túnel | Compartido por VM con conteo de referencias; se cierra al cerrar la última sesión de esa VM |

## 1. Arquitectura: modelo de sesión

Nuevo módulo `lib/src/features/workspace/`:

- **`workspace_session.dart`** — `WorkspaceSession { String id; SessionType type; ProjectAwareInstance target; String title; }` donde `SessionType = { overview, ssh, sftp }`. El estado vivo por tipo (el `Terminal`+`Pty` de SSH, el notifier del SFTP) cuelga de la propia pestaña/su widget con `key`, no del modelo serializable.
- **`workspace_provider.dart`** — `NotifierProvider<WorkspaceNotifier, WorkspaceState>` con `WorkspaceState { List<WorkspaceSession> sessions; String? activeId; }`. Métodos: `openOverview(vm)`, `openSsh(vm)`, `openSftp(vm)`, `focus(id)`, `close(id)`, `reorder(from, to)`. Reglas de dedup: `openOverview`/`openSftp` para una VM enfocan la pestaña existente si ya hay una; `openSsh` **siempre abre una nueva** (varias terminales a la misma VM son válidas).
- **Conteo de referencias de túnel**: el notifier mantiene `Map<String vmKey, int refs>`. Abrir una sesión SSH/SFTP incrementa; cerrar decrementa; al llegar a 0 se llama `stopConnection` para esa VM. Overview no cuenta.
- **`workspace_panel.dart`** — reemplaza a `InstanceDetailPane` en el `Row` raíz. Estructura: tira de pestañas (arriba, reordenable, con botón × por pestaña) + contenido. **El contenido es un `IndexedStack`** indexado por la pestaña activa: todas las sesiones quedan montadas, solo una visible. Esto es obligatorio (no `TabBarView`, que descarta hijos no visibles y mataría las sesiones).
- El **`ResourceTree`/sidebar** conserva su UI pero un clic en una VM llama `workspace.openOverview(vm)` en vez de mutar el provider de selección. `multiProjectSelectedInstanceProvider` se retira del flujo del panel (puede quedar para resaltar la fila activa).

## 2. Terminal SSH embebida

**`ssh_terminal_tab.dart`** — al montar la pestaña:
1. Asegura el túnel a `(instancia, 22)` vía el tunnel manager existente; obtiene el puerto local. Estados: *conectando túnel* → *lanzando ssh* → *conectado*.
2. `Pty.start('ssh', arguments: ['-p', '$localPort', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=<app_data>/known_hosts', '$user@localhost'])`.
3. Cableado: `pty.output.listen(terminal.write)`; `terminal.onOutput = pty.write`; el `onResize` del `TerminalView` → `pty.resize(rows, cols)`. Resize inicial al tamaño del viewport.

Decisiones:
- **known_hosts propio de la app** + `accept-new`: todas las sesiones son a `localhost:<puerto aleatorio>`, así que las claves de host colisionan entre VMs; un known_hosts dedicado evita el falso "HOST IDENTIFICATION HAS CHANGED". La autenticidad la garantiza IAP (Google valida antes del túnel), igual que hace `gcloud compute ssh`.
- **Usuario**: `getUsername()` (el mismo que usa SFTP). Autenticación por el `ssh` del sistema (agente → `~/.ssh/id_rsa`); no se reimplementa.
- macOS: `flutter_pty` y `xterm` listan macOS, y el `ssh` del sistema existe nativo — este camino porta sin reescribir cliente, y **elimina** la dependencia de `gnome-terminal` que hoy bloquea macOS.

**`sftp_tab.dart`** — reutiliza el `SftpBrowser` existente movido del diálogo a panel de pestaña; usa el mismo túnel del puerto 22 de esa VM.

## 3. Ciclo de vida

- **Cerrar pestaña**: SSH → `pty.kill()` + dispose del `Terminal`; SFTP → cierra su notifier; luego decrementa el ref-count del túnel (cierra el túnel si llega a 0).
- **Caída de sesión SSH** (el proceso `ssh` termina): la terminal muestra la salida y la pestaña pasa a estado "desconectada" con botón **Reconectar** (re-lanza el pty sobre el túnel vivo). No se cierra sola.
- **Fallo de túnel**: estado de error en la pestaña con botón **Reintentar**; nunca una terminal negra silenciosa.
- **Cierre de la app**: `window_manager` con `setPreventClose(true)`; en el intento de cierre, si hay ≥1 sesión SSH o SFTP viva, diálogo de confirmación con el conteo. Overview no cuenta. Sin restauración al reabrir (arranque limpio).

## 4. i18n

Claves nuevas en ambos `.arb` (paridad, registro neutro): títulos/tooltips de pestañas, estados de la terminal (conectando/reconectar/reintentar), y el diálogo de cierre con sesiones activas (`workspaceCloseWithSessions(count)`).

## 5. Dependencias

- Añadir a `pubspec.yaml`: `xterm: ^4.0.0`, `flutter_pty: ^0.4.2`. `window_manager` ya está.
- Riesgo: `xterm` no se actualiza desde hace ~2 años; funciona en Linux/macOS desktop pero es una dependencia poco mantenida. Aceptado para v1; si diera problemas, la alternativa es fijar la versión y parchear localmente.

## 6. Verificación

- **Unit (Dart, sin red)**: `WorkspaceNotifier` — open/focus/close/reorder, dedup (Overview/SFTP enfocan; SSH siempre nueva), y el **ref-count del túnel** (2 SSH + 1 SFTP a una VM = 1 túnel; cerrar 2 deja el túnel; cerrar la 3ª lo cierra). Los `stopConnection`/`startConnection` se mockean.
- **Widget test**: la tira de pestañas renderiza y responde a focus/close; y el crítico — que el `IndexedStack` **mantiene montado** un hijo con key al cambiar de pestaña (garantía de que la sesión no se reconstruye).
- **Manual (checklist)**: SSH a dos VMs a la vez y confirmar ambas vivas al alternar pestañas; teclear/redimensionar en la terminal; cerrar pestaña mata proceso y (si es la última) el túnel; diálogo de cierre de la app; reconexión tras cortar la red; RDP/VNC siguen lanzando cliente externo.

## Fuera de alcance

- Rediseño visual (Connect/Tools/Lifecycle, un acento, filtro segmentado) — proyecto A, aparte, dentro de este esqueleto después.
- RDP/VNC embebidos (requieren cliente de protocolo propio).
- Restauración de sesiones al reabrir la app.
- Pestañas de Diagnóstico / consola serie / Logs.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `IndexedStack` con muchas sesiones = muchas conexiones/terminales vivas | Es el objetivo; el ref-count de túneles evita fugas; sin límite duro en v1 |
| `xterm` poco mantenido | Fijar versión; parche local si hace falta; el modelo PTY es independiente de la librería de render |
| Colisión de known_hosts en localhost | known_hosts propio + `accept-new`; autenticidad delegada a IAP |
| El `ssh` del sistema falta o falla al lanzar | Estado de error explícito en la pestaña con el comando fallido |
| Migrar `InstanceDetailPane`/sidebar toca `main.dart` (4768 líneas) | Extraer a `lib/src/features/workspace/`; el sidebar solo cambia su acción de clic |
