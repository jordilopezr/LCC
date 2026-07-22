# Diseño: Aceleración de transferencias SFTP — 27H1

**Fecha:** 2026-07-22
**Rama:** `27H1`
**Estado:** Aprobado

## Objetivo

Acelerar las transferencias SFTP (subidas **y** descargas) del navegador de archivos, que hoy rinden ~0.7 MB/s sobre el túnel IAP, usando paralelismo de conexiones. Meta: acercarse a K× el techo por conexión (~1.6 MB/s), es decir **≈3–5 MB/s** con K=4.

## Base empírica (benchmark 2026-07-22, `native/examples/transfer_bench.rs`)

Medido contra la VM real `backupmig` por un túnel IAP de gcloud, fichero de 20 MB:

| Método | Velocidad |
|---|---|
| SFTP actual (1 conexión, buffer 128 KB) | 0.73 MB/s |
| SCP legacy (1 conexión) | 1.25 MB/s |
| Canal SSH crudo (1 conexión) — **techo por conexión** | ~1.6 MB/s |
| NumPy en el túnel gcloud | sin efecto |

Conclusiones que fijan el diseño:
- El techo **por conexión** es ~1.6 MB/s (ventana del canal SSH × RTT del túnel). El pipelining en una sola conexión no puede superar eso.
- Cada sesión SSH nueva abre su propia conexión TCP por el túnel, con su propio techo → **el paralelismo de conexiones multiplica el throughput**.
- SCP queda descartado: protocolo deprecado, gana menos que el paralelismo y añadiría un segundo camino de código.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Alcance | Subidas **y** descargas |
| Mecanismo | Transferencias por **rangos en paralelo** (K sesiones SSH, cada una lee/escribe su rango a offset) |
| Progreso de carpeta | **Barra global por bytes** de toda la carpeta + contador de ficheros ("56% — 145/260 MB, 7/12 ficheros") |
| Compatibilidad | La vía actual de 1 conexión se conserva como **fallback** automático |

## 1. Rust — transferencia paralela por rangos

Nuevo código en `native/src/sftp.rs`:

- **Particionado**: función pura `fn split_ranges(size: u64, k: usize) -> Vec<(u64, u64)>` (offset, longitud). Reglas: K=4 por defecto; ficheros **< 8 MB** no se particionan (una conexión; el handshake no compensa); el resto no divisible va al último rango; tamaño 0 → un rango vacío.
- **`sftp_upload_file_parallel(host, port, username, local_path, remote_path, concurrency, sink)`**:
  1. Valida rutas con las funciones existentes (`validate_local_path`, `validate_and_normalize_path`).
  2. Crea el fichero remoto y lo trunca al tamaño final (escritura posicionada requiere el fichero creado).
  3. Lanza K hilos; cada uno abre su **propia** sesión SSH (la autenticación existente: agente → `~/.ssh/id_rsa`), abre el fichero remoto en modo escritura, hace `seek` a su offset y transfiere su rango con buffer de 128 KB.
  4. Progreso: los hilos suman bytes a un `AtomicU64` compartido; el hilo coordinador emite `SftpProgress { transferred, total }` por el `StreamSink` cada ~100 ms (tipo y throttle ya existentes).
  5. Errores: flag atómico de cancelación; si un hilo falla, los demás abortan en su siguiente iteración, se borra el fichero remoto parcial y se devuelve el primer error.
- **`sftp_download_file_parallel(...)`**: simétrica — preasigna el fichero local al tamaño remoto (`set_len`), K hilos leen rangos remotos a offset y escriben posicionado en local. Si falla, se borra el fichero local parcial.
- **Fallback**: si la apertura de las sesiones adicionales falla (p. ej. `MaxSessions` del servidor SSH), se reintenta la transferencia completa por la vía actual de 1 conexión antes de reportar error. El fallback se registra en el log con motivo.
- Las funciones actuales (`sftp_upload_file`, `sftp_upload_file_streaming`, `sftp_download_file`) **no se tocan**.

