# Diseño: SFTP de doble panel (local/remoto) con cola de transferencias — 27H1

**Fecha:** 2026-07-24
**Rama:** `27H1`
**Estado:** Aprobado

## Objetivo

Convertir la pestaña SFTP del workspace en un gestor de ficheros de **doble panel estilo WinSCP**: panel local (izquierda) y remoto (derecha) lado a lado, con **arrastrar y soltar entre ellos** (subida/descarga) y un **toggle a la vista clásica** (solo remoto, la de hoy). Añade una **cola de transferencias** con progreso por item y **cancelar/reintentar reales**, incluida la cancelación a media transferencia — que hoy no existe (la cancelación en Rust solo ocurre ante fallo de un hilo hermano).

## Contexto del código actual

- La `SftpTab` (`lib/src/features/workspace/sftp_tab.dart`) monta `SftpBrowserBody` contra `localhost:<puertoTúnel>` una vez el túnel IAP está listo.
- `SftpBrowserBody` / `SftpBrowserNotifier` (`lib/src/features/sftp_browser.dart`, ~1500 líneas) es un navegador **remoto de una sola operación**: `SftpBrowserState` tiene un único `operationInProgress` (label) + `progress` (double). Operaciones existentes: `navigateTo`, `refresh`, `uploadFile`/`uploadFolder`/`uploadFiles`, `downloadFile`, `createDirectory`, `deleteEntry`, preview (texto/imagen). No hay rename remoto.
- Motor de transferencia (`native/src/sftp.rs`): `sftp_upload_file_parallel` y `sftp_download_file_parallel` transfieren por **rangos en paralelo** (K=2 por defecto) con progreso por `StreamSink<SftpProgress>`. Ambas tienen un `cancel: Arc<AtomicBool>` **interno** que los hilos ya consultan (`if cancel.load(...) { return Err(...) }`), pero solo se activa ante fallo de un hilo hermano; **no está expuesto a Dart**. El fichero parcial se borra ante error.
- No existe ningún concepto de sistema de ficheros **local** en la app (lo local hoy es solo `XFile` de drag-drop o file picker).
- Bridge flutter_rust_bridge 2.11.1. Regla conocida: tras cambiar `api.rs` hay que regenerar el bridge y **recompilar Rust debug Y release** (la app carga la `.so` de release).

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Cancelación | **Completa**: cancelar items en cola (Dart) y el fichero en curso (token de cancelación nuevo en Rust) |
| Concurrencia de la cola | **Secuencial**: un fichero a la vez; cada fichero usa el motor paralelo interno (K=2) |
| Vista por defecto | **Dual** (local izq. / remoto der.), con toggle a la vista **clásica** (solo remoto) |
| Panel local | **Navegar + origen/destino de arrastre**; sin mutaciones locales (mkdir/borrar/rename los hace el gestor del SO) |
| Ubicación de la cola | **Cajón inferior acoplado**, a lo ancho, colapsable |
| Granularidad de la cola | **Un item por fichero**; las carpetas se expanden a sus ficheros (los directorios se crean primero en destino) |
| Conflicto de sobrescritura | **Un diálogo por lote**: Sobrescribir todo / Omitir existentes / Cancelar |
| Persistencia de la cola | **En memoria, por `SftpTab`**; se pierde al cerrar la pestaña (sin persistencia entre reinicios) |

## 1. Arquitectura y componentes

Nuevo módulo `lib/src/features/sftp/`:

- **`sftp_dual_view.dart`** — `SftpDualView`: el contenedor que reemplaza a `SftpBrowserBody` como cuerpo de la `SftpTab`. Estructura: barra de herramientas (toggle **Dual | Clásico**, refrescar, inicio, contador de cola) + un `Row(LocalPane | divisor | SftpBrowserBody)` + el `TransferQueueDrawer` inferior colapsable. En modo **clásico** oculta el `LocalPane` y el divisor y muestra solo el `SftpBrowserBody` (comportamiento idéntico al de hoy). El modo se guarda en estado local del widget (dual por defecto).
- **`local_pane.dart`** — `LocalPane`: navegador del sistema de ficheros local con `dart:io` (`Directory.list`), barra de ruta con breadcrumb, `..` para subir, doble-click para entrar en carpetas. Es origen de arrastre (`Draggable`) y destino de soltado (`DragTarget`). Arranca en el home del usuario. Sin mutaciones.
- **Panel remoto** = se **reutiliza `SftpBrowserBody` sin cambios de comportamiento**; se le añade solo la capacidad de ser origen/destino de arrastre (envolver sus filas en `Draggable`/`DragTarget`). El navegador, mkdir, borrar, preview y navegación se conservan. **Los botones actuales de la barra (subir fichero/carpeta, descargar) siguen funcionando como hoy** (una operación directa, con su banner) en ambas vistas; **solo el camino nuevo de arrastrar-y-soltar pasa por la cola** (§2). Esto evita tocar la lógica del `SftpBrowserNotifier` y mantiene el riesgo acotado.
- **`transfer_queue_provider.dart`** — el `TransferQueueNotifier` + los modelos (§2).
- **`transfer_queue_drawer.dart`** — `TransferQueueDrawer`: la UI de la cola (§2).

