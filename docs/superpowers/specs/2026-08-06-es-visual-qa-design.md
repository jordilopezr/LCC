# Diseño: QA visual ES — overflow de la Overview tab + ancho estrecho (i18n SP2)

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Test + fixes de layout (Dart-only; sin Rust/bridge). Sub-proyecto **SP2** de la i18n restante (SP1 = notificaciones, hecho).

## Objetivo

Los textos en español son ~20-30% más largos que en inglés y pueden desbordar Rows/Columns ajustados. `test/es_overflow_test.dart` ya renderiza 10 **diálogos** en `Locale('es')` a 2 tamaños y falla ante overflow (está verde). Este trabajo **extiende** ese harness a la superficie grande sin cubrir — la **Overview tab** — y a un **ancho estrecho** realista de panel, y arregla los overflows en español que aparezcan.

## Contexto

- **Harness existente** (`test/es_overflow_test.dart`): mapa `_dialogs` de 10 diálogos construidos directamente; `_pumpInSpanish(tester, widget, size)` los monta en `MaterialApp(locale: Locale('es'))` → `Scaffold(body: child)` a cada tamaño; `_expectNoOverflow` recoge excepciones vía `tester.takeException()` y **falla solo** si el texto contiene `"overflowed"` (tolera errores del bridge/plugins que no funcionan en `flutter test`). Tamaños actuales: `desktop 1280x800`, `small 1024x640`. 2 diálogos en `_needsLiveApp` (skip).
- **`OverviewTab`** (`lib/src/features/workspace/overview_tab.dart:32`, `ConsumerWidget`, `const OverviewTab({required this.target})` con `target: ProjectAwareInstance`): la superficie mayor sin cubrir (~11 `_ActionButton` con labels ES + estado del VM). Observa providers (bridge) → el harness tolera esos errores; su chrome maqueta.
- **Ancho de panel real:** el `WorkspacePanel` va en un `Expanded` junto a un `ResourceTree` de 300px (`main.dart:527-533`); a 1024 su ancho efectivo es ~720px. El tamaño más pequeño actual (1024 a ancho completo) no estresa layouts a ancho de panel.
- **VM falso construible** (patrón de `test/workspace_provider_test.dart`): `ProjectAwareInstance(projectId, instance: GcpInstance(name, status, zone, machineType, cpuCount, memoryMb, diskGb, labels, osLoginEnabled, isWindows))`.

## Decisiones

| Decisión | Elección |
|---|---|
| Superficie nueva | `OverviewTab(target: <VM falso>)` en el harness |
| Tamaño nuevo | `narrow 720x800` (ancho efectivo del panel), aplicado a todas las superficies del harness |
| VM falso | `ProjectAwareInstance` con nombre largo (tipo español) para estresar el ancho |
| Fixes | **Dirigidos por hallazgos**: por cada overflow que reporte el test extendido, fix mínimo de layout (Wrap/Flexible/Expanded/ellipsis) en el widget culpable |
| Providers de OverviewTab | El harness tolera errores no-overflow; si el área de botones no renderiza headless, sembrar el estado mínimo o aceptar cobertura del chrome |
| Rust/bridge | Sin cambios |

## Diseño

### 1. Extender el harness (`test/es_overflow_test.dart`)

- Añadir el tamaño estrecho al mapa `_sizes`:
  ```dart
  'narrow 720x800': Size(720, 800),
  ```
- Añadir un helper de VM falso y `OverviewTab` a `_dialogs` (rebautizable a "surfaces", pero conservar la estructura):
  ```dart
  import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
  import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
  import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';

  ProjectAwareInstance _fakeVm() => ProjectAwareInstance(
        projectId: _project,
        instance: GcpInstance(
          name: 'instancia-de-produccion-backup-01',
          status: 'RUNNING', zone: _zone, machineType: 'e2-standard-4',
          cpuCount: 4, memoryMb: 16384, diskGb: 100, labels: const [],
          osLoginEnabled: false, isWindows: false,
        ),
      );
  // en el mapa _dialogs:
  'OverviewTab': () => OverviewTab(target: _fakeVm()),
  ```
  (Ajustar los campos de `GcpInstance`/`ProjectAwareInstance` a las firmas reales, verificadas contra `workspace_provider_test.dart`.) `OverviewTab` se pompea con el mismo `_pumpInSpanish` (ya envuelve en `Scaffold(body: child)`).
- Si al correr, `OverviewTab` lanza una excepción **de layout no-overflow** que rompe el pump (no un mero error de bridge async), sembrar el provider mínimo necesario en el `ProviderScope` de `_pumpInSpanish` (override) o añadir `OverviewTab` a un conjunto skip documentado — pero el objetivo es que renderice su chrome de botones.

### 2. Arreglar los overflows (dirigido por hallazgos)

Correr `flutter test test/es_overflow_test.dart`. Por **cada** fallo `<Superficie> overflowed in Spanish:` :
- Localizar el widget culpable (el mensaje de Flutter indica el `RenderFlex`/dirección y los píxeles).
- Aplicar el fix mínimo, siguiendo el precedente del repo (SettingsDialog: `Row`→`Wrap`):
  - `Row` que desborda horizontalmente → `Wrap`, o envolver el/los `Text` en `Flexible`/`Expanded` con `overflow: TextOverflow.ellipsis`.
  - `Column` que desborda vertical → hacer scrollable el contenedor o `Flexible`.
  - Texto largo en un chip/botón → `overflow: TextOverflow.ellipsis` + `maxLines`.
- Re-correr hasta que el test extendido esté verde. Ceñirse al fix de layout; no rediseñar.

**Nota:** puede que no haya ningún overflow (la Overview tab + ancho estrecho ya limpios en ES) — en ese caso SP2 es solo la extensión de cobertura (guardia de regresión), igualmente válida.

## Testing

- El propio `es_overflow_test` extendido es la verificación: verde = sin overflow ES en las superficies cubiertas (10 diálogos + OverviewTab) a 3 tamaños (1280, 1024, 720).
- La suite completa (`flutter test`) sigue verde.
- QA manual sigue cubriendo lo bridge-gated (WindowsCredentials/Sshfs skipped; dashboard completo; tab-strip; Custom Tunnel dialog).

## Alcance / fuera de alcance

- **Dentro:** extender `es_overflow_test` (tamaño 720 + OverviewTab) + arreglar los overflows ES que reporte.
- **Fuera:** tab-strip del `WorkspacePanel` (siembra de sesiones), diálogo Custom Tunnel (inline `showDialog`, requiere extracción/taps), dashboard completo (headless inviable) — diferidos; Rust/bridge; rediseños de layout más allá del fix de overflow.

## Verificación

- `flutter test test/es_overflow_test.dart` verde (con el tamaño 720 + OverviewTab) y `flutter test` (suite) verde.
- `flutter analyze` sin issues nuevas.
