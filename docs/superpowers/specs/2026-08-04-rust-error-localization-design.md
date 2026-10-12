# Diseño: Localización (i18n) de errores de la capa Rust — clasificador en Dart

**Fecha:** 2026-08-04
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature de i18n (capa Dart; sin cambios en Rust ni bridge)

## Objetivo

Hoy casi todo `native/src/api.rs` devuelve `anyhow::Result<T>`, así que cuando una operación falla el usuario ve un **string crudo en inglés** (stderr de gcloud, mensaje `anyhow`, etc.). Solo los túneles están localizados (enum tipado `TunnelError` con `code()` → claves `tunnelError*`). Este trabajo localiza el **resto** de errores Rust mediante un **clasificador en Dart** que mapea cada error a un código curado y a un mensaje traducido (EN/ES), con un fallback genérico que conserva el detalle crudo. El spec de i18n (2026-07-16) dejó esto explícitamente "fuera de alcance, fase posterior"; esta es esa fase.

## Contexto del código actual

- **Túneles (localizado):** `native/src/iap_tunnel/error.rs` define `TunnelError` con `code()` estable; cruza el bridge como `TunnelFailure` (Dart) y se mapea a `tunnelError*`.
- **GCP listado (parcial):** `classifyGcpError(dynamic e) → GcpErrorType{permissionDenied, unauthenticated, unknown}` en `lib/src/features/gcloud_provider.dart` clasifica por substring de `e.toString()`. Alimenta el `GcpSessionBanner` (re-login) y el estado de error de listar proyectos/instancias.
- **Resto (sin localizar):** start/stop/reset/suspend/resume instancias, SFTP, snapshots, credenciales, login → `anyhow::Result` → string inglés crudo en SnackBars/diálogos.

## Decisiones

| Decisión | Elección |
|---|---|
| Enfoque | **Clasificador en Dart** (Enfoque 1): sin tocar Rust ni regenerar el bridge |
| Cobertura | **Set curado** de categorías comunes + fallback genérico (no tipado exhaustivo) |
| Taxonomía | Enum único `AppErrorCode`; **absorbe** `classifyGcpError`/`GcpErrorType` (un solo clasificador) |
| Banner re-login | Migra de `GcpErrorType.unauthenticated` → `AppErrorCode.notAuthenticated` (equivalente en comportamiento) |
| Errores de túnel | `localizedError` reconoce `TunnelFailure` y reusa el mapeo `tunnelError*` existente (no se re-implementa) |
| Fallback | `unknown` → mensaje genérico localizado + **detalle crudo** anexado (no se pierde info); códigos conocidos → mensaje limpio sin inglés |

## Diseño

### 1. Taxonomía — `AppErrorCode`

Enum Dart en `lib/src/features/app_error.dart`:

```
notAuthenticated, permissionDenied, notFound, network,
quotaExceeded, gcloudNotInstalled, alreadyExists,
invalidInput, cancelled, unknown
```

Identificadores estables que disparan cada código (los códigos de la API de GCP son constantes que Google **no** traduce; los mensajes `anyhow` propios los controlamos nosotros):

| Código | Tokens de match (ejemplos) |
|---|---|
| `notAuthenticated` | `UNAUTHENTICATED`, `invalid_grant`, `reauth`, `gcloud auth`, HTTP 401 |
| `permissionDenied` | `PERMISSION_DENIED`, HTTP 403 |
| `notFound` | `NOT_FOUND`, HTTP 404 |
| `network` | `UNAVAILABLE`, HTTP 503, `timed out`/`timeout`, `connection refused`, `failed to connect`, DNS |
| `quotaExceeded` | `RESOURCE_EXHAUSTED`, HTTP 429, `quota` |
| `gcloudNotInstalled` | mensaje propio: `gcloud` + (`not found`/`not installed`/`no such file`) |
| `alreadyExists` | `ALREADY_EXISTS`, HTTP 409 |
| `invalidInput` | `INVALID_ARGUMENT`, HTTP 400 |
| `cancelled` | `CANCELLED`, `cancel` (transferencias abortadas) |
| `unknown` | ninguno matcheó |

### 2. Clasificador — `classifyRustError(dynamic e) → AppErrorCode`

- `final msg = e.toString();`
- Comprobaciones **ordenadas de más específico a menos** (la primera que matchea gana); `unknown` si ninguna.
- Se prefieren los **códigos simbólicos** (`PERMISSION_DENIED`, etc.) por ser inequívocos; los códigos HTTP numéricos se usan con cautela (cualificados, p. ej. `403`/`404`) para no dar falsos positivos con puertos/tamaños. La lista exacta de tokens y su orden se fijan en el plan con la tabla de tests.
- `classifyGcpError`/`GcpErrorType` **se elimina**; sus valores actuales se subsumen (`unauthenticated`→`notAuthenticated`, `permissionDenied`→`permissionDenied`, `notFound`→`notFound`, `unknown`→`unknown`). Migran a `AppErrorCode`: el campo `TunnelState.errorType` (`gcloud_provider.dart`), su constructor, y los call-sites (`gcp_session_banner.dart:22` y el estado de error de listar proyectos/instancias). Reuso confirmado para la ruta de túnel: `tunnelErrorMessage(l10n, code)` en `tunnel_manager_dialog.dart`.

