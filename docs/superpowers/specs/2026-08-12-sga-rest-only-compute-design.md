# Diseño: SG-A — REST-only para datos + lifecycle de compute (salida de gcloud, fase 1)

**Fecha:** 2026-08-12
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Refactor Dart-only (sin Rust/bridge). Primer sub-proyecto de la iniciativa de salida de `gcloud` — ver `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Objetivo

Retirar `gcloud` CLI de la **ruta runtime de datos y lifecycle de compute**, dejando REST como única vía. Es la ganancia de bajo riesgo de la iniciativa: encoge la superficie de gcloud sin tocar auth/token (sigue por gcloud hasta SG-C/D) ni el túnel (SG-B).

## Contexto (estado real verificado)

- **El listado ya es REST.** En `native/src/api.rs`, `list_instances` (líneas ~92-107) y `list_projects` (~84-90) llaman al **cliente REST** (`crate::gcp_rest_client::list_instances_client_lib` / `list_projects_simple_async`) y solo mapean el tipo. Es decir, `listInstances()`/`listProjects()` en Dart ya van por REST pese a sus nombres/comentarios.
- **Comentarios obsoletos.** `instancesProvider` (`lib/src/features/gcloud_provider.dart:343-383`) dice `// Use CLI which respects the active gcloud account` y tiene una estructura "CLI-first / REST-fallback" que en realidad es **REST/REST redundante** (ambas ramas acaban en el mismo REST). `projectsProvider` (~313-322) ya está en REST con comentario correcto.
- **gcloud en compute solo vive en los *fallbacks*:**
  - Lifecycle `*WithMethod` (`gcloud_provider.dart:1216-1380`): `try <op>InstanceClientLib (REST) catch → <op>Instance (gcloud CLI)`. Las fns `startInstance/stopInstance/resetInstance/suspendInstance/resumeInstance` (sin `ClientLib`) mapean a `crate::gcloud::*` (CLI).
  - Búsqueda manual (`manual_instance_dialog.dart:78-110`): `try getInstanceClientLib (REST) catch → getInstanceGcloud (CLI)`.
- **Plumbing de método inerte.** El enum `GcpApiMethod {cli, clientLibrary}` + `apiMethodProvider`/`ApiMethodNotifier.setMethod` (`gcloud_provider.dart:194-210`) + la pantalla `client_lib_test_screen.dart`: `setMethod` **no se llama desde ningún sitio** y la pantalla **no tiene punto de entrada** en la UI de release → siempre queda en `clientLibrary`. Es código muerto.
- **Sistema de errores** (`lib/src/features/app_error.dart`): `localizedError(l10n, e, {standalone})` ya se usa en los handlers de botón de lifecycle (`overview_tab.dart`), que localizan el error re-lanzado.

## Decisiones

| Decisión | Elección |
|---|---|
| Alcance | **Solo Dart.** Borrar las fns muertas de `gcloud.rs` + exports `api.rs` + regen del bridge se difiere a **SG-E**. Sin regen del bridge en SG-A. |
| Lifecycle | Quitar el fallback gcloud de los 5 `*WithMethod` → REST-only; el error localizado se propaga (mecanismo existente). |
| Búsqueda manual | Quitar el fallback `getInstanceGcloud` → REST-only; el `catch` del REST fija el error en pantalla. |
| `instancesProvider` | Simplificar el REST/REST redundante a una sola llamada REST + corregir comentarios obsoletos. Comportamiento idéntico. |
| Plumbing `GcpApiMethod`/`client_lib_test_screen` | **Diferido a SG-E** (inerte, inofensivo). No se toca en SG-A. |
| Listado por-cuenta (`listProjectsForAccount`) | **Diferido a SG-D** (acoplado a multi-cuenta). |
| Fila "gcloud CLI requerido" + checks Doctor | **Diferido a SG-E** (siguen siendo ciertos mientras auth use gcloud). |
| Rust/bridge/auth/túnel | Sin cambios. |

## Diseño

### 1. Lifecycle: REST-only en los 5 `*WithMethod`

En `lib/src/features/gcloud_provider.dart`, en `startInstanceWithMethod`, `stopInstanceWithMethod`, `suspendInstanceWithMethod`, `resumeInstanceWithMethod`, `resetInstanceWithMethod`: eliminar el `try/catch` **interno** que cae a la fn gcloud, dejando la llamada REST directa dentro del `try` externo existente. El `try/catch` **externo** (que hace `refreshInstances`, la notificación de éxito/fallo y el `rethrow`) se conserva intacto; `suspendInstanceWithMethod` conserva su `disconnectAllForInstance` inicial.

Antes (patrón de los 5):
```dart
try {
  await startInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
} catch (e) {
  debugPrint('REST start failed, falling back to CLI: $e');
  await startInstance(projectId: projectId, zone: zone, instanceName: instanceName);
}
```
Después:
```dart
await startInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
```
(análogo para stop/suspend/resume/reset con su `*InstanceClientLib`). El error de un fallo REST llega al `catch` externo, que ya notifica el fallo y hace `rethrow`; el handler de botón en `overview_tab.dart` lo localiza vía `localizedError`.

