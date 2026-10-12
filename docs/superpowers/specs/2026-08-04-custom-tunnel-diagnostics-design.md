# Diseño: Custom Tunnel — feedback real y diagnóstico (sub-proyecto A)

**Fecha:** 2026-08-04
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Fix + mejora de UX (Rust: captura de stderr; Dart: feedback). Parte A de dos (B = SSH Port Forward, spec aparte).

## Objetivo

El botón **Custom Tunnel** ([overview_tab.dart:469](../../../lib/src/features/workspace/overview_tab.dart)) abre un túnel IAP a un puerto remoto y **descarta el resultado**: no muestra el puerto local (el usuario no sabe a qué `127.0.0.1:<puerto>` conectarse) ni el error si falla. Además, [`start_gcloud`](../../../native/src/tunnel.rs) **captura la stderr de gcloud (`Stdio::piped()`) pero nunca la lee**, devolviendo un genérico *"Tunnel process died immediately after startup"* — el motivo real (`4003` backend inalcanzable / `4033` firewall / auth) se pierde. Este trabajo cierra el hueco: éxito muestra el puerto local; fallo muestra el error **real y localizado** con una pista de "servicio en localhost".

## Contexto (hallazgos del debugging)

- **Causa raíz del caso disparador:** un servicio ligado a `127.0.0.1:<puerto>` en la VM no es alcanzable por IAP TCP forwarding (IAP conecta a la IP interna de la VM, no a localhost). `gcloud compute ssh -- -L` sí lo alcanza (localhost se resuelve dentro de la VM). No es un bug de la app ni de firewall; es la dirección de bind del servicio. → Motiva la pista de localhost (y el sub-proyecto B).
- **Flujo del error (verificado):** `start_connection` ([api.rs:202](../../../native/src/api.rs)) mapea el error de gcloud a `TunnelFailure { code: "protocol_error", detail: <mensaje anyhow> }`. `connect()` (`gcloud_provider.dart`) guarda `error: e.detail ?? e.code` en `tunnelState.error` y devuelve `null`. → Tras capturar la stderr en Rust, `tunnelState.error` contendrá el motivo real.

## Decisiones

| Decisión | Elección |
|---|---|
| Captura de stderr | `start_gcloud` lee la stderr del hijo en los fallos y la incluye en el error (recortada) |
| Regen del bridge | **No** — no cambia la firma de `start_connection`, solo el contenido del `detail` |
| Éxito (UX) | SnackBar "Túnel listo en `127.0.0.1:<puerto-local>`" + botón **Copiar** (sin auto-copiar) |
| Fallo (UX) | **Diálogo** de error: mensaje localizado + pista de localhost condicional + detalle crudo (para el técnico) |
| Reuso | El mensaje localizado usa `localizedError(l10n, tunnelState.error)` (feature ya existente) |
| Menores | Añadir `context.mounted` tras el `await`; `dispose()` del `TextEditingController` del diálogo |

## Diseño

### 1. Rust — capturar la stderr real (`native/src/tunnel.rs`, `start_gcloud`)

Hoy el hijo se lanza con `.stderr(Stdio::piped())` pero la stderr nunca se lee; los dos caminos de fallo devuelven un genérico. Cambio: en cada fallo, **drenar la stderr del hijo** (recortada a un máximo, p. ej. 2 KB / últimas ~15 líneas) e incluirla en el `anyhow::Error`:
- Proceso muere en ~1s → `anyhow!("gcloud tunnel failed: {}", stderr)`.
- Puerto local nunca escucha en 10s → `anyhow!("gcloud tunnel timed out (port {} never listened): {}", port, stderr)`.

El motivo real (`4003`/`4033`/auth) queda en el `detail` de `TunnelFailure` y llega a Dart. Sin cambios de firma → sin regen del bridge.

### 2. Dart — Éxito (`overview_tab.dart`, handler del botón)

Capturar el retorno de `connect()`:
- Si el puerto local **≠ null** → SnackBar con `l10n.customTunnelReady('127.0.0.1:$localPort')` y una **acción "Copiar"** (`SnackBarAction`) que copia `127.0.0.1:$localPort` al portapapeles y muestra `l10n.customTunnelAddressCopied`. No se copia automáticamente.
- Reemplaza el SnackBar actual "Creando túnel…" (que mostraba el puerto **remoto**), o se muestra antes del await y se sustituye por el de éxito/fallo al terminar.

