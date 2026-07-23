# Diseño: Gestión de pestañas del workspace (overflow, pin, grupos) — 27H1

**Fecha:** 2026-07-23
**Rama:** `27H1`
**Estado:** Aprobado

## Objetivo

El `_TabStrip` actual (`lib/src/features/workspace/workspace_panel.dart`) es un `ListView` horizontal plano sin control de desbordamiento: cuando se abren más pestañas de las que caben en el ancho del panel, las nuevas quedan fuera de pantalla **sin forma de alcanzarlas** (defecto encontrado en QA 2026-07-23). Tampoco hay reordenación ni organización. Este trabajo convierte la tira de pestañas en una gestión estilo navegador: **desbordamiento navegable** (flechas + menú "todas las pestañas" + auto-scroll a la activa), **pestañas ancladas** (pin), y **grupos con nombre y color estilo MS Edge**, además de **reordenación por arrastre**.

## Contexto del código actual

- `WorkspacePanel` (`workspace_panel.dart:10`) = `Column(_TabStrip | Divider | Expanded(IndexedStack))`. El `IndexedStack` mantiene montadas todas las sesiones (invariante que mantiene vivas las terminales SSH) — **no se toca**.
- `_TabStrip` (`workspace_panel.dart:52`) = `SizedBox(height:40, child: ListView(horizontal, [_Tab...]))`. Cada `_Tab` es label completo + botón ×. Sin scroll visible, sin reordenar.
- `WorkspaceNotifier`/`WorkspaceState` (`workspace_provider.dart`): `List<WorkspaceSession> sessions`, `String? activeId`, más `focus/close/reorder` (este último **existe pero no está cableado a la UI**) y `WorkspaceSession? get activeSession`. El conteo de referencias de túnel por VM vive aquí (`_tunnelRefs`, `disconnect(name,22)` al llegar a 0).
- `WorkspaceSession` (`workspace_session.dart`): inmutable `{ String id; SessionType type; ProjectAwareInstance target; String get vmKey }`.
- i18n con paridad EN/ES obligatoria (`lib/l10n/app_en.arb` plantilla + `app_es.arb`), registro neutro, elipsis `…`, ediciones append-only, `@key` de metadatos solo en EN.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Modelo de organización | Tira plana estilo navegador (no agrupación jerárquica por instancia) |
| Desbordamiento | Flechas `‹ ›` + menú desplegable "todas las pestañas" `⌄` + auto-scroll de la pestaña activa a la vista |
| Anclar (pin) | Sí: zona fija a la izquierda, solo icono, siempre visible, cierre solo por menú contextual |
| Grupos | Manuales estilo MS Edge: con nombre + color; **siempre expandidos** (sin colapsar a chip); color autoasignado pero cambiable de una paleta fija de 6 |
| Atajo de grupo | "Agrupar todas las pestañas de esta VM" en el menú contextual de pestaña |
| Reordenar | Arrastre **solo dentro de una zona** (ancladas↔ancladas, dentro de un grupo, sueltas↔sueltas). Cambiar de grupo o anclar se hace por menú, no por arrastre |
| Persistencia | Solo durante la sesión; sin restauración al reabrir la app (coherente con la decisión del workspace) |

## 1. Modelo de datos

`WorkspaceState` añade `List<WorkspaceGroup> groups`. Nuevo tipo:

```dart
enum GroupColor { blue, purple, green, amber, red, grey }

class WorkspaceGroup {
  final String id;
  final String name;
  final GroupColor color;
  const WorkspaceGroup({required this.id, required this.name, required this.color});
  WorkspaceGroup copyWith({String? name, GroupColor? color});
}
```

`WorkspaceSession` añade dos campos con `copyWith`: `bool pinned` (por defecto `false`) y `String? groupId` (por defecto `null`). `GroupColor` se mapea a colores conscientes del tema en la capa de UI (no se guardan `Color` en el estado).

**`sessions` es el orden visual canónico.** Toda mutación conserva dos invariantes:

1. **Ancladas primero:** toda sesión con `pinned == true` precede a toda sesión con `pinned == false`.
2. **Grupos contiguos:** las sesiones que comparten un mismo `groupId != null` son contiguas en la lista.

