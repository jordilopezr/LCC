# Diseño: Localizar las notificaciones de escritorio (i18n SP1)

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature de código (Dart-only; sin Rust/bridge). Sub-proyecto **SP1** de la i18n restante (SP2 = QA visual ES, aparte/después).

## Objetivo

Las notificaciones de escritorio salen hoy en **inglés hardcoded** (`NotificationService`, `lib/src/services/notification_service.dart`). Este trabajo las localiza para que sigan el idioma de la app, cargando `AppLocalizations` sin `BuildContext` en el servicio (que es un singleton sin context) y refrescándolo al cambiar de idioma.

## Contexto

- **`NotificationService`** (singleton, `lib/src/services/notification_service.dart`): 6 métodos `notify*` con title/body en inglés (`notifyVmStateChange`, `notifyTunnelFailed`, `notifyLifecycleOperation`, `notifyTunnelReconnecting`, `notifyTunnelReconnected`, `notifyTunnelGaveUp`) + `notifyGeneral(title, body)`. Sin `BuildContext`; `initialize()` se llama en `main.dart:77`.
- **Call-sites:** todos en `lib/src/features/gcloud_provider.dart` (providers, sin context). Los **2 usos de `notifyGeneral`** (L1112, L1185) son notificaciones de fallback de cliente RDP/VNC con strings inglesas: title `'RDP Client Fallback'`/`'VNC Client Fallback'`, body `'Your preferred client was unavailable. Using $clientName instead.'`.
- **Locale:** `localeProvider` (`NotifierProvider<LocaleNotifier, Locale?>`, `settings_provider.dart:384`; `null` = system) alimenta `MaterialApp.locale` (`main.dart:186`).
- **Cargar `AppLocalizations` sin context:** `AppLocalizations.delegate.load(locale)` → `Future<AppLocalizations>`. Alternativa más limpia usada aquí: obtener `AppLocalizations.of(context)` desde un punto **debajo del `MaterialApp`** (reusa la resolución de locale de Flutter, incl. "system") y pasárselo al servicio.
- i18n: arb-dir `lib/l10n`, template `app_en.arb`, output-class `AppLocalizations`, `flutter gen-l10n`.

## Decisiones

| Decisión | Elección |
|---|---|
| Fuente del `AppLocalizations` | El servicio guarda `AppLocalizations? _l10n`, actualizado por un `MaterialApp.builder` que llama `updateLocalizations(AppLocalizations.of(context))` |
| Sincronización con el idioma | El `builder` corre en cada build (y al cambiar locale), siempre bajo `Localizations` → `_l10n` sigue al idioma de la UI |
| `_l10n == null` (arranque) | `notify*` hace **early-return** (como el guard `isEnabled`); no se conservan strings inglesas |
| `notifyGeneral` inglés (2 sitios RDP/VNC) | Reemplazar por un método nuevo localizado `notifyClientFallback(protocol, clientName)` |
| `notifyGeneral` genérico | Si queda sin uso tras lo anterior, retirarlo |
| `operation` / estados VM | Interpolados **crudos** (constantes GCP: start/stop/RUNNING/…); se localiza solo el marco |
| Rust/bridge | Sin cambios |

## Diseño

### 1. `NotificationService` — sostener y usar `AppLocalizations`

```dart
AppLocalizations? _l10n;

/// Keep the service's localizations in sync with the app's current locale.
/// Called from a widget below MaterialApp (see main.dart) so it uses the same
/// resolved locale as the UI, including "system".
void updateLocalizations(AppLocalizations l10n) {
  _l10n = l10n;
}
```
Cada método `notify*` empieza con:
```dart
if (!isEnabled) return;
final l10n = _l10n;
if (l10n == null) return;
```
y construye `title`/`body` desde `l10n.<clave>(...)` (ver §3) en vez de literales en inglés. La lógica de `_showNotification`/id/importancia/payload no cambia.

Nuevo método (reemplaza los 2 `notifyGeneral`):
```dart
Future<void> notifyClientFallback({
  required String protocol,   // "RDP" | "VNC" (crudo)
  required String clientName,
}) async {
  if (!isEnabled) return;
  final l10n = _l10n;
  if (l10n == null) return;
  await _showNotification(
    id: 'fallback:$protocol'.hashCode,
    title: l10n.notifClientFallbackTitle(protocol),
    body: l10n.notifClientFallbackBody(clientName),
    payload: 'client_fallback:$protocol',
  );
}
```
Si tras el cambio `notifyGeneral` no tiene llamadores, borrarlo (lo confirma `flutter analyze`/grep).

