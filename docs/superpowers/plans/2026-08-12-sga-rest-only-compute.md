# SG-A: REST-only para datos + lifecycle de compute — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retirar `gcloud` CLI de la ruta runtime de datos y lifecycle de compute (dejando REST como única vía), sin tocar auth/token ni el túnel.

**Architecture:** Cambios Dart-only en `lib/src/features/gcloud_provider.dart` (5 métodos de lifecycle + `instancesProvider`) y `lib/src/features/manual_instance_dialog.dart`. Se eliminan los `catch → gcloud` de los fallbacks; el error REST (ya localizado en el handler de botón / mostrado en el diálogo) se propaga en su lugar. El listado ya era REST bajo el capó.

**Tech Stack:** Flutter (Dart), Riverpod. Spec: `docs/superpowers/specs/2026-08-12-sga-rest-only-compute-design.md`. Roadmap: `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. Do NOT run `dart format`.
- **REST es la única vía de datos/lifecycle de compute.** Eliminar los fallbacks gcloud; en fallo, propagar/mostrar el error existente (localizado). Sin fallback silencioso a gcloud.
- **Preservar todo el comportamiento salvo el fallback eliminado:** en los `*WithMethod`, el `try/catch` **externo** (`refreshInstances` + notificación éxito/fallo + `rethrow`) se conserva; `suspendInstanceWithMethod` conserva su `disconnectAllForInstance` inicial. En el diálogo manual, la ruta REST de éxito y la muestra de error no cambian.
- **`instancesProvider`:** la simplificación es **behavior-identical** (ambas ramas ya eran REST).
- **Higiene de imports:** eliminar imports que queden sin uso (p. ej. `import '../bridge/api.dart/gcloud.dart';` en `manual_instance_dialog.dart`) para no introducir `unused_import`.
- **Analyzer:** baseline ~85 issues (0 errores); **no introducir issues nuevas**. `flutter test` (suite completa) sigue verde.
- **Commits de código NO llevan trailer `Co-Authored-By`** (solo docs). Rama `27H1-Preview`.
- **NO tocar en SG-A (diferido):** `GcpApiMethod`/`apiMethodProvider`/`setMethod`/`client_lib_test_screen`; código muerto Rust (`gcloud.rs`) + `api.rs` + regen bridge; `listProjectsForAccount`/`get_projects_for_account`; fila "gcloud CLI requerido"/checks Doctor; migrar el diálogo manual a `localizedError`.

---

### Task 1: REST-only en compute (Dart)

Elimina los fallbacks gcloud de lifecycle y del diálogo manual, y simplifica `instancesProvider`. No hay test headless viable (el bridge no se linka en `flutter test`); la verificación es analyzer + suite verde (no-regresión). El QA real va en la Task 2.

**Files:**
- Modify: `lib/src/features/gcloud_provider.dart` (los 5 `*WithMethod` en ~1216-1380; `instancesProvider` en ~343-383)
- Modify: `lib/src/features/manual_instance_dialog.dart` (~1-113)

**Interfaces:**
- Consume (ya existentes, REST): `startInstanceClientLib`/`stopInstanceClientLib`/`suspendInstanceClientLib`/`resumeInstanceClientLib`/`resetInstanceClientLib`, `listInstances`, `getInstanceClientLib`.
- Deja de llamar (quedan como código muerto para SG-E): `startInstance`/`stopInstance`/`suspendInstance`/`resumeInstance`/`resetInstance` (gcloud CLI), `getInstanceGcloud`, `listInstancesClientLib` (la rama redundante).

- [ ] **Step 1: Lifecycle — quitar el fallback gcloud en los 5 `*WithMethod`**

En `lib/src/features/gcloud_provider.dart`, en cada uno de `startInstanceWithMethod`, `stopInstanceWithMethod`, `suspendInstanceWithMethod`, `resumeInstanceWithMethod`, `resetInstanceWithMethod`, sustituir el `try/catch` **interno** por la llamada REST directa. Patrón (ejemplo `start`):

Antes:
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
Aplicar igual a los otros 4, usando su `*InstanceClientLib` correspondiente: `stopInstanceClientLib`, `suspendInstanceClientLib`, `resumeInstanceClientLib`, `resetInstanceClientLib`. **No tocar** el `try/catch` externo (con `refreshInstances`, `NotificationService().notifyLifecycleOperation(...)` de éxito/fallo y `rethrow`), ni el `disconnectAllForInstance` inicial de `suspendInstanceWithMethod`.

- [ ] **Step 2: Simplificar `instancesProvider` + comentarios obsoletos**

En `lib/src/features/gcloud_provider.dart` (~343-383), reemplazar el cuerpo del provider y su comentario de cabecera. Antes:

```dart
// Provider para la lista de instancias (account-aware, CLI for active account)
final instancesProvider = FutureProvider<List<GcpInstance>>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), () {
    link.close();
    ref.invalidateSelf();
  });
  ref.onDispose(() => timer.cancel());

  // Watch account so we re-fetch when account changes
  ref.watch(accountProvider);

  final projectId = ref.watch(selectedProjectProvider);
  if (projectId == null) return [];

  try {
    // Use CLI which respects the active gcloud account
    return await listInstances(projectId: projectId);
  } catch (cliError) {
    debugPrint('CLI instances failed for $projectId: $cliError');
    try {
      // Fallback to REST
      final clientLibInstances = await listInstancesClientLib(projectId: projectId);
      return clientLibInstances.map((inst) => GcpInstance(
        name: inst.name,
        status: inst.status,
        zone: inst.zone,
        machineType: inst.machineType,
        cpuCount: inst.cpuCount,
        memoryMb: inst.memoryMb,
        diskGb: inst.diskGb,
        labels: inst.labels,
        osLoginEnabled: inst.osLoginEnabled,
        isWindows: inst.isWindows,
      )).toList();
    } catch (restError) {
      debugPrint('REST fallback also failed for $projectId: $restError');
      rethrow;
    }
  }
});
```
Después:
```dart
// Provider para la lista de instancias (account-aware, vía REST del cliente Rust).
final instancesProvider = FutureProvider<List<GcpInstance>>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), () {
    link.close();
    ref.invalidateSelf();
  });
  ref.onDispose(() => timer.cancel());

  // Watch account so we re-fetch when account changes
  ref.watch(accountProvider);

  final projectId = ref.watch(selectedProjectProvider);
  if (projectId == null) return [];

  // listInstances() va por el cliente REST de Rust (sigue la cuenta activa). En
  // fallo propagamos: una lista vacía ocultaría el problema real.
  try {
    return await listInstances(projectId: projectId);
  } catch (e) {
    debugPrint('Instance listing failed for $projectId: $e');
    rethrow;
  }
});
```

- [ ] **Step 3: Diálogo manual — quitar el fallback gcloud**

En `lib/src/features/manual_instance_dialog.dart`, reemplazar el bloque REST+fallback (líneas ~63-112) por solo la ruta REST con el error mostrado en su `catch`. Antes: el `try` REST hace `setState(...); return;` y su `catch` solo hace `debugPrint(... trying gcloud ...)`, seguido de un segundo `try` "Fallback to gcloud CLI" con `getInstanceGcloud` y un `catch` que fija `_error`. Después:

```dart
    // Look up the instance via the REST API.
    try {
      final instance = await getInstanceClientLib(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
      );

      setState(() {
        _foundInstance = instance;
        _usedMethod = 'REST API';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('AnyhowException(', '').replaceAll(')', '');
        _isLoading = false;
      });
    }