Reglas de mantenimiento:
- Anclar una sesión la mueve al final del bloque de ancladas; desanclar la mueve al inicio del bloque de no-ancladas. Una sesión anclada no puede pertenecer a un grupo (anclar la saca de su grupo).
- Añadir una sesión a un grupo la mueve junto al bloque de ese grupo (al final del bloque). Quitarla (o cerrar/deshacer el grupo) la deja como suelta en su posición relativa.
- La reordenación por arrastre está restringida a mover dentro de la misma zona contigua (bloque de ancladas, bloque de un grupo, o el tramo de sueltas entre grupos), de modo que las invariantes se mantienen por construcción.

**El conteo de referencias de túnel no cambia.** Anclar/agrupar son puras operaciones de UI sobre las mismas sesiones. Los cierres masivos (`closeGroup`, `closeOthers`, `closeToRight`) invocan el `close(id)` existente por cada sesión, así que el túnel se libera exactamente igual que hoy.

## 2. Métodos del `WorkspaceNotifier`

Nuevos, todos preservando las invariantes y devolviendo estado inmutable:

- `togglePin(String id)` — ancla/desancla; reubica según la regla de ancladas; si se ancla y estaba en un grupo, lo saca.
- `newGroupFromSession(String id)` — crea un `WorkspaceGroup` (color autoasignado: el primero de la paleta no usado, o rotación si todos están usados; nombre por defecto = nombre de la VM de esa sesión) y mete la sesión.
- `groupByVm(String vmKey)` — crea un grupo con todas las sesiones **no ancladas** de esa VM (nombre = nombre de la VM).
- `addToGroup(String sessionId, String groupId)` / `removeFromGroup(String sessionId)`.
- `renameGroup(String groupId, String name)` / `recolorGroup(String groupId, GroupColor color)`.
- `ungroup(String groupId)` — disuelve el grupo (sus sesiones quedan sueltas y contiguas donde estaban); elimina el `WorkspaceGroup`.
- `closeGroup(String groupId)` — cierra todas las sesiones del grupo (usa `close` por sesión) y elimina el grupo.
- `closeOthers(String id)` / `closeToRight(String id)` — cierres masivos; nunca cierran pestañas ancladas.
- `reorder(...)` (existente) se extiende/valida para operar solo dentro de una zona.

Un grupo que se queda vacío (p. ej. su última sesión se cierra o se saca) se elimina automáticamente.

## 3. Renderizado (reescritura de `_TabStrip`)

La tira de 44 px se compone de tres regiones en un `Row`:

1. **Zona anclada (fija, no scrollable):** `Row` de pestañas solo-icono (icono del tipo de sesión + punto de color del grupo si aplica), separada por un divisor vertical. Siempre visible.
2. **Región desplazable (`Expanded`):** un área con `ScrollController` horizontal que recorre `sessions` (las no ancladas) en orden, dibujando:
   - cada **grupo** como un segmento de color: cabecera-chip con el nombre + sus pestañas miembro contiguas, con fondo tenue del color del grupo y la cabecera en el color pleno;
   - las **pestañas sueltas** entre grupos.
   Las **flechas `‹ ›`** aparecen solo cuando hay desbordamiento (el contenido excede el viewport) y desplazan por pasos. La pestaña **activa o recién abierta se auto-desplaza a la vista** con `Scrollable.ensureVisible`/animateTo — este es el arreglo del defecto.
3. **Botón "todas las pestañas" `⌄`:** abre un `PopupMenu`/overlay que lista **todas** las pestañas (agrupadas bajo encabezados por grupo, luego sueltas, luego ancladas), cada una enfocable con un clic. Resuelve encontrar una pestaña concreta entre muchas.

Descomposición en unidades pequeñas con una responsabilidad cada una: `_PinnedZone`, `_ScrollableTabs` (posee el `ScrollController`, las flechas y el auto-scroll), `_TabGroup` (cabecera + miembros de un grupo), `_Tab` (pestaña individual, ya existe, se extiende), `_AllTabsMenu`.