La `SftpTab` cambia una línea: renderiza `SftpDualView(host, port, username, instanceName)` en vez de `SftpBrowserBody(...)`. `SftpBrowserBody` permanece en `sftp_browser.dart`.

## 2. Cola de transferencias

Modelos (en `transfer_queue_provider.dart`):

```dart
enum TransferDirection { upload, download }
enum TransferStatus { queued, active, done, failed, cancelled }

class TransferItem {
  final int id;                 // id monótono, también es el transfer_id de Rust
  final String localPath;
  final String remotePath;
  final TransferDirection direction;
  final int sizeBytes;
  final TransferStatus status;
  final int transferred;        // bytes transferidos (para la barra)
  final String? error;
  // + copyWith
}
```

`TransferQueueNotifier` (`NotifierProvider`, **una instancia por `SftpTab`** — se crea junto al `SftpDualView`, en memoria) mantiene `List<TransferItem>` y un flag `bool _running`. API:

- `enqueue(List<TransferItem> items)` — añade items `queued` al final y arranca el worker si no corría.
- `cancel(int id)` — si el item está `queued`: se marca `cancelled` (el worker lo salta). Si está `active`: llama `sftpCancelTransfer(id)` (bridge, §3); el stream terminará en error y el worker lo marcará `cancelled`.
- `retry(int id)` — un item `failed`/`cancelled` vuelve a `queued` (al final) y arranca el worker.
- `clearCompleted()` — elimina los `done`.
- `hasActiveTransfers` — hay algún item `queued` o `active` (lo usa el guard de cierre).

**Worker secuencial** (`_run`): mientras haya un item `queued`, toma el primero, lo marca `active`, elige `sftpUploadParallel` o `sftpDownloadParallel` (con `transferId: item.id` y el `StreamSink<SftpProgress>`), consume el stream actualizando `transferred`, y al completar marca `done`; ante error, si fue cancelación → `cancelled`, si no → `failed` con el mensaje. Luego pasa al siguiente. Los directorios de destino de un lote se crean **antes** de encolar sus ficheros (§4).

## 3. Cancelación real en Rust + bridge

En `native/src/sftp.rs`:

- **Registro global**: `static CANCELLATIONS: Lazy<Mutex<HashMap<u64, Arc<AtomicBool>>>>`.
- **Helpers**: `fn register_cancel(id: u64) -> Arc<AtomicBool>` (inserta un `Arc::new(AtomicBool::new(false))` y lo devuelve), `fn unregister_cancel(id: u64)` (lo quita al terminar).
- `sftp_upload_file_parallel` y `sftp_download_file_parallel` ganan un parámetro `transfer_id: u64`. Al empezar, en vez de crear su `cancel` interno lo obtienen de `register_cancel(transfer_id)`; los hilos ya consultan ese flag (código actual). Al terminar (éxito o error), `unregister_cancel(transfer_id)`. La limpieza del fichero parcial (ya presente ante error) cubre también la cancelación, porque cancelar produce un `Err`.
- Nueva función pública **`sftp_cancel_transfer(transfer_id: u64)`**: bloquea el mutex, y si existe el id pone su `AtomicBool` a `true`. No-op si el id ya no está (transferencia ya terminada).

En `native/src/api.rs`: exponer `sftp_upload_parallel`/`sftp_download_parallel` con el nuevo `transfer_id` y una wrapper `sftp_cancel_transfer(transfer_id: u64)`.

Dart genera el `id` con un contador monótono en el `TransferQueueNotifier`. Tras el cambio: regenerar el bridge y **recompilar Rust debug y release**.

## 4. Panel local, arrastre y conflictos