```
Eliminar por completo el bloque "Fallback to gcloud CLI" (`getInstanceGcloud` + el `setState` con `_usedMethod = 'gcloud CLI'`) y el `return;` del `try` REST. Actualizar el doc-comment de clase (línea ~10) de `First tries REST API, then falls back to gcloud CLI.` a `Looks up an instance via the REST API.`

- [ ] **Step 4: Eliminar imports que queden sin uso**

En `manual_instance_dialog.dart`, tras quitar `getInstanceGcloud`/`GcpInstance`, el import `import '../bridge/api.dart/gcloud.dart';` (línea 5) probablemente queda sin uso. Verificar que ningún símbolo de ese import se use aún en el archivo y, si no, eliminar la línea. (El paso 5 lo confirma: `unused_import` = quitarlo.)

- [ ] **Step 5: Analyzer — 0 issues nuevas**

Run: `flutter analyze 2>&1 | tail -8`
Expected: 0 errores; el recuento de issues **no** sube respecto al baseline (~85). Si aparece `unused_import` en algún archivo tocado, eliminar ese import y re-correr.

- [ ] **Step 6: Suite completa — sin regresión**

Run: `flutter test 2>&1 | tail -12`
Expected: la suite sigue verde (los tests existentes, incl. `es_overflow_test` que pompea `ManualInstanceDialog`, no referencian los fallbacks eliminados).

- [ ] **Step 7: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/gcloud_provider.dart lib/src/features/manual_instance_dialog.dart
git commit -m "refactor(gcloud): REST-only for compute data + lifecycle (drop gcloud fallbacks)"
```

