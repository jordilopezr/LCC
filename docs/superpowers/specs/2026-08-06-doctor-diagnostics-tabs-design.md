# Diseño: Doctor + Diagnostics como pestañas del workspace (sub-proyecto B)

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature UI (Dart-only; sin Rust, sin regen de bridge). Sub-proyecto **B** de dos (A = unificación del backend de detección, ya hecho).

## Objetivo

El Connectivity Doctor y el panel de Diagnostics se abren hoy como **diálogos modales**: cada apertura arranca de cero y al cerrarlos se pierde el reporte. El usuario quiere **resolver un problema y volver al reporte sin relanzarlo**. Este trabajo los integra como **pestañas del workspace** (junto a SSH terminal y SFTP), reusando el `IndexedStack` que ya mantiene vivo el State de cada pestaña off-screen, de modo que el reporte persiste al cambiar de pestaña y volver.

## Contexto

- **Modelo de workspace** (`workspace/`): `enum SessionType { overview, ssh, sftp }`; `WorkspaceSession { id, type, target: ProjectAwareInstance, pinned, groupId }`. El `WorkspaceNotifier` expone `openOverview`/`openSsh`/`openSftp` (overview y sftp deduplican por `type + vmKey` y enfocan; ssh siempre añade). `WorkspacePanel` renderiza una `_TabStrip` + un `IndexedStack` cuyo `_content(s)` hace `switch (s.type)` → `OverviewTab`/`SshTerminalTab`/`SftpTab`.
- **Patrón de cuerpo de pestaña ya establecido:** `SftpTab`/`SshTerminalTab` son `ConsumerStatefulWidget { final WorkspaceSession session; }` que arrancan en `initState` y renderizan; `SftpDualView` fue extraído como cuerpo reutilizable. B sigue ese patrón.
- **Layout:** el dashboard es un `Row` fijo `ResourceTree` (300px) + `Expanded(WorkspacePanel())` (`main.dart:531`) → **el WorkspacePanel siempre está visible**: una pestaña abierta desde cualquier superficie aparece al instante.
- **Los dos diálogos:**
  - `ConnectivityDoctorDialog(projectId, zone, instanceName)` (`connectivity_doctor.dart`): State `_report/_isRunning/_error`, auto-run en `initState`, action bar con "Run Again"/refresh + Export + chips de resumen, cuerpo con resultados por categoría, footer. `showConnectivityDoctor(context, {projectId, zone, instanceName})`.
  - `DiagnosticsPanel(params: DiagnosticsParams)` (`diagnostics_panel.dart`): un `TabController` con `TabBar`/`TabBarView` sobre 3 sub-pestañas (`SerialConsoleTab`/`VmDiagnosticsTab`/`AuditLogsTab`). `showDiagnosticsPanel(context, {projectId, zone, instanceName})`.
- **Sin túnel IAP:** Doctor y Diagnostics son puras llamadas REST a GCP (no abren túnel), a diferencia de SSH/SFTP.
- **Rust:** A ya unificó la detección (`detect_guest_agent`); B **no toca Rust ni el bridge**.

## Decisiones

| Decisión | Elección |
|---|---|
| Puntos de lanzamiento | **Solo desde el workspace** abren pestaña: los 2 botones del Overview + el "Run Doctor" del diálogo de error de Custom Tunnel. El **menú contextual del ResourceTree** (`main.dart`) **conserva sus diálogos** (respeta su diseño "click derecho ≠ abrir vista"). |
| Diálogos modales | **Se conservan** `showConnectivityDoctor`/`showDiagnosticsPanel` (para el menú contextual), refactorizados para envolver el **mismo cuerpo extraído** que usan las pestañas → sin duplicar lógica. |
| Cuerpo reutilizable | Extraer `ConnectivityDoctorView` y `DiagnosticsView`; el diálogo = header + botón cerrar + View; la pestaña = View a secas. |
| Dedup | `openDoctor`/`openDiagnostics` deduplican por `type + vmKey` y enfocan la existente (una sola pestaña Doctor y una sola Diagnostics por VM → volver al reporte). |
| Túnel | Doctor/Diagnostics **no** sostienen túnel; predicado `_holdsTunnel(t) = ssh‖sftp` reemplaza el proxy `type != overview` en `close()` y `hasLiveSessions`. |
| Re-ejecución | El botón "Run Again"/refresh del Doctor ya existe; en Diagnostics cada sub-pestaña tiene su propio refresh. Persistencia = el State vive en el `IndexedStack`. |
| Rust / bridge | Sin cambios. |

