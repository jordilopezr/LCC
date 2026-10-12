# Localize Desktop Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make desktop notifications follow the app language by localizing `NotificationService` (a context-less singleton) via an `AppLocalizations` it holds, kept in sync with the app locale.

**Architecture:** Add ~17 `notif*` i18n keys; `NotificationService` holds an `AppLocalizations? _l10n` set by `updateLocalizations`, wired from a `MaterialApp.builder` (`AppLocalizations.of(context)`); the 6 `notify*` methods render localized title/body (early-return if `_l10n` is null); a new `notifyClientFallback` replaces the 2 English `notifyGeneral` RDP/VNC sites.

**Tech Stack:** Flutter, flutter gen-l10n. Spec: `docs/superpowers/specs/2026-08-06-localize-notifications-design.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. Do NOT run `dart format`.
- The service has no `BuildContext`; it gets `AppLocalizations` from `updateLocalizations`, called by a widget BELOW `MaterialApp` (so `AppLocalizations.of(context)` resolves the effective locale, incl. "system"). If `_l10n` is null (startup), `notify*` early-returns — no English fallback strings kept.
- `operation` and VM states (RUNNING/TERMINATED/…) are interpolated RAW (GCP constants), not translated.
- New i18n keys go in `lib/l10n/app_en.arb` + `lib/l10n/app_es.arb` (arb-dir `lib/l10n`, template `app_en.arb`, output class `AppLocalizations`), regenerated with `flutter gen-l10n`. Do NOT hand-edit `lib/l10n/gen/`.
- Analyzer bar: repo baseline ~85 pre-existing issues (0 errors); introduce no NEW issues and leave no orphaned method/import. Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer (docs commits only). Branch: `27H1-Preview`.

---

### Task 1: Add the notification i18n keys (TDD via a render test)

**Files:**
- Create: `test/notification_l10n_test.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Produces (used by Task 2): the `AppLocalizations` methods listed below (title/body per notification, plus `notifUnknownError`).

- [ ] **Step 1: Write the failing render test**

Create `test/notification_l10n_test.dart`:

```dart
import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notification keys render and interpolate in EN and ES', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final es = await AppLocalizations.delegate.load(const Locale('es'));

    // EN reproduces the current strings.
    expect(en.notifTunnelFailedTitle('vm1'), 'IAP Tunnel Failed: vm1');
    expect(en.notifTunnelFailedBody(8080, 'proj', 'z1'),
        'Port 8080 disconnected\nproj/z1');
    expect(en.notifTunnelReconnectingBody(22, 2, 5, 'proj'),
        'Port 22 - Attempt 2/5\nproj');
    expect(en.notifLifecycleSuccessTitle('start', 'vm1'),
        '✓ start completed: vm1');
    expect(en.notifClientFallbackTitle('RDP'), 'RDP Client Fallback');

    // ES interpolates the same values and differs from EN.
    expect(es.notifTunnelFailedTitle('vm1'), contains('vm1'));
    expect(es.notifTunnelFailedTitle('vm1'),
        isNot(en.notifTunnelFailedTitle('vm1')));
    expect(es.notifTunnelReconnectingBody(22, 2, 5, 'proj'), contains('2/5'));
    expect(es.notifClientFallbackBody('Remmina'), contains('Remmina'));
    expect(es.notifUnknownError, isNot(en.notifUnknownError));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/notification_l10n_test.dart 2>&1 | tail -20`
Expected: FAIL to compile — the `notif*` methods don't exist on `AppLocalizations` yet.

- [ ] **Step 3: Add the keys to `app_en.arb`**

In `lib/l10n/app_en.arb`, add (group them together; keep JSON valid — the preceding entry keeps its comma):

