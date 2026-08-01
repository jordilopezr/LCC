# Diseño: Detección de sesión GCP caducada + re-login desde la app

**Fecha:** 2026-07-31
**Estado:** Aprobado
**Tipo:** Feature (Flutter + Rust, flutter_rust_bridge)

## Objetivo

Cuando la sesión de gcloud/ADC caduca durante el uso normal, la app deja de listar proyectos/instancias con un error crudo y el usuario tiene que ir a una terminal a hacer `gcloud auth login`. Esta feature hace que la app **detecte** ese estado y ofrezca **reautenticarse desde la propia app**, con un **banner no-modal** en el dashboard y un botón "Reautenticar" que abre el navegador y, al volver, re-lista solo.

## Contexto del código actual (verificado)

- **Auto-refresco:** `projectsProvider` e `instancesProvider` (`lib/src/features/gcloud_provider.dart`) son `FutureProvider` con `keepAlive()` + `Timer(Duration(minutes: 5))` → `invalidateSelf()`. Cada 5 min re-fetchan; `listProjects()`/`listInstances()` van por el token de gcloud CLI (reauth/RAPT) con fallback a ADC. Si la sesión caducó, **lanzan el error y se propaga** (los widgets ya tienen rama de error).
- **Origen del error:** `native/src/gcp_rest_client.rs:230` devuelve el `anyhow!` con el texto: `"Authentication failed: your Google Cloud session has expired or requires reauthentication. Run: gcloud auth login (and if it persists: gcloud auth application-default login)"`.
- **Clasificador existente:** `_classifyGcpError(dynamic e)` (`gcloud_provider.dart:75`) mapea `PERMISSION_DENIED/403`, `NOT_FOUND/404`, `UNAUTHENTICATED/401`, quota, network → `GcpErrorType`. El mensaje de sesión-caducada **no** contiene `UNAUTHENTICATED`/`401` → hoy cae en `GcpErrorType.unknown`. **Este es el hueco central.**
- **Re-auth ya existe (a reutilizar):** `native/src/doctor.rs:1151` (`execute_doctor_fix("re_authenticate", …)`) llama a `crate::gcloud::execute_login()`, que ejecuta `gcloud auth login` (abre navegador, síncrono). Hoy solo se dispara desde el **Doctor** (`connectivity_doctor.dart`, confirmación `doctorConfirmReauthenticate`).
- Ya existe `GcpErrorType.unauthenticated` y el texto `commonGcpErrorUnauthenticated` ("Authentication required. Please re-login.").

## Decisiones

| Decisión | Elección |
|---|---|
| Interacción | **Banner no-modal** arriba del dashboard (no un modal ni auto-reautenticar) |
| Detección | **Reactiva** sobre el estado de error de `projectsProvider`/`instancesProvider`; **semi-proactiva** gracias al TTL de 5 min ya existente (no se añade poller nuevo) |
| Re-auth | Reutilizar `crate::gcloud::execute_login()` (el mismo `gcloud auth login` del Doctor), expuesto con un **bridge fn dedicado** `reauthenticate()` (sin los args de instancia del Doctor) |
| Alcance v1 | Solo listado de **proyectos e instancias**; otras operaciones muestran su error como hoy |
| ADC (`application-default login`) | **No** se ejecuta en v1; se documenta como fallback manual si el re-login por sí solo no bastara |

## Diseño

### 1. Clasificación del error (el arreglo central)

Extender `_classifyGcpError` (`gcloud_provider.dart`) para reconocer el estado de reautenticación como `unauthenticated`. Añadir, **antes** del `return unknown`, una comprobación de subcadenas distintivas del mensaje (case-sensitive, tal como las emite Rust):

```dart
if (msg.contains('requires reauthentication') ||
    msg.contains('session has expired') ||
    msg.contains('invalid_rapt') ||
    msg.contains('No active GCP account')) {
  return GcpErrorType.unauthenticated;
}
```

(Se mantiene la rama existente `UNAUTHENTICATED`/`401`.) Con esto, el `AsyncError` de los providers queda clasificado como `unauthenticated`.

### 2. Banner global no-modal

Nuevo widget `GcpSessionBanner` (`lib/src/features/gcp_session_banner.dart`):

- Observa `projectsProvider` **e** `instancesProvider`. Se muestra si **alguno** está en `AsyncError` cuyo error, pasado por `_classifyGcpError`, sea `GcpErrorType.unauthenticated`. (Se expone `_classifyGcpError` como público `classifyGcpError` para reutilizarlo aquí.)
- Cuando no hay error auth → el widget ocupa 0 alto (`SizedBox.shrink()`), no molesta.
- Contenido: icono ⚠ + texto `l10n.sessionExpiredBanner` + botón `FilledButton` `l10n.sessionExpiredReauth` ("Reautenticar").
- Se coloca en el dashboard, **encima** del contenido principal (en el `Column`/`Scaffold` raíz del dashboard en `lib/main.dart`, justo bajo la barra superior).