## 2. Bridge

- Wrappers en `native/src/api.rs`: `sftp_upload_parallel` y `sftp_download_parallel`, ambos con `StreamSink<SftpProgress>`; `concurrency: Option<u8>` (None = 4).
- Regenerar el bridge y — lección aprendida — **recompilar ambos perfiles** de Rust (`cargo build` y `cargo build --release`): la app carga la lib de release aunque el build de Flutter sea debug.

## 3. Dart — subida de carpeta en paralelo

En `lib/src/features/sftp_browser.dart`:

- `uploadFolder` calcula el total de bytes de la carpeta al enumerar, y sube con un **pool de 3 ficheros concurrentes**. Cuando el pool está activo, cada fichero usa `concurrency: 2` interno (máximo ~6 conexiones simultáneas); un fichero solo (subida individual) usa `concurrency: 4`.
- Progreso agregado: un mapa `{ruta: bytes}` alimentado por los streams de cada fichero en vuelo; la barra muestra `bytes_totales_subidos / bytes_totales` y el contador "N/M ficheros". Se reutiliza el campo `progress` del estado y el banner actual (fila propia, elipsis); solo cambia el texto a la clave nueva de progreso global.
- Los directorios se crean primero (como hoy, ordenados padre→hijo); los ficheros se reparten al pool después.
- `uploadFile` (individual) pasa a `sftp_upload_parallel` conservando su barra actual.

## 4. Dart — descargas

- `downloadFile` pasa a `sftp_download_parallel` y **gana barra de progreso** (hoy no tiene ninguna), con el mismo banner.

## 5. i18n

Claves nuevas en ambos `.arb` (paridad obligatoria, registro neutro):
- `sftpFolderProgressLabel`: "{percent}% — {done}/{total} MB, {filesDone}/{filesTotal} files" / ES "{percent} % — {done}/{total} MB, {filesDone}/{filesTotal} archivos"
- `sftpDownloadingWithProgress` si hiciera falta distinguir de la clave existente de descarga.

## 6. Verificación

- **Unit tests Rust** de `split_ranges`: K no divide el tamaño, fichero < 8 MB (sin partición), tamaño 0, tamaño exactamente 8 MB, K=1.
- **Benchmark extendido**: `transfer_bench` gana un modo paralelo (`transfer_bench ... --parallel 4`) para medir la ganancia real contra la VM y confirmar la meta de ≈3–5 MB/s.
- **Integridad**: en el QA manual, subir un fichero grande y verificar checksum (`sha256sum`) local vs remoto; lo mismo en descarga. Es crítico porque la escritura posicionada con errores silenciosos corrompería datos.
- **QA manual**: subir la carpeta `offline-bundle` real (12 ficheros, ~250 MB) y comprobar tiempo total (esperado: de ~5 min a ~1–1.5 min), barra global coherente, y que cerrar el diálogo a mitad de subida no rompe la app (mismo comportamiento que hoy; un botón de cancelar es trabajo futuro).

## Fuera de alcance

- SCP como mecanismo o feature.
- Pipelining no-bloqueante en una conexión.
- Migración a russh u otro stack SSH.
- Reanudación de transferencias interrumpidas (resume).
- Botón de cancelar transferencias en curso (la cancelación existe solo internamente, ante errores).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Corrupción por escritura posicionada mal calculada | Tests de `split_ranges` + checksum en QA manual; borrado del parcial ante cualquier error |
| Servidores con `MaxSessions` bajo rechazan las sesiones extra | Fallback automático a 1 conexión, registrado en el log |
| Más conexiones = más carga en el túnel/relay | K acotado (4 individual, 3×2 en carpeta); ficheros <8 MB no paralelizan |
| El túnel gcloud es un proceso único (CPU-bound Python) y podría saturarse antes de K×1.6 | El benchmark paralelo lo medirá; si satura, se ajusta K por defecto con datos |