### 3. Helper de display — `localizedError(AppLocalizations l10n, dynamic e) → String`

Punto único para mostrar **cualquier** error al usuario:

1. Si `e` es `TunnelFailure` → enruta al mapeo `tunnelError*` existente (reusa lo que hay; no se duplica).
2. Si no → `code = classifyRustError(e)`:
   - **Conocido** → mensaje localizado limpio (`l10n.appErrorNotAuthenticated`, …).
   - **`unknown`** → `l10n.appErrorGeneric(detail)`, donde `detail` = `e.toString()` recortado/limpiado (para no perder la pista de depuración).

### 4. Claves l10n — `appError*` (EN/ES, paridad)

Una por código conocido + la genérica con placeholder. Redacción inicial (se afina en el plan):

| Clave | EN | ES |
|---|---|---|
| `appErrorNotAuthenticated` | Your session expired. Sign in again. | Tu sesión expiró. Inicia sesión de nuevo. |
| `appErrorPermissionDenied` | You don't have permission for this operation. | No tienes permiso para esta operación. |
| `appErrorNotFound` | The requested resource was not found. | No se encontró el recurso solicitado. |
| `appErrorNetwork` | Network error. Check your connection and try again. | Error de red. Revisa tu conexión e inténtalo de nuevo. |
| `appErrorQuotaExceeded` | Quota exceeded. Try again later or request more quota. | Cuota excedida. Inténtalo más tarde o solicita más cuota. |
| `appErrorGcloudNotInstalled` | The gcloud CLI is not installed or was not found. | gcloud CLI no está instalado o no se encontró. |
| `appErrorAlreadyExists` | That resource already exists. | Ese recurso ya existe. |
| `appErrorInvalidInput` | Invalid input. | Entrada inválida. |
| `appErrorCancelled` | Operation cancelled. | Operación cancelada. |
| `appErrorGeneric` | Operation failed: {detail} | La operación falló: {detail} |

### 5. Integración (call-sites)

Reemplazar los `e.toString()` de cara al usuario (SnackBars, diálogos de error, estados de error de providers) por `localizedError(l10n, e)`. El `GcpSessionBanner` migra su condición de disparo a `AppErrorCode.notAuthenticated`. El **inventario exacto** de call-sites se levanta en el plan (grep de `.toString()` en Snackbar/diálogos/estado de error); no se tocan los logs internos ni `debugPrint` (esos quedan en inglés a propósito).

## Verificación

- **Unit (`test/app_error_test.dart`):** tabla de mensajes representativos reales (GCP client-lib, stderr de gcloud, `anyhow` propios) → `AppErrorCode` esperado. Es el ancla de robustez del clasificador. Casos negativos (mensaje ambiguo → `unknown`).
- **`localizedError`:** `TunnelFailure` → clave `tunnelError*`; cada código → su mensaje; `unknown` → genérico con el detalle interpolado.
- **Paridad EN/ES:** todas las `appError*` presentes en ambos `.arb`; `flutter gen-l10n` sin drift.
- **Regresión:** `flutter analyze` 0 errores; suite completa verde; el banner de re-login sigue apareciendo con sesión expirada (comportamiento preservado tras migrar a `AppErrorCode`).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Substrings frágiles si cambian los mensajes | Se matchean **códigos simbólicos estables** de la API de GCP (no traducidos) y mensajes propios que controlamos; la tabla de tests documenta los esperados y detecta regresiones |
| Falsos positivos con códigos HTTP numéricos (403 en un puerto) | Preferir códigos simbólicos; usar numéricos cualificados; cubrir con casos negativos en el test |
| Migrar el banner rompe el re-login (código ya revisado) | Migración equivalente (`unauthenticated`→`notAuthenticated`); test de que el banner sigue disparando con sesión expirada |
| Filtrar inglés crudo en un caso "conocido" | Los códigos conocidos devuelven mensaje limpio; solo `unknown` anexa el detalle crudo |

## Fuera de alcance

- Tipado exhaustivo de errores en Rust (se descartó a favor del set curado).
- Cambios en Rust o regeneración del bridge (Enfoque 1 es 100% Dart).
- Localizar logs internos / `debugPrint` (quedan en inglés a propósito).
- Notificaciones de escritorio en inglés (ítem i18n aparte; ver [[project_i18n_plan]]).