### 2. Búsqueda manual: REST-only

En `lib/src/features/manual_instance_dialog.dart` (~78-110): eliminar el bloque "Fallback to gcloud CLI" (`getInstanceGcloud` + su `setState` con `_usedMethod = 'gcloud CLI'`). En el `catch` de la ruta REST, fijar el error en pantalla con el **mismo tratamiento que hoy hace el `catch` final** (limpieza de `AnyhowException(...)`), en vez de intentar gcloud:

```dart
try {
  // ...getInstanceClientLib (REST)...
  setState(() { _foundInstance = ...; _usedMethod = 'REST API'; _isLoading = false; });
} catch (e) {
  setState(() {
    _error = e.toString().replaceAll('AnyhowException(', '').replaceAll(')', '');
    _isLoading = false;
  });
}
```
`_usedMethod` ya solo tomará el valor `'REST API'`; el campo se conserva (inofensivo). Migrar este diálogo a `localizedError` es una mejora opcional diferida a SG-E, no forma parte de SG-A.

**Imports:** tras quitar `getInstanceGcloud`, revisar y **eliminar imports que queden sin uso** (p. ej. `import '../bridge/api.dart/gcloud.dart';` en `manual_instance_dialog.dart`, si `getInstanceGcloud`/`GcpInstance` eran su único uso) para no introducir un warning `unused_import` nuevo. Análogamente en cualquier archivo tocado.

### 3. `instancesProvider`: una sola llamada REST + comentarios correctos

En `lib/src/features/gcloud_provider.dart` (~343-383): sustituir el `try listInstances catch → listInstancesClientLib(map)` por una única llamada REST con `rethrow` en fallo (misma forma que `projectsProvider`), y corregir los comentarios obsoletos (`// Use CLI...`, y `(account-aware, CLI for active account)`):

```dart
// Provider para la lista de instancias (account-aware, vía REST del cliente Rust).
final instancesProvider = FutureProvider<List<GcpInstance>>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), () { link.close(); ref.invalidateSelf(); });
  ref.onDispose(() => timer.cancel());
  ref.watch(accountProvider);
  final projectId = ref.watch(selectedProjectProvider);
  if (projectId == null) return [];
  // listInstances() va por el cliente REST de Rust (sigue la cuenta activa). En fallo
  // propagamos: una lista vacía ocultaría el problema real.
  try {
    return await listInstances(projectId: projectId);
  } catch (e) {
    debugPrint('Instance listing failed for $projectId: $e');
    rethrow;
  }
});
```
Comportamiento idéntico (ambas ramas ya eran REST y en fallo total ya hacía `rethrow`); elimina el segundo intento redundante y el mapeo duplicado.

## Errores

- **Lifecycle:** el fallo REST se re-lanza y el handler de botón lo muestra localizado (`localizedError`, ya existente). Sin fallback silencioso a gcloud.
- **Búsqueda manual:** el fallo REST se muestra con la limpieza de error existente del diálogo.
- **Listado:** el fallo se propaga a los selectores, que ya tienen rama de error.

## Testing

Estos flujos van por el bridge (la lib nativa no se linka en `flutter test`), así que **no hay test headless nuevo viable** para las llamadas REST en sí. Verificación:

- `flutter analyze` sin issues nuevas (baseline ~85).
- `flutter test` (suite completa) verde — no-regresión (ningún test existente referencia los fallbacks eliminados).
- **Checklist de QA manual** (nuevo doc, como en features bridge-dependientes previas): con una VM real —
  - start / stop / reset / suspend / resume funcionan y notifican por REST;
  - un fallo de operación muestra el error localizado (no cae a gcloud);
  - búsqueda manual de instancia con nombre válido (encuentra) y con nombre inexistente (muestra error, no gcloud);
  - la lista de instancias y de proyectos del dashboard siguen poblando.

## Alcance / fuera de alcance

- **Dentro:** quitar el fallback gcloud de los 5 `*WithMethod` y de `manual_instance_dialog`; simplificar `instancesProvider` + comentarios; checklist de QA manual. Todo Dart.
- **Fuera:** auth/token (gcloud hasta SG-C/D); túnel nativo por defecto (SG-B); borrar código muerto Rust + `GcpApiMethod`/`client_lib_test_screen` + regen bridge (SG-E); listado por-cuenta (SG-D); fila "gcloud requerido"/Doctor (SG-E); migrar el diálogo manual a `localizedError` (SG-E opcional).

## Verificación

- `flutter analyze` sin issues nuevas y `flutter test` (suite) verde.
- Ningún path de datos/lifecycle de compute invoca gcloud en runtime (los `*Instance` CLI y `getInstanceGcloud` dejan de llamarse desde Dart; quedan como código muerto para SG-E).
- Checklist de QA manual creado.