## Diseño

### 1. Extracción de cuerpos (los diálogos siguen funcionando)

**`connectivity_doctor.dart`** — mover el State y el contenido a un widget nuevo:
- `class ConnectivityDoctorView extends ConsumerStatefulWidget { final String projectId, zone, instanceName; }` que **contiene** el State actual (`_report/_isRunning/_error`, `_runDoctor` con auto-run en `initState`, `_exportReport`, `_executeFix`) y cuyo `build` devuelve el `Column` de **action bar + `Divider` + `Expanded(cuerpo)` + footer** (todo lo actual **menos** el `Dialog`/`ConstrainedBox` y el header con botón cerrar).
- `ConnectivityDoctorDialog` pasa a ser un envoltorio: `Dialog(ConstrainedBox(Column[ header con título+instancia+cerrar, Expanded(ConnectivityDoctorView(...)) ]))`.
- Los widgets auxiliares (`_SummaryChip`, `_DoctorCheckTile`) y los helpers de categoría se mueven/quedan accesibles para la View.
- `showConnectivityDoctor` **sin cambios de firma**.

**`diagnostics_panel.dart`** — análogo:
- `class DiagnosticsView extends ConsumerStatefulWidget { final DiagnosticsParams params; }` con el `TabController` (mixin `SingleTickerProviderStateMixin`) y el `build` = `Column[ TabBar, Expanded(TabBarView[SerialConsoleTab, VmDiagnosticsTab, AuditLogsTab]) ]` (menos `Dialog`/header/cerrar).
- `DiagnosticsPanel` pasa a ser `Dialog(SizedBox(Column[ header con título+subtítulo+cerrar, Expanded(DiagnosticsView(params)) ]))`.
- Sub-pestañas intactas. `showDiagnosticsPanel` **sin cambios de firma**.

### 2. Widgets de pestaña (nuevos, en `workspace/`)

- `workspace/doctor_tab.dart`: `class DoctorTab extends StatelessWidget { final WorkspaceSession session; ... build => ConnectivityDoctorView(projectId: session.target.projectId, zone: session.target.zone, instanceName: session.target.name); }`.
- `workspace/diagnostics_tab.dart`: `class DiagnosticsTab extends StatelessWidget { final WorkspaceSession session; ... build => DiagnosticsView(params: DiagnosticsParams(projectId: session.target.projectId, zone: session.target.zone, instanceName: session.target.name)); }`.

(`ProjectAwareInstance` expone `projectId`, `zone`, `name` — usados igual que en `SftpTab`.)

### 3. Modelo + notifier

**`workspace/workspace_session.dart`:**
```dart
enum SessionType { overview, ssh, sftp, doctor, diagnostics }
```

**`workspace/workspace_provider.dart`:**
- Predicado privado: `bool _holdsTunnel(SessionType t) => t == SessionType.ssh || t == SessionType.sftp;`
- `String openDoctor(ProjectAwareInstance vm)` — dedup por `type == doctor && vmKey`, enfoca si existe, si no `_add(WorkspaceSession(type: doctor, target: vm))` **sin** `holdsTunnel`.
- `String openDiagnostics(ProjectAwareInstance vm)` — igual con `type == diagnostics`.
- En `close()`: reemplazar `if (session.type != SessionType.overview)` por `if (_holdsTunnel(session.type))` (Doctor/Diagnostics no liberan túnel).
- En `hasLiveSessions`: reemplazar `s.type != SessionType.overview` por `_holdsTunnel(s.type)` (Doctor/Diagnostics no cuentan como sesión "viva" para el guardado de cierre del workspace).