## 4. Interacciones

- **Clic izquierdo** = enfocar; **×** = cerrar; **arrastrar** = reordenar dentro de la zona.
- **Menú contextual de pestaña** (clic derecho): Anclar/Desanclar · Añadir a grupo ▸ (submenú con los grupos existentes) · Nuevo grupo desde esta pestaña · Agrupar todas las pestañas de esta VM · Cerrar · Cerrar las demás · Cerrar las de la derecha.
- **Menú contextual de cabecera de grupo** (clic derecho): Renombrar… · recolorear (6 swatches) · Desagrupar · Cerrar grupo.
- No se incluye cierre con clic central (fuera de alcance de v1).

## 5. i18n

Claves nuevas en ambos `.arb` (paridad, registro neutro), para: cada ítem de los dos menús contextuales, los tooltips de las flechas y del botón "todas las pestañas", el nombre por defecto de grupo, y el título del diálogo de renombrar. Sin placeholders salvo donde haga falta (p. ej. contadores), con `@key` solo en EN.

## 6. Verificación

- **Unit (Notifier, sin red):** las dos invariantes tras cada mutación (anclar/desanclar reordena correctamente; los miembros de un grupo quedan contiguos); `newGroupFromSession`, `groupByVm`, `addToGroup`/`removeFromGroup`, `renameGroup`/`recolorGroup`, `ungroup`, `closeGroup`, `closeOthers`, `closeToRight`; reordenar restringido a zona; auto-eliminación de grupo vacío; y **que `closeGroup`/`closeOthers` siguen disparando el `disconnect` del túnel** cuando se cierra la última sesión de una VM (con el fake `ConnectionsNotifier` existente).
- **Widget:** las flechas `‹ ›` aparecen solo al desbordar; el auto-scroll deja visible la pestaña activa al abrir una nueva; el menú "todas las pestañas" lista y enfoca; se preserva el invariante `IndexedStack` (hijos ocultos no se destruyen).
- **Manual (checklist):** abrir muchas pestañas y confirmar que ninguna se pierde (flechas + menú + auto-scroll); anclar/desanclar; crear grupo, renombrar, recolorear, desagrupar, cerrar grupo; "agrupar todas las pestañas de esta VM"; reordenar dentro de cada zona; verificar en ES que los menús y nombres no se recortan.

## 7. Secuenciación

El plan aterriza en fases independientemente entregables, con el arreglo del defecto primero:

1. **Fase 1 — Desbordamiento (arregla el defecto):** `ScrollController` + flechas `‹ ›` + auto-scroll a la activa + menú `⌄` "todas las pestañas". Sin cambios de modelo de datos. Entregable por sí solo.
2. **Fase 2 — Anclar:** campo `pinned`, invariante de ancladas, `togglePin`, zona anclada solo-icono, y el ítem de menú.
3. **Fase 3 — Grupos + reordenar:** `WorkspaceGroup`, `groupId`, invariante de contigüidad, todos los métodos de grupo, el renderizado de segmentos de color, los menús contextuales, y la reordenación por arrastre restringida a zona.

## Fuera de alcance

- Colapsar grupos a un chip (descartado por el usuario: "clutter").
- Cambiar la pertenencia a grupo o anclar **por arrastre** (solo por menú en v1).
- Cierre con clic central.
- Restauración de pestañas/grupos/anclajes al reabrir la app.
- Rediseño visual general (Connect/Tools/Lifecycle, un acento) — proyecto A, aparte.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Mantener las dos invariantes de orden se vuelve frágil | Centralizar toda mutación en el Notifier con helpers privados; tests unitarios de invariantes tras cada operación |
| El auto-scroll/`ensureVisible` compite con el arrastre o el layout | Fase 1 lo entrega y prueba de forma aislada antes de añadir pin/grupos |
| Muchos grupos/colores = ruido visual | Paleta fija de 6; grupos siempre expandidos pero el menú `⌄` da navegación directa |
| Colisión con el ref-count de túnel en cierres masivos | Los cierres masivos reutilizan `close(id)`; test explícito de que el `disconnect` sigue disparándose |