```json
  "notifVmStateChangeTitle": "VM State Changed: {instanceName}",
  "@notifVmStateChangeTitle": { "placeholders": { "instanceName": { "type": "String" } } },
  "notifVmStateChangeBody": "{oldState} → {newState}\n{project}/{zone}",
  "@notifVmStateChangeBody": { "placeholders": { "oldState": {"type":"String"}, "newState": {"type":"String"}, "project": {"type":"String"}, "zone": {"type":"String"} } },
  "notifTunnelFailedTitle": "IAP Tunnel Failed: {instanceName}",
  "@notifTunnelFailedTitle": { "placeholders": { "instanceName": {"type":"String"} } },
  "notifTunnelFailedBody": "Port {port} disconnected\n{project}/{zone}",
  "@notifTunnelFailedBody": { "placeholders": { "port": {"type":"int"}, "project": {"type":"String"}, "zone": {"type":"String"} } },
  "notifLifecycleSuccessTitle": "✓ {operation} completed: {instanceName}",
  "@notifLifecycleSuccessTitle": { "placeholders": { "operation": {"type":"String"}, "instanceName": {"type":"String"} } },
  "notifLifecycleSuccessBody": "{project}/{zone}",
  "@notifLifecycleSuccessBody": { "placeholders": { "project": {"type":"String"}, "zone": {"type":"String"} } },
  "notifLifecycleFailedTitle": "✗ {operation} failed: {instanceName}",
  "@notifLifecycleFailedTitle": { "placeholders": { "operation": {"type":"String"}, "instanceName": {"type":"String"} } },
  "notifLifecycleFailedBody": "{error}\n{project}/{zone}",
  "@notifLifecycleFailedBody": { "placeholders": { "error": {"type":"String"}, "project": {"type":"String"}, "zone": {"type":"String"} } },
  "notifUnknownError": "Unknown error",
  "notifTunnelReconnectingTitle": "Tunnel Reconnecting: {instanceName}",
  "@notifTunnelReconnectingTitle": { "placeholders": { "instanceName": {"type":"String"} } },
  "notifTunnelReconnectingBody": "Port {port} - Attempt {attempt}/{maxAttempts}\n{project}",
  "@notifTunnelReconnectingBody": { "placeholders": { "port": {"type":"int"}, "attempt": {"type":"int"}, "maxAttempts": {"type":"int"}, "project": {"type":"String"} } },
  "notifTunnelReconnectedTitle": "Tunnel Reconnected: {instanceName}",
  "@notifTunnelReconnectedTitle": { "placeholders": { "instanceName": {"type":"String"} } },
  "notifTunnelReconnectedBody": "Port {port} successfully restored\n{project}",
  "@notifTunnelReconnectedBody": { "placeholders": { "port": {"type":"int"}, "project": {"type":"String"} } },
  "notifTunnelGaveUpTitle": "Tunnel Failed: {instanceName}",
  "@notifTunnelGaveUpTitle": { "placeholders": { "instanceName": {"type":"String"} } },
  "notifTunnelGaveUpBody": "Port {port} - Gave up after {maxAttempts} attempts\n{project}",
  "@notifTunnelGaveUpBody": { "placeholders": { "port": {"type":"int"}, "maxAttempts": {"type":"int"}, "project": {"type":"String"} } },
  "notifClientFallbackTitle": "{protocol} Client Fallback",
  "@notifClientFallbackTitle": { "placeholders": { "protocol": {"type":"String"} } },
  "notifClientFallbackBody": "Your preferred client was unavailable. Using {clientName} instead.",
  "@notifClientFallbackBody": { "placeholders": { "clientName": {"type":"String"} } },
```

- [ ] **Step 4: Add the ES translations to `app_es.arb`**

In `lib/l10n/app_es.arb`, add the translation-only lines (no `@` blocks):

```json
  "notifVmStateChangeTitle": "Estado de VM cambiado: {instanceName}",
  "notifVmStateChangeBody": "{oldState} → {newState}\n{project}/{zone}",
  "notifTunnelFailedTitle": "Túnel IAP fallido: {instanceName}",
  "notifTunnelFailedBody": "Puerto {port} desconectado\n{project}/{zone}",
  "notifLifecycleSuccessTitle": "✓ {operation} completado: {instanceName}",
  "notifLifecycleSuccessBody": "{project}/{zone}",
  "notifLifecycleFailedTitle": "✗ {operation} falló: {instanceName}",
  "notifLifecycleFailedBody": "{error}\n{project}/{zone}",
  "notifUnknownError": "Error desconocido",
  "notifTunnelReconnectingTitle": "Reconectando túnel: {instanceName}",
  "notifTunnelReconnectingBody": "Puerto {port} - Intento {attempt}/{maxAttempts}\n{project}",
  "notifTunnelReconnectedTitle": "Túnel reconectado: {instanceName}",
  "notifTunnelReconnectedBody": "Puerto {port} restaurado correctamente\n{project}",
  "notifTunnelGaveUpTitle": "Túnel fallido: {instanceName}",
  "notifTunnelGaveUpBody": "Puerto {port} - Se rindió tras {maxAttempts} intentos\n{project}",
  "notifClientFallbackTitle": "Cliente {protocol} de respaldo",
  "notifClientFallbackBody": "Tu cliente preferido no estaba disponible. Usando {clientName} en su lugar.",
```

- [ ] **Step 5: Regenerate and pass the test**

Run: `flutter gen-l10n`
Expected: `AppLocalizations` gains the `notif*` methods.

Run: `flutter test test/notification_l10n_test.dart 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add test/notification_l10n_test.dart lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen/
git commit -m "feat(i18n): notification message keys (EN/ES) + render test"
```

