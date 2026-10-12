# Reconnect Preserves Chosen Local Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-reconnect of a Direct IAP Custom Tunnel rebinds the user's chosen local port instead of auto-assigning a new one; auto tunnels are unchanged.

**Architecture:** A side map `_requestedLocalPorts` in `ConnectionsNotifier`, keyed by the invariant `tunnelKey`, records the port the user explicitly requested. It is set on connect, read on auto-reconnect (in place of the current `localPort: null`), and removed on explicit disconnect — three touch points, no threading through the ~8 inline `TunnelState` rebuilds.

**Tech Stack:** Flutter / Riverpod (Notifier). Spec: `docs/superpowers/specs/2026-08-06-reconnect-preserve-local-port-design.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. The bridge already accepts `localPort` (prior feature). Do NOT run `dart format`.
- Only Direct IAP is in scope (it auto-reconnects). SSH forward has `autoReconnectEnabled: false` → no reconnect → untouched.
- Auto tunnels (user never chose a port) must keep exact current behavior: absent map entry → `null` → auto-assign.
- Do NOT clear the map on reconnect "give-up" — only on explicit disconnect — so a later manual `retryConnection` still preserves the port.
- Analyzer bar: the repo carries ~85 pre-existing issues (0 errors); introduce no NEW issues. Commits must NOT carry the `Co-Authored-By: Claude` trailer (code commits). Branch: `27H1-Preview`.

---

### Task 1: Add the `_requestedLocalPorts` side map and wire the three touch points

All edits are in `lib/src/features/gcloud_provider.dart`. They are interdependent (the field must exist before the set/read/remove reference it), so they land in one task.

**Files:**
- Modify: `lib/src/features/gcloud_provider.dart`

**Interfaces:**
- Consumes: existing `_connect(String projectId, String zone, String instanceName, int remotePort, String tunnelKey, int? localPort)`, `_attemptReconnection(String tunnelKey, TunnelState tunnelState)`, `disconnectByKey(String tunnelKey)`, `startConnection({..., int? localPort})`.
- Produces: no new public API — internal state only.

- [ ] **Step 1: Declare the side map**

In `lib/src/features/gcloud_provider.dart`, immediately below the existing `final Map<String, Future<int?>> _inFlightConnects = {};` (around line 487), add:

```dart
  /// Local port the user explicitly requested per tunnel (keyed by the stable
  /// tunnelKey). Absent = auto-assigned. Read on auto-reconnect so a chosen
  /// port survives the idle-reaper; removed on explicit disconnect.
  final Map<String, int?> _requestedLocalPorts = {};
```

- [ ] **Step 2: Record the requested port on a successful connect**

In `_connect`, in the success branch — after `final port = await startConnection(...)` returns and where the `'connected'` `TunnelState` is built (around lines 906-919) — record the chosen port only when the user set one. Insert immediately before the `state = { ... 'connected' ... };` assignment (i.e. right after `final now = DateTime.now();`):

```dart
      if (localPort != null) {
        _requestedLocalPorts[tunnelKey] = localPort;
      }
```

- [ ] **Step 3: Read the requested port on auto-reconnect**

In `_attemptReconnection`, change the `startConnection` call's local port argument from the hardcoded `null` (line ~696) so it reuses the requested port:

Replace:
```dart
        localPort: null,
```
with:
```dart
        localPort: _requestedLocalPorts[tunnelKey],
```

(`_requestedLocalPorts[tunnelKey]` is `null` when there is no entry — an auto tunnel — preserving today's behavior; it is the chosen port when the user fixed one. `retryConnection` reaches this same method, so manual retry preserves the port too.)

- [ ] **Step 4: Remove the entry on explicit disconnect**

In `disconnectByKey`, after `newState.remove(tunnelKey);` and before/after `state = newState;` (around line 1043), add the map cleanup:

```dart
    _requestedLocalPorts.remove(tunnelKey);
```

(`disconnect`, `disconnectAllForInstance`, and `disconnectAll` all route through `disconnectByKey`, so this single site covers every explicit teardown. The reconnect give-up path is intentionally left alone.)

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/src/features/gcloud_provider.dart 2>&1 | tail -20`
Expected: no new issues attributable to this change (the file's pre-existing baseline issues, if any, are unchanged).

- [ ] **Step 6: Full test suite**

Run: `flutter test 2>&1 | tail -15`
Expected: the existing suite stays green (this change adds no test seam — the reconnect path calls the bridge; behavior is verified by the manual QA in Task 2).

- [ ] **Step 7: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/gcloud_provider.dart
git commit -m "feat(tunnel): auto-reconnect preserves the chosen local port"
```

---

### Task 2: Manual QA checklist

The behavior can only be verified with a live tunnel + the idle reaper, so capture the manual checks.

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-reconnect-preserve-local-port-manual-qa.md`

- [ ] **Step 1: Confirm the gate is green**

Run: `flutter analyze 2>&1 | tail -6` — Expected: zero errors; no issue in `gcloud_provider.dart` introduced by Task 1.
Run: `flutter test 2>&1 | tail -6` — Expected: all pass.

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-reconnect-preserve-local-port-manual-qa.md`:

```markdown
# Manual QA — Reconnect preserves the chosen local port

Run on a real desktop with a reachable GCP VM.

- [ ] Open a Direct (IAP) Custom Tunnel and choose a fixed local port (e.g. 15901). Confirm it connects on 15901.
- [ ] Leave it idle until the Rust reaper reaps it (idle timeout), so the health check enters "reconnecting".
- [ ] After auto-reconnect: the tunnel is back on the SAME port 15901 (not a new auto port).
- [ ] Open a Direct Custom Tunnel WITHOUT choosing a local port (auto). Force a reap/reconnect → it reconnects on some auto port (no regression; no error).
- [ ] While a chosen-port tunnel is reconnecting, hold that local port with another process → reconnect fails and retries/gives up with the existing notification (it does not silently move to a different port).
- [ ] Disconnect the chosen-port tunnel explicitly, then reconnect a fresh one on an auto port for the same VM:remote → no stale chosen port is reused.
```

- [ ] **Step 3: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-reconnect-preserve-local-port-manual-qa.md
git commit -m "docs(qa): manual QA checklist for reconnect local-port preservation"
```

---

## Self-Review

**1. Spec coverage:**
- Side map `_requestedLocalPorts` keyed by tunnelKey → Task 1 Step 1. ✓
- Set in `_connect` when `localPort != null` → Task 1 Step 2. ✓
- Read in `_attemptReconnection` (replace `localPort: null`) → Task 1 Step 3. ✓
- Remove in `disconnectByKey` → Task 1 Step 4. ✓
- No clean on give-up (only explicit disconnect) → Task 1 Step 4 note. ✓
- Auto tunnels unchanged (absent → null) → Task 1 Step 3 behavior. ✓
- Manual-QA-only verification (no unit seam) → Task 2. ✓
- Dart-only, no Rust/bridge → no task touches Rust or runs codegen. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows the exact snippet and its anchor (the `_inFlightConnects` field, the `'connected'` state build, the `localPort: null` line, `newState.remove(tunnelKey);`). ✓

**3. Type consistency:** `_requestedLocalPorts` is `Map<String, int?>` everywhere; `tunnelKey` is the `String` key used by `_connect`/`_attemptReconnection`/`disconnectByKey`; `localPort` is the `int?` param of `_connect` and of `startConnection`. All consistent. ✓