---

### Task 2: Checklist de QA manual

Las llamadas REST no son testeables headless (bridge no linkado); esta lista cubre lo que un humano debe verificar en una VM real.

**Files:**
- Create: `docs/superpowers/plans/2026-08-12-sga-rest-only-compute-manual-qa.md`

- [ ] **Step 1: Confirmar la verja**

Run: `flutter analyze 2>&1 | tail -6` — Expected: 0 errores, sin issues nuevas.
Run: `flutter test 2>&1 | tail -6` — Expected: suite verde.

- [ ] **Step 2: Escribir el checklist**

Crear `docs/superpowers/plans/2026-08-12-sga-rest-only-compute-manual-qa.md`:

```markdown
# QA manual — SG-A: REST-only en compute

Las operaciones de datos/lifecycle van por el bridge (no testeables en `flutter test`).
Verificar a mano contra una VM real, con `gcloud` instalado (auth aún lo usa):

- [ ] Lifecycle por REST: **Iniciar / Detener / Reiniciar / Suspender / Reanudar** una VM funcionan y muestran su notificación de éxito.
- [ ] Fallo de lifecycle: forzar un error (p. ej. permiso insuficiente) y confirmar que aparece el **error localizado** en el snackbar y **no** se cae a gcloud (sin proceso gcloud en segundo plano para la operación).
- [ ] Búsqueda manual de instancia (diálogo "añadir instancia"): un nombre **válido** la encuentra (método mostrado: "REST API"); un nombre **inexistente** muestra el error, sin fallback gcloud.
- [ ] Dashboard: la **lista de instancias** y el **selector de proyectos** siguen poblando con normalidad.
- [ ] Ningún flujo de datos/lifecycle lanza un proceso `gcloud compute …` (solo auth/túnel siguen usando gcloud en esta fase).
```

- [ ] **Step 3: Commit** (docs)

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-12-sga-rest-only-compute-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SG-A REST-only compute"
```

---

## Self-Review

**1. Spec coverage:**
- Lifecycle REST-only (5 `*WithMethod`, quitar fallback, preservar try/catch externo + disconnect de suspend) → Task 1 Step 1. ✓
- Búsqueda manual REST-only (quitar `getInstanceGcloud`, catch REST fija `_error`) → Task 1 Step 3. ✓
- `instancesProvider` simplificado + comentarios corregidos (behavior-identical) → Task 1 Step 2. ✓
- Higiene de imports (no `unused_import`) → Task 1 Steps 4-5. ✓
- Sin fallback silencioso; error localizado se propaga → Steps 1/3 + Global Constraints. ✓
- Diferidos (GcpApiMethod/test-screen, Rust/bridge, listProjectsForAccount, Doctor/dep row, localizedError del diálogo) → Global Constraints, no se tocan. ✓
- Verificación analyzer + suite + checklist QA manual → Task 1 Steps 5-6 + Task 2. ✓
- Dart-only, sin regen bridge → Global Constraints. ✓

**2. Placeholder scan:** Sin TBD/TODO. Los antes/después de lifecycle, `instancesProvider` y el diálogo son código concreto; el checklist es contenido completo. ✓

**3. Type consistency:** `*InstanceClientLib`/`listInstances`/`getInstanceClientLib` son las firmas REST existentes (consumidas). `instancesProvider` devuelve `Future<List<GcpInstance>>` igual que antes; `listInstances` ya devuelve `List<GcpInstance>` (no requiere el mapeo que se elimina). El diálogo mantiene `_foundInstance` como `GcpInstanceClientLib?` (lo que devuelve `getInstanceClientLib`). ✓