---

### Task 2: Localize `NotificationService`

**Files:**
- Modify: `lib/src/services/notification_service.dart`

**Interfaces:**
- Consumes: the `notif*` `AppLocalizations` methods (Task 1).
- Produces (used by Task 3): `void updateLocalizations(AppLocalizations l10n)`; `Future<void> notifyClientFallback({required String protocol, required String clientName})`. The existing `notify*` signatures are unchanged.

- [ ] **Step 1: Import AppLocalizations and hold `_l10n`**

At the top of `lib/src/services/notification_service.dart`, add the import:

```dart
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
```
In the class (near `_notificationsEnabled`), add:

```dart
  AppLocalizations? _l10n;

  /// Keep the service's localizations in sync with the app's current locale.
  /// Called from a widget below MaterialApp (see main.dart), so it uses the
  /// same resolved locale as the UI (including "system").
  void updateLocalizations(AppLocalizations l10n) {
    _l10n = l10n;
  }
```

- [ ] **Step 2: Localize the 6 `notify*` methods**

Replace the body of each `notify*` method's title/body construction with localized versions. In each, after `if (!isEnabled) return;` add `final l10n = _l10n; if (l10n == null) return;`, then build from `l10n.*`. The `_showNotification(...)` call (id/payload/importance/priority) stays as-is. Concretely:

`notifyVmStateChange`:
```dart
    final title = l10n.notifVmStateChangeTitle(instanceName);
    final body = l10n.notifVmStateChangeBody(oldState, newState, project, zone);
```
`notifyTunnelFailed`:
```dart
    final title = l10n.notifTunnelFailedTitle(instanceName);
    final body = l10n.notifTunnelFailedBody(remotePort, project, zone);
```
`notifyLifecycleOperation`:
```dart
    final title = success
        ? l10n.notifLifecycleSuccessTitle(operation, instanceName)
        : l10n.notifLifecycleFailedTitle(operation, instanceName);
    final body = success
        ? l10n.notifLifecycleSuccessBody(project, zone)
        : l10n.notifLifecycleFailedBody(errorMessage ?? l10n.notifUnknownError, project, zone);
```
`notifyTunnelReconnecting`:
```dart
    final title = l10n.notifTunnelReconnectingTitle(instanceName);
    final body = l10n.notifTunnelReconnectingBody(remotePort, attempt, maxAttempts, project);
```
`notifyTunnelReconnected`:
```dart
    final title = l10n.notifTunnelReconnectedTitle(instanceName);
    final body = l10n.notifTunnelReconnectedBody(remotePort, project);
```
`notifyTunnelGaveUp`:
```dart
    final title = l10n.notifTunnelGaveUpTitle(instanceName);
    final body = l10n.notifTunnelGaveUpBody(remotePort, maxAttempts, project);
```

- [ ] **Step 3: Add `notifyClientFallback`**

