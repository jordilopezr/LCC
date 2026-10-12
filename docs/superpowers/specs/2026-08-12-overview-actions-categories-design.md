# Diseño: agrupar por categorías los botones de acción de la Overview tab

**Fecha:** 2026-08-12
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Mejora de UI (Dart-only; sin Rust/bridge). Deuda pre-corte de 27H1.

## Objetivo

Hoy la Overview tab muestra sus **17 botones de acción en un único `Wrap` plano**, sin agrupación visual, lo que dificulta encontrar la acción correcta. Este trabajo los reorganiza en **3 categorías etiquetadas** (Enfoque A del brainstorming: sub-secciones etiquetadas), sin cambiar el comportamiento de ningún botón.

## Contexto

- **Estructura actual** (`lib/src/features/workspace/overview_tab.dart`, ~2093 líneas): bajo un título "Actions" (`Text` con `dashboardActionsTitle`, `fontSize: 18`, bold, línea ~341) hay un solo `Wrap(spacing: 16, runSpacing: 16)` (líneas ~346-1021) con 17 `_ActionButton` hijos.
- **Visibilidad:** solo **un** botón se renderiza condicionalmente (Mount SSHFS, envuelto en `if (!Platform.isWindows)`). Los otros 16 están siempre presentes; su disponibilidad se controla vía `onPressed: null` (habilitado/deshabilitado según `isRunning`/`isConnecting`/`isConnected`/`isSuspended`). **Ningún grupo puede quedar vacío** (cada categoría tiene ≥1 botón siempre presente), así que no hace falta lógica de sección vacía.
- **i18n:** arb-dir `lib/l10n` (`app_en.arb` plantilla + `app_es.arb`), clase `AppLocalizations`, salida `lib/l10n/gen`; se regenera con `flutter gen-l10n` y se commitea `lib/l10n/gen`. Registro ES neutro/impersonal.
- **Guardia de overflow:** `test/es_overflow_test.dart` ya pompea `OverviewTab` con un VM falso en `Locale('es')` a 3 tamaños (1280/1024/720) y falla ante RenderFlex overflow — cubre automáticamente los nuevos encabezados.

## Decisiones

| Decisión | Elección |
|---|---|
| Enfoque de presentación | **A — sub-secciones etiquetadas**: encabezado secundario + su propio `Wrap` por categoría, apiladas en un `Column`. (Descartados B colapsables / C sub-pestañas por añadir interacción/estado innecesarios.) |
| Nº de categorías | **3**: Acceso · Energía · Herramientas |
| Orden de las secciones | Acceso → Energía → Herramientas (acción de conexión primero, gestión de energía después, utilidades al final) |
| Orden dentro de cada sección | Se conserva el orden relativo actual de los botones |
| Extracción de archivo | **No** en este trabajo: reestructuración **in situ** (el `Wrap` pasa a `Column` de secciones), reutilizando un helper de encabezado. La extracción de `OverviewTab` en archivos más pequeños es deuda aparte, fuera de alcance. |
| Rust/bridge | Sin cambios |

## Diseño

### 1. Membresía de las 3 categorías

Los 17 botones (orden relativo conservado dentro de cada grupo):

- **Acceso / Conexión** — `dashboardActionsGroupAccess`
  1. Conectar RDP
  2. Conectar VNC
  3. Conectar SSH
  4. Abrir SFTP
  5. Custom Tunnel
  6. Base de datos
  7. Mount SSHFS *(solo si `!Platform.isWindows`)*
  8. Credenciales de Windows
  9. Conectar/Desconectar IAP (el toggle `isConnected`)
- **Energía / Estado de la VM** — `dashboardActionsGroupPower`
  1. Iniciar
  2. Detener
  3. Reiniciar
  4. Suspender
  5. Reanudar
- **Herramientas** — `dashboardActionsGroupTools`
  1. Diagnóstico
  2. Doctor
  3. Snapshots

Nota: respecto al `Wrap` plano actual, esto reubica el toggle Conectar/Desconectar (hoy tras Snapshots) al final de **Acceso**, y agrupa Diagnóstico/Doctor/Snapshots en **Herramientas**. El código de cada `_ActionButton` (icono, colores, `onPressed`, historial, snackbars) se mueve **verbatim** a su grupo; no se toca su lógica.