### 3. Dart — Fallo (diálogo de error)

Si `connect()` devuelve **null**: leer el error del estado del túnel — `ref.read(activeConnectionsProvider)[makeTunnelKey(target.name, remotePort)]?.error` — y abrir un `AlertDialog`:
- **Título:** `l10n.customTunnelFailedTitle` ("No se pudo crear el túnel").
- **Cuerpo:** `localizedError(l10n, error)` (titular localizado).
- **Pista de localhost (condicional):** si `error` contiene señales de backend inalcanzable (`4003`, `failed to connect to backend`, `connection refused`), mostrar `l10n.customTunnelLocalhostHint`.
- **Detalle crudo:** el `error` en texto pequeño/monoespaciado y seleccionable (ahora que se captura, se muestra para el técnico).
- **Acciones:** "Cerrar"; y **"Ejecutar Doctor"** (abre el Connectivity Doctor, que tiene el check de firewall IAP) — *incluido por defecto; si prefieres omitirlo, se quita en revisión del spec.*

### 4. Claves l10n nuevas (EN/ES, paridad)

| Clave | EN | ES |
|---|---|---|
| `customTunnelReady` `{address}` | Tunnel ready at {address} | Túnel listo en {address} |
| `customTunnelAddressCopied` | Address copied | Dirección copiada |
| `customTunnelFailedTitle` | Couldn't create the tunnel | No se pudo crear el túnel |
| `customTunnelLocalhostHint` | The service may be listening only on 127.0.0.1; IAP can't reach localhost-only services. Bind it to 0.0.0.0 or use SSH forwarding. | El servicio puede estar escuchando solo en 127.0.0.1; IAP no alcanza servicios en localhost. Enlázalo a 0.0.0.0 o usa reenvío SSH. |

(El botón "Copiar" reusa `commonCopy`; "Cerrar" reusa `commonClose`.)

### 5. Menores (mismo handler/diálogo)

- Guardar `context.mounted` antes de usar `context`/`ScaffoldMessenger` tras el `await _showCustomTunnelDialog(...)` y tras `await connect(...)`.
- `dispose()` del `customPortController` de `_showCustomTunnelDialog` (hoy se fuga).

## Verificación

- **Rust (`cargo test`):** un test de que el helper de recorte de stderr limita longitud/líneas. (La ejecución real de gcloud no es testeable en unidad; la captura se valida en QA manual.) `cargo build` debug+release.
- **Dart:** `flutter analyze` 0 errores; `flutter gen-l10n` sin drift; paridad EN/ES de las claves nuevas; `flutter test`. Un widget test del diálogo de fallo (dado un `error` con `4003`, muestra la pista de localhost; sin esa señal, no la muestra).
- **QA manual:** (a) Custom Tunnel a un puerto con servicio en `0.0.0.0` → SnackBar con puerto local + Copiar funciona. (b) A un puerto con servicio solo en `127.0.0.1` (o sin firewall) → diálogo con el error real de gcloud + pista de localhost. (c) El botón Doctor abre el diagnóstico.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Leer la stderr del hijo bloquea o cuelga | Leer solo tras detectar el fallo (proceso muerto o timeout), con recorte; no bloquear el camino de éxito |
| La stderr puede traer info sensible (rutas, proyecto) | Es el mismo contenido que gcloud imprime en la terminal del usuario; se muestra solo a quien ya opera esa VM. Recortado |
| `localizedError` sobre el string clasifica "4003…connection refused" como `network` genérico | Aceptable — la **pista de localhost** aporta la guía específica; el detalle crudo muestra el `4003` |

## Fuera de alcance

- **Modo SSH Port Forward (`-L`)** — es el sub-proyecto **B** (spec aparte); aquí solo se añade la *pista* que lo menciona.
- Tipar los errores de gcloud a códigos estables (siguen como `protocol_error` + detalle; `localizedError` los clasifica por string).
- Cambiar el motor de túnel o su firma en el bridge.
