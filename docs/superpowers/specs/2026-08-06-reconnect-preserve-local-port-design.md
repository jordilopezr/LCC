# Diseño: Reconnect que preserva el puerto local elegido

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature pequeña (Dart-only; sin Rust, sin regen de bridge). Continúa la feature "elegir puerto local".

## Objetivo

Cuando un túnel Custom **Directo (IAP)** con el puerto local elegido por el usuario se recicla por inactividad (reaper de Rust) y el health-check dispara el **auto-reconnect**, hoy se re-vincula en un puerto **auto** nuevo (`startConnection(..., localPort: null)`), rompiendo la app del usuario que apunta al puerto fijo. Este trabajo hace que el reconnect re-vincule el **mismo** puerto elegido. Los túneles auto no cambian.

## Contexto

- `TunnelState.autoReconnectEnabled` **default = `true`** (`gcloud_provider.dart:434`); `_connect` (Directo) construye el estado conectado sin fijarlo → **los túneles Custom Directo auto-reconectan**. `_connectSshForward` pone `autoReconnectEnabled: false` (`:997`) → **el Reenvío SSH no reconecta** → fuera de alcance por construcción.
- El health-check periódico `_checkAllTunnels` (`:508`) detecta el fallo, entra en `reconnecting` vía `_enterReconnectingState`, y `_attemptReconnection` (`:679`) llama `startConnection(..., localPort: null)` (`:696`). El retry manual `retryConnection` (`:810`) también pasa por `_attemptReconnection`.
- `TunnelState` es inmutable y se **reconstruye inline (sin `copyWith`) en ~8 sitios** del ciclo de vida de reconnect — incluida la reconstrucción `connected` en **cada** health-check sano (`:589`). Guardar el puerto solicitado *dentro* de `TunnelState` obligaría a arrastrarlo por los 8 sitios, con un fallo silencioso si se olvida uno. Por eso se descarta esa vía (Enfoque A) a favor de un mapa lateral.
- `disconnectByKey` (`:1029`) es el **único** punto de borrado de un túnel; `disconnect`, `disconnectAllForInstance` y `disconnectAll` pasan por él.

## Decisiones

| Decisión | Elección |
|---|---|
| Dónde vive el puerto solicitado | **Mapa lateral** `Map<String, int?> _requestedLocalPorts` en `ConnectionsNotifier`, keyed por el `tunnelKey` invariante (Enfoque B) |
| Puntos de contacto | **3**: set en `_connect` (si `localPort != null`), read en `_attemptReconnection`, remove en `disconnectByKey` |
| Por qué B y no A | El `tunnelKey` no cambia entre reconexiones → las ~8 reconstrucciones de `TunnelState` no tocan el mapa; imposible perder el valor a mitad del ciclo. A es frágil (trampa del health-check `:589`) |
| Alcance | Solo Directo IAP (único con auto-reconnect). SSH forward no reconecta → nada que preservar |
| Puerto elegido ocupado al reconectar | Reconnect falla (`LocalPortUnavailable`), reintenta con el backoff existente, se rinde tras `maxReconnectAttempts` (mover a otro puerto rompería igual la app del usuario) |
| Retry manual | `retryConnection` → `_attemptReconnection` lee el mapa → también preserva el puerto |
| Rust / bridge | Sin cambios (el plumbing ya acepta `localPort`) |

## Diseño

Todo en `lib/src/features/gcloud_provider.dart`.

### 1. El mapa lateral

Junto a `final Map<String, Future<int?>> _inFlightConnects = {};` (`:487`), añadir:

```dart
  /// Local port the user explicitly requested per tunnel (keyed by the stable
  /// tunnelKey). Absent = auto-assigned. Read on auto-reconnect so a chosen
  /// port is preserved across the idle-reaper; removed on explicit disconnect.
  final Map<String, int?> _requestedLocalPorts = {};
```

### 2. Set — en `_connect` (éxito)

En `_connect`, en la rama de éxito (tras `final port = await startConnection(...)`, junto al estado `connected` en `:908-919`), registrar el puerto solicitado solo si el usuario eligió uno:

```dart
      if (localPort != null) {
        _requestedLocalPorts[tunnelKey] = localPort;
      }
```

(Los túneles auto no crean entrada; ausencia = auto.)

### 3. Read — en `_attemptReconnection`

Cambiar `localPort: null` (`:696`) por:

```dart
        localPort: _requestedLocalPorts[tunnelKey],
```

`_requestedLocalPorts[tunnelKey]` es `null` cuando no hay entrada (túnel auto) → comportamiento actual; es el puerto elegido cuando el usuario lo fijó.

### 4. Remove — en `disconnectByKey`

Tras `newState.remove(tunnelKey);` (`:1043`), añadir:

```dart
    _requestedLocalPorts.remove(tunnelKey);
```

**No** se limpia en el "give-up" (estado `error`): si el usuario luego usa `retryConnection`, el reintento debe seguir preservando el puerto. Solo el disconnect explícito lo borra.

## Comportamiento

- **Puerto elegido, libre tras el reaper:** el reconnect lo re-vincula. ✓
- **Puerto elegido, ocupado:** el reconnect falla, reintenta con backoff, se rinde con la notificación existente (correcto: un puerto distinto no le sirve a la app fijada).
- **Túnel auto (`localPort` nunca elegido):** sin entrada en el mapa → reconnect `null` → auto. **Sin regresión.**
- **Retry manual:** preserva el puerto (mismo camino).

## Testing

- El comportamiento clave (reconnect usa el puerto elegido) requiere un túnel vivo + reap → **QA manual**.
- La lógica del mapa (set/read/remove) no tiene un seam puro fácil de aislar (todo pasa por el bridge `startConnection`); no se añade test unitario artificial. Verificación = `flutter analyze` (sin issues nuevas) + QA manual.

## Alcance / fuera de alcance

- **Dentro:** el mapa lateral + los 3 puntos de contacto; preservación en auto-reconnect y en retry manual (Directo IAP).
- **Fuera:** SSH forward (no auto-reconecta); avisar en UI cuando el reconnect no pudo recuperar el puerto (la notificación de "gave up" existente ya cubre el fallo); cambiar el modelo de dedup o el backoff.

## Verificación

- `flutter analyze` (sin issues nuevas sobre el baseline ~85, 0 errores) y `flutter test` (suite existente verde).
- QA manual: túnel Custom Directo con puerto elegido → forzar reap por inactividad → confirmar que el reconnect re-vincula el mismo puerto; túnel auto → reconnect sigue auto.