- **Dirección del arrastre**: local→remoto = **subida**, remoto→local = **descarga**. Soltar sobre una **fila de carpeta** = dentro de esa carpeta; soltar sobre el fondo del panel = el directorio actual de ese panel. Sin arrastre dentro del mismo panel en v1.
- **Carpetas**: al encolar un directorio se enumera recursivamente; se **crean primero los subdirectorios en destino** (remoto con `sftp_create_directory`; local con `Directory.create`) ordenados padre→hijo, y luego se encola **un item por fichero**. El `sizeBytes` de cada item se obtiene al enumerar.
- **Conflicto de sobrescritura**: al soltar un lote, antes de encolar se listan los nombres existentes en el directorio destino (remoto: `sftp_list_directory`; local: `Directory.list`). Si hay colisiones, **un solo diálogo por lote**: *Sobrescribir todo* (encola todo), *Omitir existentes* (no encola los que chocan), *Cancelar* (no encola nada). No hay prompt por fichero.
- **Cierre con transferencia activa**: el guard de cierre de la app (`window_manager`, feature del workspace) ya cuenta la SFTP como sesión viva. Al cerrar la pestaña o la app con `hasActiveTransfers`, se cancela la transferencia en curso (`sftpCancelTransfer`, que borra el parcial) antes de destruir.

## 5. i18n

Claves nuevas en ambos `.arb` (paridad EN/ES, registro neutro, elipsis `…`, append-only, `@key` solo en EN): toggle Dual/Clásico, cabeceras "Local"/"Remoto", etiquetas de la cola (título, "en espera", "hecho", "error", cancelar, reintentar, limpiar completadas, pausar), direcciones subida/descarga, y el diálogo de conflicto (título + Sobrescribir todo / Omitir existentes / Cancelar) con placeholder para el nombre/conteo si hace falta.

## 6. Verificación

- **Unit Rust** (`native/src/sftp.rs`): el registro de cancelación — `register_cancel`/`unregister_cancel` (insertar/quitar), `sftp_cancel_transfer` pone el flag a `true`, id inexistente es no-op, y un bucle de trabajo simulado que consulta el token aborta al activarlo.
- **Unit Dart** (`TransferQueueNotifier`, con una función de transferencia falsa inyectada): encolar añade items `queued`; el worker procesa **secuencialmente** (item N+1 no empieza hasta que N termina); `cancel` de un `queued` lo salta sin llamar al bridge; `cancel` de un `active` invoca `sftpCancelTransfer(id)`; `retry` re-encola un `failed`; la resolución de conflicto *omitir* no encola los que chocan y *sobrescribir* sí; `hasActiveTransfers` es correcto.
- **Widget test**: `SftpDualView` en modo dual renderiza dos paneles + el cajón de cola; el toggle a clásico oculta el panel local; el cajón lista los items con su estado.
- **QA manual**: arrastrar un fichero local→remoto (subida) y remoto→local (descarga) reales; **cancelar a media transferencia y verificar que el fichero parcial se borra y que el checksum de un fichero completado coincide** (crítico: la escritura posicionada con cancelación no debe corromper); reintentar un item fallido; arrastrar una carpeta (crea dirs + un item por fichero); diálogo de conflicto (sobrescribir/omitir); toggle a clásico y vuelta; ES sin recortes; cerrar la pestaña con transferencia activa la cancela limpiamente.

## Fuera de alcance (diferido)

- Cola **concurrente** (más de un fichero a la vez).
- **Sincronización** de carpetas (comparar y espejar).
- **Editar en sitio** (abrir remoto, editar, re-subir).
- **Reanudar** transferencias interrumpidas (resume).
- **Cola persistente** entre reinicios de la app.
- **Mover/renombrar dentro** de un panel (arrastre intra-panel) y **rename** remoto.
- **Mutaciones de ficheros locales** desde la app (mkdir/borrar/rename local).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Corrupción por cancelar a media escritura posicionada | El borrado del parcial ante `Err` ya existe y cubre la cancelación; QA con checksum del completado y verificación de que el parcial desaparece |
| Registro de cancelación con ids colgados (fugas de memoria) | `unregister_cancel` siempre al terminar (éxito/error/cancelación); test unit de que el mapa queda limpio |
| Reutilizar `SftpBrowserBody` como panel + añadir arrastre lo complica | El arrastre se añade envolviendo filas; la lógica del notifier remoto no se toca; se transfiere **a través de la cola**, no de sus métodos directos |
| Presión de conexiones al encolar carpetas grandes | Cola **secuencial**: solo un fichero (K=2 conexiones) a la vez, sin multiplicar como el pool actual de subida de carpeta |
| El diálogo de conflicto necesita listar el destino (coste/latencia) | Un solo `list` del directorio destino por lote, no un `stat` por fichero |