### 2. Wiring del locale (`main.dart`)

En el `MaterialApp` (el que ya usa `locale: appLocale`, L~178-186), añadir el `builder`:
```dart
builder: (context, child) {
  NotificationService().updateLocalizations(AppLocalizations.of(context));
  return child ?? const SizedBox.shrink();
},
```
(El `context` del `builder` está bajo el `Localizations` que inserta `MaterialApp`, así que `AppLocalizations.of(context)` resuelve el idioma efectivo. Si ya existe un `builder`, se compone dentro de él.)

### 3. Wiring de call-sites (`gcloud_provider.dart`)

Reemplazar los 2 `NotificationService().notifyGeneral(title: 'RDP/VNC Client Fallback', body: '...$clientName...')` (L1112, L1185) por:
```dart
NotificationService().notifyClientFallback(protocol: 'RDP', clientName: clientName);
// y
NotificationService().notifyClientFallback(protocol: 'VNC', clientName: clientName);
```
Los demás call-sites (`notifyTunnelFailed`, `notifyLifecycle*`, `notifyTunnel*`, `notifyVmStateChange`) **no cambian de firma** — solo el servicio localiza internamente.

### 4. Claves i18n (nuevas, en `app_en.arb` + `app_es.arb`, con placeholders + `flutter gen-l10n`)

Un par title/body por método (nombres `notif*`), con estos placeholders (todos `String`, salvo `port`/`attempt`/`maxAttempts` = `int`):

- `notifVmStateChangeTitle(instanceName)` / `notifVmStateChangeBody(oldState, newState, project, zone)`
- `notifTunnelFailedTitle(instanceName)` / `notifTunnelFailedBody(port, project, zone)`
- `notifLifecycleSuccessTitle(operation, instanceName)` / `notifLifecycleSuccessBody(project, zone)`
- `notifLifecycleFailedTitle(operation, instanceName)` / `notifLifecycleFailedBody(error, project, zone)`
- `notifTunnelReconnectingTitle(instanceName)` / `notifTunnelReconnectingBody(port, attempt, maxAttempts, project)`
- `notifTunnelReconnectedTitle(instanceName)` / `notifTunnelReconnectedBody(port, project)`
- `notifTunnelGaveUpTitle(instanceName)` / `notifTunnelGaveUpBody(port, maxAttempts, project)`
- `notifClientFallbackTitle(protocol)` / `notifClientFallbackBody(clientName)`

Los textos EN reproducen los actuales (p.ej. `notifTunnelFailedTitle` = `"IAP Tunnel Failed: {instanceName}"`, body = `"Port {port} disconnected\n{project}/{zone}"`); ES son la traducción equivalente. El marcador `✓`/`✗` del lifecycle se conserva en la clave EN y ES.

## Testing

- **Unit (nuevo test):** cargar `AppLocalizations` para `Locale('en')` y `Locale('es')` con `AppLocalizations.delegate.load(...)` (no requiere widget) y aserta que las nuevas claves renderizan e interpolan (p.ej. `en.notifTunnelFailedTitle('vm1') == 'IAP Tunnel Failed: vm1'` y que la variante ES no es igual a la EN y contiene el `instanceName`). Verifica que las claves existen y toman los placeholders en ambos idiomas.
- **Manual:** con el idioma en español, forzar eventos que disparen notificaciones (p.ej. un reconnect / un cambio de estado de VM / un fallback RDP-VNC) y ver la notificación en español.

## Alcance / fuera de alcance

- **Dentro:** localizar los 6 `notify*` + el nuevo `notifyClientFallback` (reemplazando los 2 `notifyGeneral` ingleses); el `updateLocalizations` + su wiring en `main.dart`; ~14 claves i18n EN/ES.
- **Fuera:** traducir los verbos de `operation` / los estados de VM (se interpolan crudos); SP2 (QA visual ES); Rust/bridge; el `notifyGeneral` genérico se retira solo si queda sin uso.

## Verificación

- `flutter analyze` (sin issues nuevas sobre el baseline ~85, 0 errores; sin `notifyGeneral` huérfano si se retira) y `flutter test` (suite existente + el nuevo test de claves).
- QA manual de una notificación en español.
