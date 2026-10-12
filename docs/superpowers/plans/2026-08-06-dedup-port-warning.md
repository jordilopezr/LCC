# Dedup Port-Reuse Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Custom Tunnel handler, show a distinct warning snackbar when a requested local port wasn't applied because dedup returned an existing tunnel's port (instead of the silent success message).

**Architecture:** One-file Dart change in `overview_tab.dart`'s Custom Tunnel success branch: compute `reused = choice.localPort != null && localPort != choice.localPort` and branch the snackbar's text + duration on it; keep the Copy action. Add one i18n key with `flutter gen-l10n`.

**Tech Stack:** Flutter, flutter gen-l10n. Spec: `docs/superpowers/specs/2026-08-06-dedup-port-warning-design.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. Do NOT run `dart format`.
- Warn ONLY when `choice.localPort != null && localPort != choice.localPort` (a specific port was requested and the returned port differs). Auto mode (`choice.localPort == null`) never warns.
- Applies to both Custom Tunnel modes (Direct + SSH forward) — the handler is shared; do not special-case per mode.
- New i18n key `customTunnelReusedPort` with placeholders `address` (String) and `requested` (int); regenerate with `flutter gen-l10n` (arb-dir `lib/l10n`, template `app_en.arb`, output class `AppLocalizations`). Do NOT hand-edit generated files under `lib/l10n/gen/`.
- Analyzer bar: repo baseline has ~85 pre-existing issues (0 errors); introduce no NEW issues. Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer (docs commits only). Branch: `27H1-Preview`.

---

### Task 1: Add the i18n key and the dedup-warning branch

The i18n key must exist before the handler references it, so both land in one task.

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Modify: `lib/src/features/workspace/overview_tab.dart`

**Interfaces:**
- Consumes: existing `choice.localPort` (`int?`, requested) and `localPort` (`int?`, returned) in the Custom Tunnel handler; existing `l10n.customTunnelReady(String)`, `l10n.commonCopy`, `l10n.customTunnelAddressCopied`.
- Produces: `l10n.customTunnelReusedPort(String address, int requested)`.

- [ ] **Step 1: Add the i18n key (EN template + placeholders)**

In `lib/l10n/app_en.arb`, near the other `customTunnel*` keys, add:

```json
  "customTunnelReusedPort": "Reused an existing tunnel on {address}; the requested port {requested} wasn't applied.",
  "@customTunnelReusedPort": {
    "placeholders": {
      "address": { "type": "String" },
      "requested": { "type": "int" }
    }
  },
```

In `lib/l10n/app_es.arb`, near the other `customTunnel*` keys, add (translations only, no `@` block):

```json
  "customTunnelReusedPort": "Se reusó un túnel existente en {address}; el puerto {requested} que pediste no se aplicó.",
```

(Mind the JSON commas — ensure the preceding entry keeps its trailing comma and the object stays valid.)

- [ ] **Step 2: Regenerate localizations**

Run: `flutter gen-l10n`
Expected: `AppLocalizations` gains `String customTunnelReusedPort(String address, int requested)`. Confirm it compiled by grepping the generated output:

Run: `grep -rn "customTunnelReusedPort" lib/l10n/gen/ | head`
Expected: the method appears in `lib/l10n/gen/app_localizations.dart` (and the `_en`/`_es` files).

- [ ] **Step 3: Branch the success snackbar on `reused`**

In `lib/src/features/workspace/overview_tab.dart`, in the Custom Tunnel button handler's success branch (the `if (localPort != null) { ... }` block, ~L492-504 — locate it by the `final address = '127.0.0.1:$localPort';` line and the `l10n.customTunnelReady(address)` snackbar), replace that block with:

```dart
                        if (localPort != null) {
                          final address = '127.0.0.1:$localPort';
                          final reused = choice.localPort != null &&
                              localPort != choice.localPort;
                          messenger.showSnackBar(SnackBar(
                            content: Text(reused
                                ? l10n.customTunnelReusedPort(
                                    address, choice.localPort!)
                                : l10n.customTunnelReady(address)),
                            duration: reused
                                ? const Duration(seconds: 6)
                                : const Duration(seconds: 4),
                            action: SnackBarAction(
                              label: l10n.commonCopy,
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: address));
                                messenger.showSnackBar(SnackBar(
                                    content: Text(
                                        l10n.customTunnelAddressCopied)));
                              },
                            ),
                          ));
                        }