### 3. Acción "Reautenticar"

- **Rust/bridge:** nueva `pub async fn reauthenticate() -> Result<()>` en `native/src/api.rs` que llama a `crate::gcloud::execute_login()` (reutiliza la lógica existente; sin duplicar gcloud). Regenerar el bridge.
- **Dart:** el botón, al pulsarse:
  1. Pasa a estado "en progreso": deshabilitado + label `l10n.sessionExpiredReauthenticating` ("Autenticando…"). El estado vive local en el `StatefulWidget` del banner (`bool _busy`).
  2. `await reauthenticate();`
  3. **Éxito** → `ref.invalidate(projectsProvider); ref.invalidate(instancesProvider);` (se re-listan; al desaparecer el error auth, el banner se oculta solo). SnackBar `l10n.sessionExpiredReauthOk`.
  4. **Fallo/cancelado** (excepción de `execute_login`) → `_busy = false`; el banner sigue visible; SnackBar `l10n.sessionExpiredReauthFailed`.

### 4. i18n (EN/ES, append-only, con `@key` solo en EN)

| clave | EN | ES |
|---|---|---|
| `sessionExpiredBanner` | `Your Google Cloud session has expired.` | `Tu sesión de Google Cloud ha expirado.` |
| `sessionExpiredReauth` | `Re-authenticate` | `Reautenticar` |
| `sessionExpiredReauthenticating` | `Authenticating…` | `Autenticando…` |
| `sessionExpiredReauthOk` | `Re-authenticated. Refreshing…` | `Reautenticado. Actualizando…` |
| `sessionExpiredReauthFailed` | `Re-authentication failed or was cancelled.` | `La reautenticación falló o se canceló.` |

Regenerar con `flutter gen-l10n`.

## Alcance / fuera de alcance

- **v1:** detección + banner sobre proyectos e instancias; re-auth vía `gcloud auth login`.
- **Fuera de v1:** poller proactivo dedicado (el TTL de 5 min ya lo cubre); cobertura de todas las operaciones GCP (túneles, snapshots, serial); ejecutar `gcloud auth application-default login` automáticamente (queda como fallback manual, ya mencionado en el propio texto del error de Rust).

## Verificación

- **Unit (Dart):** `classifyGcpError` con el mensaje exacto de `gcp_rest_client.rs` ("…requires reauthentication…") → `GcpErrorType.unauthenticated`; y con `invalid_rapt`, `session has expired`, `No active GCP account`. Casos negativos: `PERMISSION_DENIED` → `permissionDenied`; texto genérico → `unknown`.
- **Widget (Dart):** banner **visible** cuando `projectsProvider` está en `AsyncError`(unauthenticated); **oculto** (`SizedBox.shrink`) cuando `AsyncData`; pulsar "Reautenticar" invoca `reauthenticate()` (mock) y, al éxito, invalida los providers.
- **Manual (QA):** con la app abierta, `gcloud auth revoke` (o dejar caducar la sesión) → en ≤5 min aparece el banner; "Reautenticar" abre el navegador; al completar el login, el banner desaparece y se listan proyectos/instancias. Cancelar el login → el banner sigue, sin crash.

## Archivos afectados

- Modificar: `lib/src/features/gcloud_provider.dart` (extender + exponer `classifyGcpError`).
- Crear: `lib/src/features/gcp_session_banner.dart` (widget).
- Modificar: `lib/main.dart` (montar el banner en el dashboard).
- Modificar: `native/src/api.rs` (`reauthenticate()`), regenerar bridge (`lib/src/bridge/api.dart/…`).
- Modificar: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` (+ regen `lib/l10n/gen/`).
- Crear: tests (unit del clasificador, widget del banner).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| El mensaje de error de Rust cambia y el clasificador deja de reconocerlo | La clasificación se basa en varias subcadenas estables (`requires reauthentication`, `invalid_rapt`); un test unitario ancla el contrato con el string real |
| `gcloud auth login` refresca la sesión CLI pero el fallo venía de ADC | El error mismo indica el fallback (`application-default login`); si tras reautenticar el banner reaparece, el usuario tiene la pista; ADC-auto queda para v2 |
| `execute_login()` es síncrono/bloqueante (abre navegador y espera) | Se llama con `await` desde el bridge async; el botón muestra estado "Autenticando…" mientras tanto; no bloquea el hilo de UI |
| Doble fuente (proyectos e instancias en error a la vez) muestra dos banners | El banner es único y global (observa ambos providers pero renderiza una sola barra) |
