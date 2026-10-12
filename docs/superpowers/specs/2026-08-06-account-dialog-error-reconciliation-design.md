# Diseño: Reconciliar el stopgap de errores del Account dialog con `localizedError`

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Cleanup / reconciliación (Dart-only; sin Rust/bridge). Cierra el pendiente del mapeo de errores Rust (2026-08-04).

## Objetivo

`account_management_dialog.dart` mapea errores con su propia función `_gcpErrorMessage` (un stopgap sobre las claves `commonGcpError*`), en paralelo al sistema unificado `localizedError`/`classifyRustError`/`AppErrorCode` de `lib/src/features/app_error.dart`. Este trabajo hace que el diálogo use **`localizedError`** (una sola fuente de verdad de errores localizados) y elimina el stopgap junto con el código muerto que deja atrás.

## Contexto

- **`_gcpErrorMessage(l10n, AppErrorCode? type)`** (`account_management_dialog.dart:9-30`): mapea 5 códigos a claves `commonGcpError*` y colapsa el resto (gcloudNotInstalled/alreadyExists/invalidInput/cancelled/unknown) en `commonGcpErrorUnknown`; devuelve `null` para `type == null`. Se usa en L85: `_gcpErrorMessage(l10n, accountState.errorType) ?? accountState.error!`.
- **`localizedError(l10n, e, {standalone = true})`** (`app_error.dart:85`): clasifica `e` con `classifyRustError` y mapea los **10** códigos a claves `appError*` (distingue todos); para `unknown` con `standalone: true` devuelve `l10n.appErrorGeneric(detail)`. Nunca devuelve `null`.
- **`accountState.errorType`** se fija con `classifyRustError(e)` (`gcloud_provider.dart:98,154`), así que re-clasificar `accountState.error` con `localizedError` produce el **mismo** código — equivalente y seguro.
- **`errorType` se lee SOLO** en `account_management_dialog.dart:85`; tras el cambio queda write-only.
- **Las 6 claves `commonGcpError*`** (`app_en.arb:46-51`, `app_es.arb:36-41`) las usa **solo** `_gcpErrorMessage`; tras el cambio quedan muertas. Solo existen los locales en/es.
- `localizedError`/`classifyRustError` ya tienen cobertura de tests (feature de errores, 2026-08-04).

## Decisiones

| Decisión | Elección |
|---|---|
| Fuente de verdad | El diálogo usa `localizedError(l10n, accountState.error!)` (default `standalone: true`) |
| Stopgap | Borrar `_gcpErrorMessage` |
| Código muerto derivado | Borrar el campo `AccountState.errorType` y las 6 claves `commonGcpError*` (en/es) |
| Re-clasificación vs código pre-clasificado | Re-clasificar el crudo (equivalente, porque `errorType` venía de `classifyRustError` del mismo string) — evita exponer un `messageForCode` nuevo |
| Rust/bridge | Sin cambios |

## Diseño

### 1. `account_management_dialog.dart`

- Reemplazar la línea 85:
  ```dart
  _gcpErrorMessage(l10n, accountState.errorType) ?? accountState.error!,
  ```
  por:
  ```dart
  localizedError(l10n, accountState.error!),
  ```
  (`localizedError` nunca devuelve `null`, por lo que el `?? accountState.error!` sobra.)
- Borrar la función `_gcpErrorMessage` (L7-30, incluido su doc-comment). El `import 'app_error.dart';` se mantiene (aporta `localizedError`).

### 2. `gcloud_provider.dart` — eliminar el campo muerto `AccountState.errorType`

- Quitar el campo `final AppErrorCode? errorType;` (L29), el parámetro del constructor (L36), y del `copyWith` (el parámetro L44 + la asignación `errorType: errorType,` L51).
- En los dos sitios que lo fijan (L98 y L154), quitar la línea `errorType: classifyRustError(e),`.
- Tras esto, si `classifyRustError`/`AppErrorCode` ya no se usan en `gcloud_provider.dart`, retirar el `import 'app_error.dart';` de ese archivo (lo confirma `flutter analyze`: quitar solo si queda sin uso; conservarlo si algo más de `app_error` sigue usándose ahí).

### 3. i18n — borrar las 6 claves muertas

- Quitar `commonGcpErrorPermissionDenied`, `commonGcpErrorNotFound`, `commonGcpErrorUnauthenticated`, `commonGcpErrorQuotaExceeded`, `commonGcpErrorNetwork`, `commonGcpErrorUnknown` de `lib/l10n/app_en.arb` y `lib/l10n/app_es.arb` (cuidando comas JSON). Luego `flutter gen-l10n`.

## Consecuencias visibles

- El diálogo pasa del wording `commonGcpError*` al `appError*` (estándar de la app) — texto ligeramente distinto pero coherente; además distingue más códigos (gcloudNotInstalled/alreadyExists/invalidInput/cancelled con mensaje propio).
- Errores `unknown`: se muestran como `appErrorGeneric(detalle)` (wrapper localizado + detalle crudo) en vez del genérico fijo — más informativo (y coherente con el fallback previo, que ya mostraba el crudo).

## Testing

- `localizedError`/`classifyRustError` ya cubiertos por tests existentes; no se añade test nuevo (la reconciliación es wiring + borrado de código muerto).
- Verificación: `flutter analyze` (cero issues nuevas; sirve de red para imports/campos huérfanos tras el borrado) y `flutter test` (suite existente verde). QA manual: forzar un error en el Account dialog (p.ej. sin autenticación) y ver el mensaje `appError*` correcto en el idioma activo.

## Alcance / fuera de alcance

- **Dentro:** el diálogo usa `localizedError`; borrar `_gcpErrorMessage`, el campo `AccountState.errorType`, y las 6 claves `commonGcpError*`.
- **Fuera:** cambiar el wording de las claves `appError*`; tocar `classifyRustError`/`localizedError`; otros diálogos (ya usan `localizedError` o quedan fuera de este pendiente); Rust/bridge.

## Verificación

- `flutter analyze` sin issues nuevas sobre el baseline (~85, 0 errores) y sin nuevos "unused" tras los borrados; `flutter test` verde.
- QA manual del Account dialog con un error real.
