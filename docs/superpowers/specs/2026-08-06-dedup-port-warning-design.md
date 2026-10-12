# Diseño: Aviso de dedup (puerto local reusado)

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** UX pequeña (Dart-only; sin Rust/bridge). Continúa la feature "elegir puerto local".

## Objetivo

Cuando el usuario pide un puerto local concreto en el diálogo Custom Tunnel pero ya existe un túnel/forward para ese `instance:remote`, la dedup de Rust (`start_tunnel`/`start_ssh_forward`, keyed por `instance:remote`) devuelve el puerto local del túnel **existente**, ignorando el pedido. Hoy la UI muestra el éxito normal ("Túnel listo en 127.0.0.1:\<puerto real\>") sin decir que se reusó otro puerto. Este trabajo añade un **mensaje de aviso** cuando el puerto devuelto difiere del pedido.

## Contexto

- Handler del botón Custom Tunnel en `lib/src/features/workspace/overview_tab.dart` (~L476-522): tras `_showCustomTunnelDialog`, llama `connect(...)` (Directo) o `connectSshForward(...)` (Reenvío SSH) con `localPort: choice.localPort`, recibe el puerto real en `localPort`, y en la rama de éxito (`if (localPort != null)`, ~L492-504) muestra `SnackBar(content: Text(l10n.customTunnelReady(address)))` + acción Copiar (`l10n.commonCopy` → `l10n.customTunnelAddressCopied`).
- `choice.localPort` (`int?`) = el puerto pedido (null = auto); `localPort` (`int?`) = el puerto real devuelto. Ambos ya están en scope.
- La dedup coincide en `instance:remote`; reabrir con otro puerto local devuelve el existente (comportamiento honesto y deliberado, documentado en el spec de "elegir puerto local").
- i18n: arb-dir `lib/l10n`, template `app_en.arb`, output-class `AppLocalizations`, `flutter gen-l10n`.

## Decisiones

| Decisión | Elección |
|---|---|
| Cuándo avisar | Solo cuando `choice.localPort != null && localPort != choice.localPort` (se pidió un puerto concreto y el devuelto difiere) |
| Modo auto | `choice.localPort == null` → nunca avisa |
| Ambos modos | Sí — el handler es compartido para Directo y Reenvío SSH |
| Presentación | Un `SnackBar` con el texto de aviso + `duration: Duration(seconds: 6)` + la misma acción Copiar. **Sin color/icono** especial |
| Rust/bridge | Sin cambios (Rust ya devuelve el puerto real) |

## Diseño

Todo en `lib/src/features/workspace/overview_tab.dart`, dentro de la rama `if (localPort != null)` del handler.

Calcular el flag y ramear solo el texto + la duración del `SnackBar`; la estructura (address, acción Copiar) se mantiene:

```dart
if (localPort != null) {
  final address = '127.0.0.1:$localPort';
  final reused = choice.localPort != null && localPort != choice.localPort;
  messenger.showSnackBar(SnackBar(
    content: Text(reused
        ? l10n.customTunnelReusedPort(address, choice.localPort!)
        : l10n.customTunnelReady(address)),
    duration: reused
        ? const Duration(seconds: 6)
        : const Duration(seconds: 4), // default de SnackBar
    action: SnackBarAction(
      label: l10n.commonCopy,
      onPressed: () {
        Clipboard.setData(ClipboardData(text: address));
        messenger.showSnackBar(SnackBar(
            content: Text(l10n.customTunnelAddressCopied)));
      },
    ),
  ));
} else { /* ...diálogo de error actual, sin cambios... */ }
```

(El `duration` del caso no-reused se fija explícitamente a 4s = el default actual de `SnackBar`, para que la rama sea simétrica y no cambie el comportamiento existente.)

### i18n — clave nueva

En `lib/l10n/app_en.arb` y `app_es.arb`, junto a las otras claves `customTunnel*`, añadir `customTunnelReusedPort` con dos placeholders (`address` String, `requested` int); luego `flutter gen-l10n`:

- EN: `"Reused an existing tunnel on {address}; the requested port {requested} wasn't applied."`
- ES: `"Se reusó un túnel existente en {address}; el puerto {requested} que pediste no se aplicó."`

Definición ARB (EN template, con metadatos de placeholders):
```json
  "customTunnelReusedPort": "Reused an existing tunnel on {address}; the requested port {requested} wasn't applied.",
  "@customTunnelReusedPort": {
    "placeholders": {
      "address": { "type": "String" },
      "requested": { "type": "int" }
    }
  },
```
(ES: solo la línea `"customTunnelReusedPort": "..."`, sin bloque `@`.)

## Testing

- La lógica es el booleano `reused` inline; el `SnackBar` es UI → verificación por **QA manual** + `flutter analyze` (sin issues nuevas sobre el baseline ~85).
- No se añade test unitario artificial (no hay seam puro que aporte; extraer un helper de una comparación de una línea sería sobre-ingeniería).

## Alcance / fuera de alcance

- **Dentro:** el aviso en el handler del diálogo Custom Tunnel (ambos modos), 1 clave i18n EN/ES.
- **Fuera:** cambiar el modelo de dedup (sigue `instance:remote`); avisar en otras superficies (SSH/SFTP usan `:22` auto, `localPort` null → no aplican); color/icono de warning en el snackbar.

## Verificación

- `flutter analyze` (sin issues nuevas) y `flutter test` (suite existente verde).
- QA manual: abrir un túnel Custom con puerto elegido para un `instance:remote` que **ya** tiene túnel → ver el aviso con el puerto real + el pedido; abrir uno nuevo (sin dedup) → mensaje de éxito normal; modo auto → sin aviso.