Add a new method (replaces the callers' use of `notifyGeneral`):

```dart
  /// Show a notification that a preferred RDP/VNC client was unavailable and a
  /// fallback client was used. `protocol` is "RDP"/"VNC" (raw, not translated).
  Future<void> notifyClientFallback({
    required String protocol,
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

Leave `notifyGeneral` in place for now (Task 3 removes it if it becomes unused).

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/src/services/notification_service.dart 2>&1 | tail -20`
Expected: no new issues (the file now imports and uses `AppLocalizations`; `updateLocalizations`/`notifyClientFallback` are public, so no dead-code warning even before Task 3 wires them).

- [ ] **Step 5: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/services/notification_service.dart
git commit -m "feat(notifications): render localized title/body via held AppLocalizations"
```

---

### Task 3: Wire the locale + swap the client-fallback call sites

**Files:**
- Modify: `lib/main.dart`, `lib/src/features/gcloud_provider.dart`, `lib/src/services/notification_service.dart`

**Interfaces:**
- Consumes: `updateLocalizations` and `notifyClientFallback` (Task 2).

- [ ] **Step 1: Feed the service the app locale from `main.dart`**

In `lib/main.dart`, in the `MaterialApp(...)` (which currently has no `builder`), add a `builder` (e.g. just before `home: const DashboardScreen(),`):

```dart
      builder: (context, child) {
        NotificationService().updateLocalizations(AppLocalizations.of(context));
        return child ?? const SizedBox.shrink();
      },
```
(`NotificationService` and `AppLocalizations` are already imported in `main.dart`. The `builder`'s `context` is below the `Localizations` widget `MaterialApp` inserts, so `AppLocalizations.of(context)` resolves the effective locale and re-runs on locale change.)

- [ ] **Step 2: Swap the two RDP/VNC fallback call sites**

In `lib/src/features/gcloud_provider.dart`, replace the RDP fallback notification (the `NotificationService().notifyGeneral(title: 'RDP Client Fallback', body: 'Your preferred client was unavailable. Using $clientName instead.')` block, ~L1112) with:

```dart
            NotificationService().notifyClientFallback(
                protocol: 'RDP', clientName: clientName);
```
and the VNC one (~L1185, `title: 'VNC Client Fallback'`) with:

```dart
            NotificationService().notifyClientFallback(
                protocol: 'VNC', clientName: clientName);
```

- [ ] **Step 3: Remove `notifyGeneral` if now unused**

Run: `grep -rn "notifyGeneral" lib/`
Expected: only the definition in `notification_service.dart` remains (both call sites are gone). If so, delete the `notifyGeneral` method from `notification_service.dart`. If any other caller exists, leave it (and note it in the report).

- [ ] **Step 4: Analyze + full test**

Run: `flutter analyze 2>&1 | tail -12`
Expected: 0 errors; no new issue; no orphaned `notifyGeneral`.

Run: `flutter test 2>&1 | tail -12`
Expected: the existing suite + the Task 1 render test pass.

- [ ] **Step 5: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/main.dart lib/src/features/gcloud_provider.dart lib/src/services/notification_service.dart
git commit -m "feat(notifications): wire app locale + localized RDP/VNC fallback"
```

---

### Task 4: Gate + manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-localize-notifications-manual-qa.md`

- [ ] **Step 1: Confirm the gate**

Run: `flutter analyze 2>&1 | tail -6` — Expected: 0 errors; no new issue in the touched files.
Run: `flutter test 2>&1 | tail -6` — Expected: all pass (incl. the render test).

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-localize-notifications-manual-qa.md`:

```markdown
# Manual QA — Localized desktop notifications

Enable notifications, set the app language, and trigger events.

- [ ] Spanish: force a tunnel reconnect (let an idle tunnel be reaped, then reconnect) → the desktop notification title/body are in Spanish ("Reconectando túnel…", "Túnel reconectado…").
- [ ] Spanish: a lifecycle op (start/stop a VM) → "✓ start completado: <vm>" / on failure "✗ … falló: <vm>" with the error line.
- [ ] Spanish: launch RDP/VNC where the preferred client is unavailable → "Cliente RDP/VNC de respaldo" + "…Usando <client> en su lugar."
- [ ] English: switch the app language to English and repeat one case → notifications are in English (the original wording, e.g. "IAP Tunnel Failed: <vm>").
- [ ] Change the language while the app is running, then trigger a notification → it uses the newly selected language (the builder refreshed the service's localizations).
- [ ] Raw interpolation preserved: VM states (RUNNING/TERMINATED) and the operation verb appear as-is inside the localized frame.
```

- [ ] **Step 3: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-localize-notifications-manual-qa.md
git commit -m "docs(qa): manual QA checklist for localized notifications"
```

---

## Self-Review

**1. Spec coverage:**
- `NotificationService` holds `AppLocalizations? _l10n` + `updateLocalizations` → Task 2 Step 1. ✓
- 6 `notify*` render localized title/body, early-return if `_l10n` null → Task 2 Step 2. ✓
- `notifyClientFallback` replaces the 2 English `notifyGeneral` sites → Task 2 Step 3 + Task 3 Step 2. ✓
- Remove `notifyGeneral` if unused → Task 3 Step 3. ✓
- ~17 `notif*` i18n keys EN/ES (EN reproduces current strings incl. ✓/✗) + gen-l10n → Task 1. ✓
- `MaterialApp.builder` feeds the locale → Task 3 Step 1. ✓
- operation/VM-states raw → Task 1 keys interpolate them as `{operation}`/`{oldState}` verbatim; Task 2 passes them raw. ✓
- Render test (EN+ES) → Task 1. Verification analyze/test/manual → Tasks 3-4. ✓
- Dart-only → no cargo/bridge; only `flutter gen-l10n`. ✓

**2. Placeholder scan:** No TBD/TODO; the full ARB entries, the localized method bodies, the builder, and the two call-site swaps are all shown. The one conditional (remove `notifyGeneral` if unused) is grep-gated. ✓

**3. Type consistency:** the `AppLocalizations` method signatures used in Task 2 (e.g. `notifTunnelReconnectingBody(int port, int attempt, int maxAttempts, String project)`) match the placeholder types declared in Task 1's ARB (`port`/`attempt`/`maxAttempts` = int; rest String). `updateLocalizations(AppLocalizations)` and `notifyClientFallback({required String protocol, required String clientName})` (Task 2) match their uses in Task 3. The render test (Task 1) calls the same signatures. ✓