```

(Only the `content` text and the new `duration` line change; the `else { ... }` error branch that follows is unchanged. The 4s non-reused duration equals `SnackBar`'s current default, so existing behavior is preserved.)

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/src/features/workspace/overview_tab.dart 2>&1 | tail -20`
Expected: no NEW issues attributable to this change (`choice.localPort!` is null-safe here because `reused` already guards `choice.localPort != null`).

- [ ] **Step 5: Full test suite**

Run: `flutter test 2>&1 | tail -15`
Expected: the existing suite stays green (this change adds no test seam — the snackbar is UI, verified by manual QA).

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen/ \
        lib/src/features/workspace/overview_tab.dart
git commit -m "feat(tunnel): warn when dedup reuses a different local port"
```

---

### Task 2: Manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-dedup-port-warning-manual-qa.md`

- [ ] **Step 1: Confirm the gate**

Run: `flutter analyze 2>&1 | tail -6` — Expected: 0 errors, no issue introduced in `overview_tab.dart` by Task 1.
Run: `flutter test 2>&1 | tail -6` — Expected: all pass.

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-dedup-port-warning-manual-qa.md`:

```markdown
# Manual QA — Dedup port-reuse warning

Run on a real desktop with a reachable GCP VM.

- [ ] Open a Custom Tunnel (Direct) choosing local port A for a VM:remote → success snackbar "Túnel listo en 127.0.0.1:A".
- [ ] With that tunnel still up, open the Custom Tunnel again for the SAME VM:remote choosing a DIFFERENT local port B → the warning snackbar appears ("Se reusó un túnel existente en 127.0.0.1:A; el puerto B que pediste no se aplicó"), stays ~6s, and Copy still copies 127.0.0.1:A.
- [ ] Same two steps in SSH forward mode → the warning appears there too.
- [ ] Open a Custom Tunnel with a chosen port for a VM:remote that has NO existing tunnel → normal success message (no warning).
- [ ] Open a Custom Tunnel in AUTO mode (leave local port empty) for a VM:remote that already has a tunnel → normal success message on the reused port (no warning — you didn't request a specific port).
- [ ] Spanish and English locales both render the warning text correctly with the address and requested port.
```

- [ ] **Step 3: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-dedup-port-warning-manual-qa.md
git commit -m "docs(qa): manual QA checklist for dedup port-reuse warning"
```

---

## Self-Review

**1. Spec coverage:**
- Warn only when `choice.localPort != null && localPort != choice.localPort` → Task 1 Step 3 (`reused`). ✓
- Auto mode never warns → same guard (`choice.localPort != null`). ✓
- Both modes (shared handler) → Task 1 Step 3 is mode-agnostic. ✓
- Warning snackbar: distinct text + 6s duration + keeps Copy; non-reused keeps 4s default → Task 1 Step 3. ✓
- i18n key `customTunnelReusedPort(address String, requested int)` EN/ES + gen-l10n → Task 1 Steps 1-2. ✓
- Dart-only, no Rust/bridge → no task runs cargo/codegen beyond gen-l10n. ✓
- Verification = analyze + manual QA → Task 1 Steps 4-5 + Task 2. ✓

**2. Placeholder scan:** No TBD/TODO; the full replacement block is given, anchored to the `final address = ...` / `customTunnelReady` lines. ✓

**3. Type consistency:** `customTunnelReusedPort(String address, int requested)` matches the ARB placeholders (`address` String, `requested` int) and the call `l10n.customTunnelReusedPort(address, choice.localPort!)` (address is `String`, `choice.localPort!` is `int`). `reused` is `bool`. ✓