### 4. Panel (`workspace/workspace_panel.dart`)

Añadir los casos que faltan en los tres `switch` exhaustivos (imports de los dos nuevos tabs):
- `_content(s)`: `case SessionType.doctor: return DoctorTab(session: s);` y `case SessionType.diagnostics: return DiagnosticsTab(session: s);`.
- `_PinnedZone._icon(t)`: `doctor => Icons.medical_services_outlined`, `diagnostics => Icons.build_circle_outlined` (mismos iconos que hoy usan los botones/diálogos).
- `_tabLabel`: `doctor => l10n.workspaceTabDoctor`, `diagnostics => l10n.workspaceTabDiagnostics`.

### 5. Wiring (solo `workspace/overview_tab.dart`; `main.dart` intacto)

- L638 `showDiagnosticsPanel(context, ...)` → `ref.read(workspaceProvider.notifier).openDiagnostics(target)`.
- L655 `showConnectivityDoctor(context, ...)` → `ref.read(workspaceProvider.notifier).openDoctor(target)`.
  - Nota: en este scope `target` es un `ProjectAwareInstance` (ya se pasa igual a `openSsh(target)`/`openSftp(target)` en L432/455); el `projectId: selectedProject` que hoy usan los diálogos equivale a `target.projectId`, así que la pestaña lo obtiene de `target` sin necesitar `selectedProject`.
- L1256 (dentro de `_showCustomTunnelError`, acción "Run Doctor"): mantener `Navigator.pop(dialogContext);` y sustituir la llamada por `ref.read(workspaceProvider.notifier).openDoctor(widget.target);` (`widget.target` es el VM del Overview; `instanceName` del método == `widget.target.name`). `workspaceProvider` ya está importado (se usa en `openSsh`/`openSftp` L432/455).
- Tras el cambio, `overview_tab.dart` deja de referenciar `showConnectivityDoctor`/`showDiagnosticsPanel`; retirar esos imports si quedan sin uso (los diálogos siguen existiendo, invocados desde `main.dart`).

### 6. i18n

Dos claves nuevas en `lib/l10n/app_en.arb` y `app_es.arb`, y `flutter gen-l10n`:
- `workspaceTabDoctor`: EN `"Doctor"`, ES `"Doctor"`.
- `workspaceTabDiagnostics`: EN `"Diagnostics"`, ES `"Diagnóstico"`.

## Testing

- **Notifier** (`test/workspace_provider_test.dart`, extendiendo el patrón con `_FakeConnections` que registra `disconnect()` y el helper `_vm(name)`):
  - `openDoctor`/`openDiagnostics` deduplican por VM y enfocan (segunda apertura no añade pestaña).
  - `hasLiveSessions` es `false` con solo overview/doctor/diagnostics abiertas.
  - `close()` de una pestaña doctor o diagnostics **no** registra ningún `disconnect` en el fake (no tienen túnel).
- **Widget smoke** (`test/workspace_panel_test.dart`): con una sesión doctor/diagnostics activa, `WorkspacePanel` construye `DoctorTab`/`DiagnosticsTab` sin excepción y la etiqueta de la tab muestra el nombre del VM + el tipo.
- Sin cambios en Rust ni bridge → `cargo` no interviene.

## Alcance / fuera de alcance

- **Dentro:** extracción de los cuerpos, dos widgets de pestaña, `SessionType` + `openDoctor`/`openDiagnostics` + predicado de túnel, casos de `switch` del panel, re-wiring de los 3 call-sites del Overview, 2 claves i18n, tests de notifier + smoke.
- **Fuera:** el menú contextual del ResourceTree (`main.dart`) sigue con diálogos (sin cambios); ninguna modificación de la lógica interna de los checks/sub-pestañas; ningún cambio en Rust/bridge; pin/group de las nuevas pestañas funciona por herencia del modelo existente (sin trabajo extra).

## Verificación

- `flutter test` (nuevos tests de notifier + smoke + suite existente en verde).
- `flutter analyze` (0 errores).
- `flutter build linux --release` para el bundle de pruebas.
- Sin `cargo` (Dart-only).