### 2. Estructura de widgets (in situ)

Reemplazar el único `Wrap(...)` por un `Column(crossAxisAlignment: CrossAxisAlignment.start)` con, por cada categoría: un encabezado + su `Wrap`. Esbozo:

```dart
Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    _actionSectionHeader(context, l10n.dashboardActionsGroupAccess),
    Wrap(spacing: 16, runSpacing: 16, children: [ /* botones de Acceso */ ]),
    const SizedBox(height: 20),
    _actionSectionHeader(context, l10n.dashboardActionsGroupPower),
    Wrap(spacing: 16, runSpacing: 16, children: [ /* botones de Energía */ ]),
    const SizedBox(height: 20),
    _actionSectionHeader(context, l10n.dashboardActionsGroupTools),
    Wrap(spacing: 16, runSpacing: 16, children: [ /* botones de Herramientas */ ]),
  ],
)
```

Helper reutilizable (fichero, arriba o junto a `_ActionButton`):

```dart
Widget _actionSectionHeader(BuildContext context, String label) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      label,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
```

- El título "Actions" (`dashboardActionsTitle`) se mantiene como cabecera global encima de las 3 secciones.
- El encabezado de sección es deliberadamente **secundario** (menor y atenuado, `titleSmall` + `onSurfaceVariant`) para no competir con el título "Actions".
- El `if (isConnecting) LinearProgressIndicator()` que hoy va justo tras el `Wrap` se conserva tras el nuevo `Column`.

### 3. Claves i18n nuevas (3, EN + ES, prefijo `dashboard*`)

Añadir junto a `dashboardActionsTitle` en ambos `.arb` (paridad obligatoria), y regenerar:

| Clave | EN | ES |
|---|---|---|
| `dashboardActionsGroupAccess` | `Access & connections` | `Acceso y conexiones` |
| `dashboardActionsGroupPower` | `Power & state` | `Energía y estado` |
| `dashboardActionsGroupTools` | `Tools` | `Herramientas` |

## Testing

- **Guardia de overflow (existente):** `test/es_overflow_test.dart` ya cubre `OverviewTab` en ES a 1280/1024/720 — debe seguir verde con los encabezados nuevos (sin overflow).
- **Test de widget nuevo:** pompea `OverviewTab(target: <VM falso>)` (patrón de `test/workspace_provider_test.dart`/el render-check de SP2) dentro de `ProviderScope` + `MaterialApp` con `AppLocalizations` en inglés y verifica:
  - se encuentran los 3 textos de encabezado (`Access & connections`, `Power & state`, `Tools`);
  - sigue presente un botón representativo de cada grupo (p. ej. label de Conectar SSH en Acceso, Iniciar en Energía, Doctor en Herramientas).
  No se asierta el conteo exacto de botones (frágil por el gate de Windows en SSHFS).
- **Suite + analyzer:** `flutter test` verde; `flutter analyze` sin issues nuevas (baseline ~85).
- **QA manual (ojo humano):** encabezados y botones en EN y ES, en ventana estrecha, no se cortan ni desbordan.

## Alcance / fuera de alcance

- **Dentro:** reagrupar los 17 botones de `OverviewTab` en 3 sub-secciones etiquetadas (Enfoque A); helper `_actionSectionHeader`; 3 claves i18n EN+ES + regen `lib/l10n/gen`; test de widget de encabezados; conservar intacto el comportamiento de cada botón.
- **Fuera:** cambiar la lógica/estilo/colores de cualquier botón; secciones colapsables o sub-pestañas (B/C, descartados); extraer `OverviewTab` a archivos separados (deuda aparte); cualquier otra superficie; Rust/bridge; la deuda de quitar `gcloud`.

## Verificación

- `flutter test test/es_overflow_test.dart` verde (OverviewTab a 3 tamaños, sin overflow) y `flutter test` (suite completa) verde, incluido el nuevo test de encabezados.
- `flutter analyze` sin issues nuevas.
- Los 3 encabezados aparecen en EN y ES con paridad de claves; `lib/l10n/gen` regenerado y commiteado.
