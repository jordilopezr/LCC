# Detection Backend Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the duplicated guest-agent detection (guest attributes → serial fallback) and serial reads in `doctor.rs` and `diagnostics.rs` into a single token-based source of truth in `diagnostics.rs`, so Connectivity Doctor and the Diagnostics panel can never drift.

**Architecture:** Add a pure inventory-interpretation helper (`inventory_facts`) plus a unified async detector (`detect_guest_agent`) that returns a typed `GuestAgentDetection`, both `pub(crate)` in `native/src/diagnostics.rs` next to the existing `guest_agent_in_serial`. Rewrite `DiagnosticsClient::get_guest_agent_status` and `DoctorClient::check_vm_guest_agent` as thin adapters over it, deleting each surface's private serial GET and inline guest-attributes logic.

**Tech Stack:** Rust, `reqwest`, `serde_json`, `tokio`. Spec: `docs/superpowers/specs/2026-08-05-detection-backend-unification-design.md`.

## Global Constraints

- **Rust-only.** No bridge regen, no Dart changes. `GuestAgentStatus`, `VmDiagnostics`, `DoctorCheckResult` keep their exact shape.
- **Canonical inventory rule:** HTTP 200 with non-empty `queryValue.items` ⇒ inventory-confirmed; 200-empty / 404 / other / network error ⇒ serial fallback; no serial signature ⇒ not reporting.
- **`detect_guest_agent` never returns `Err`** — it degrades to `GuestAgentSource::None` on any failure.
- **Preserve verbatim** the current `check_id`, `name`, `category`, `message`, `details`, and `suggestion` strings of each CHECK 9 branch, and the `os_type = "Detected via Serial"` label of the Diagnostics serial path.
- **Rebuild both profiles:** `cargo build` **and** `cargo build --release` (the app loads `native/target/release/libnative.so`).
- **Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer** (that trailer is for documentation commits only).
- Branch: `27H1-Preview` (already checked out).

---

### Task 1: Unified detection in `diagnostics.rs` + Diagnostics adoption

Introduces the pure helper, the types, the unified detector, and rewires the Diagnostics consumer in the same task so the new function has a live caller (no dead code). All changes are inside `native/src/diagnostics.rs`.

**Files:**
- Modify: `native/src/diagnostics.rs` (add types + helpers after `guest_agent_in_serial` at line 32; rewrite `get_guest_agent_status` at lines 475-540; delete `check_guest_agent_via_serial` at lines 445-472; add tests in the `#[cfg(test)] mod tests` block)
- Test: `native/src/diagnostics.rs` (same file, `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: existing `guest_agent_in_serial(contents: &str) -> bool` (already in this file); `DiagnosticsClient` fields `auth: Arc<GcpAuthClient>` and `compute_base_url: String`.
- Produces (used by Task 2):
  - `pub(crate) enum GuestAgentSource { Inventory, Serial, None }` (derives `Default` = `None`).
  - `pub(crate) struct GuestAgentDetection { pub reporting: bool, pub source: GuestAgentSource, pub os_version: Option<String>, pub last_heartbeat: Option<String> }`.
  - `pub(crate) async fn detect_guest_agent(base_url: &str, token: &str, project: &str, zone: &str, instance: &str) -> GuestAgentDetection`.

- [ ] **Step 1: Write the failing tests for `inventory_facts`**

Add these tests inside the existing `#[cfg(test)] mod tests` block at the end of `native/src/diagnostics.rs`:

```rust
#[test]
fn test_inventory_facts_populated() {
    let body = serde_json::json!({
        "queryValue": { "items": [
            {"key": "LongName", "value": "Debian GNU/Linux 12"},
            {"key": "LastUpdated", "value": "2026-08-05T00:00:00Z"}
        ]}
    });
    assert_eq!(
        super::inventory_facts(&body),
        Some((
            Some("Debian GNU/Linux 12".to_string()),
            Some("2026-08-05T00:00:00Z".to_string())
        ))
    );
}

#[test]
fn test_inventory_facts_items_without_metadata() {
    // Non-empty items ⇒ inventory-confirmed even without os/heartbeat keys.
    let body = serde_json::json!({
        "queryValue": { "items": [ {"key": "ShortName", "value": "debian"} ] }
    });
    assert_eq!(super::inventory_facts(&body), Some((None, None)));
}

#[test]
fn test_inventory_facts_empty_items_is_none() {
    // The drift case: HTTP 200 with an empty inventory must NOT confirm.
    let body = serde_json::json!({ "queryValue": { "items": [] } });
    assert_eq!(super::inventory_facts(&body), None);
}

#[test]
fn test_inventory_facts_absent_queryvalue_is_none() {
    assert_eq!(super::inventory_facts(&serde_json::json!({})), None);
    assert_eq!(super::inventory_facts(&serde_json::json!({ "foo": 1 })), None);
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `cd native && cargo test inventory_facts 2>&1 | head -30`
Expected: FAIL — `cannot find function inventory_facts in module super` (function not defined yet).

- [ ] **Step 3: Add the types and the `inventory_facts` helper**

Insert immediately **after** `guest_agent_in_serial` (after line 32, before the `SERIAL PORT OUTPUT` banner comment) in `native/src/diagnostics.rs`:

```rust
/// Where a guest-agent detection was confirmed. `Default` is `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum GuestAgentSource {
    /// Confirmed via getGuestAttributes with non-empty inventory items.
    Inventory,
    /// Confirmed via the guest agent's signature in the serial console.
    Serial,
    /// Neither inventory nor serial shows the agent.
    #[default]
    None,
}

/// Result of the unified guest-agent detection shared by the Diagnostics
/// panel and the Connectivity Doctor. `os_version`/`last_heartbeat` are only
/// populated when `source == Inventory`.
#[derive(Debug, Clone, Default)]
pub(crate) struct GuestAgentDetection {
    pub reporting: bool,
    pub source: GuestAgentSource,
    pub os_version: Option<String>,
    pub last_heartbeat: Option<String>,
}

/// Extract inventory facts from a getGuestAttributes response body.
/// Returns `Some((os_version, last_heartbeat))` ONLY when `queryValue.items`
/// is non-empty (⇒ inventory-confirmed). Returns `None` when items is empty
/// or absent (⇒ caller falls back to the serial console). This is the
/// canonical rule that keeps Doctor and Diagnostics from drifting.
fn inventory_facts(body: &serde_json::Value) -> Option<(Option<String>, Option<String>)> {
    let items = body["queryValue"]["items"].as_array()?;
    if items.is_empty() {
        return None;
    }
    let mut os_version = None;
    let mut last_heartbeat = None;
    for item in items {
        let key = item["key"].as_str().unwrap_or("");
        let value = item["value"].as_str().unwrap_or("");
        match key {
            "LongName" | "KernelRelease" => os_version = Some(value.to_string()),
            "LastUpdated" => last_heartbeat = Some(value.to_string()),
            _ => {}
        }
    }
    Some((os_version, last_heartbeat))
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd native && cargo test inventory_facts 2>&1 | tail -20`
Expected: PASS — `test_inventory_facts_populated`, `test_inventory_facts_items_without_metadata`, `test_inventory_facts_empty_items_is_none`, `test_inventory_facts_absent_queryvalue_is_none` all pass.

- [ ] **Step 5: Add the `detect_guest_agent` function**

Insert immediately **after** the `inventory_facts` function added in Step 3:

```rust
/// Unified guest-agent detection shared by the Diagnostics panel and the
/// Connectivity Doctor so both surfaces always agree. Two steps:
/// 1. getGuestAttributes (OS inventory) — confirmed only when items are
///    non-empty (see `inventory_facts`).
/// 2. Serial console fallback — matches the guest agent's log signature
///    (see `guest_agent_in_serial`).
/// Never returns `Err`: degrades to `GuestAgentSource::None` on any failure.
pub(crate) async fn detect_guest_agent(
    base_url: &str,
    token: &str,
    project: &str,
    zone: &str,
    instance: &str,
) -> GuestAgentDetection {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap_or_default();

    // Step 1: guest attributes (OS inventory).
    let inv_url = format!(
        "{}/projects/{}/zones/{}/instances/{}/getGuestAttributes?queryPath=guestInventory/",
        base_url, project, zone, instance
    );
    if let Ok(r) = client.get(&inv_url).bearer_auth(token).send().await {
        if r.status().is_success() {
            let body: serde_json::Value = r.json().await.unwrap_or_default();
            if let Some((os_version, last_heartbeat)) = inventory_facts(&body) {
                return GuestAgentDetection {
                    reporting: true,
                    source: GuestAgentSource::Inventory,
                    os_version,
                    last_heartbeat,
                };
            }
        }
    }

    // Step 2: serial console fallback.
    let serial_url = format!(
        "{}/projects/{}/zones/{}/instances/{}/serialPort?port=1",
        base_url, project, zone, instance
    );
    if let Ok(r) = client.get(&serial_url).bearer_auth(token).send().await {
        if r.status().is_success() {
            let body: serde_json::Value = r.json().await.unwrap_or_default();
            let contents = body["contents"].as_str().unwrap_or("");
            if guest_agent_in_serial(contents) {
                return GuestAgentDetection {
                    reporting: true,
                    source: GuestAgentSource::Serial,
                    os_version: None,
                    last_heartbeat: None,
                };
            }
        }
    }

    GuestAgentDetection::default()
}
```

- [ ] **Step 6: Rewrite `get_guest_agent_status` as a thin adapter**

Replace the **entire** current `get_guest_agent_status` method (lines 474-540, the doc comment `/// Get guest agent status from guest attributes` through its closing brace) with:

```rust
    /// Get guest agent status via the unified detection (shared with the
    /// Connectivity Doctor so both surfaces agree).
    async fn get_guest_agent_status(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<GuestAgentStatus> {
        let token = self.auth.get_access_token().await?;
        let d = detect_guest_agent(&self.compute_base_url, &token, project, zone, instance).await;
        Ok(GuestAgentStatus {
            is_reporting: d.reporting,
            os_type: match d.source {
                GuestAgentSource::Serial => Some("Detected via Serial".to_string()),
                _ => None,
            },
            os_version: d.os_version,
            last_heartbeat: d.last_heartbeat,
        })
    }
```

- [ ] **Step 7: Delete the now-unused `check_guest_agent_via_serial` method**

Delete the **entire** `check_guest_agent_via_serial` method (lines 445-472, the doc comment `/// Fallback to check guest agent via serial console` through its closing brace). It had exactly one caller (`get_guest_agent_status`), which no longer references it. `get_serial_port_output` stays (still used by the public wrapper and by nothing here).

- [ ] **Step 8: Build and run the full diagnostics test suite**

Run: `cd native && cargo build 2>&1 | tail -20`
Expected: builds with no errors and no `dead_code` / `unused` warnings for the touched items.

Run: `cd native && cargo test diagnostics 2>&1 | tail -25`
Expected: PASS — the four new `inventory_facts` tests plus the existing `test_guest_agent_in_serial`, `test_default_guest_agent_status`, etc. all pass.

- [ ] **Step 9: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/diagnostics.rs
git commit -m "refactor(diagnostics): unified detect_guest_agent + inventory_facts source of truth"
```

---

### Task 2: Doctor adoption of `detect_guest_agent`

Rewrites CHECK 9 to route through the unified detector and deletes the Doctor's private serial GET and inline guest-attributes logic. All changes are inside `native/src/doctor.rs`.

**Files:**
- Modify: `native/src/doctor.rs` (rewrite `check_vm_guest_agent` body at lines 760-854; delete `guest_agent_detected_via_serial` at lines 856-884)

**Interfaces:**
- Consumes (from Task 1): `crate::diagnostics::detect_guest_agent(base_url, token, project, zone, instance) -> GuestAgentDetection`; `crate::diagnostics::GuestAgentSource::{Inventory, Serial, None}`.
- Produces: no new public surface — `DoctorCheckResult` shape unchanged.

- [ ] **Step 1: Rewrite the body of `check_vm_guest_agent`**

In `native/src/doctor.rs`, keep the method signature and the auth-guard + token-guard prologue (lines 760-782, up to and including the `let token = match auth.get_access_token().await { ... };` block). Replace **everything after** the token guard — i.e. the current inline guest-attributes GET (step 1, lines ~784-817), the serial fallback call (step 2, lines ~819-839), and the final Warning (step 3, lines ~841-853) — with:

```rust
        // Unified detection shared with the Diagnostics panel so both agree.
        let detection = crate::diagnostics::detect_guest_agent(
            &self.compute_base_url,
            &token,
            project,
            zone,
            instance,
        )
        .await;

        match detection.source {
            crate::diagnostics::GuestAgentSource::Inventory => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Pass,
                message: "Guest agent is responding".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            crate::diagnostics::GuestAgentSource::Serial => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Pass,
                message: "Guest agent detected via serial console".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            crate::diagnostics::GuestAgentSource::None => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Warning,
                message: "Guest agent not reporting".to_string(),
                details: Some("Neither guest attributes (OS inventory) nor the serial console show the guest agent. It may not be installed, or the VM may be stopped/booting.".to_string()),
                suggestion: Some("Ensure the VM is running and the Google guest agent is installed.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }
```

(The final `}` above closes `check_vm_guest_agent`.)

- [ ] **Step 2: Delete the now-unused `guest_agent_detected_via_serial` method**

Delete the **entire** `guest_agent_detected_via_serial` method (the doc comment `/// Serial-console fallback for the guest-agent check:` through its closing brace, lines ~856-884). Its only caller was `check_vm_guest_agent`, which no longer references it.

- [ ] **Step 3: Build (debug) and check for warnings**

Run: `cd native && cargo build 2>&1 | tail -20`
Expected: builds with no errors. No `unused`/`dead_code` warnings for `check_vm_guest_agent` or the removed method. `reqwest` may still be used elsewhere in `doctor.rs` (the other checks) — confirm no "unused import" appears.

- [ ] **Step 4: Run the doctor + diagnostics test suites**

Run: `cd native && cargo test 2>&1 | tail -30`
Expected: PASS — all existing `doctor` tests (`test_check_gcloud_installed`, `test_check_local_clients`, `test_report_markdown_generation`, `test_report_redacts_sensitive_data`, `test_category_display_names`, `test_category_all`, `test_skipped_check`) and all `diagnostics` tests (including the four `inventory_facts` tests from Task 1) pass.

- [ ] **Step 5: Build the release profile**

Run: `cd native && cargo build --release 2>&1 | tail -10`
Expected: release build succeeds (this is the `libnative.so` the app loads).

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/doctor.rs
git commit -m "refactor(doctor): route CHECK 9 through unified detect_guest_agent"
```

---

## Self-Review

**1. Spec coverage:**
- Canonical inventory rule (200 non-empty ⇒ Inventory; else serial) → Task 1 Step 3 (`inventory_facts`) + Step 5 (`detect_guest_agent`). ✓
- `GuestAgentDetection` / `GuestAgentSource` types → Task 1 Step 3. ✓
- `detect_guest_agent` token-based, 10s timeout, never `Err` → Task 1 Step 5. ✓
- Diagnostics adapter preserving `os_type = "Detected via Serial"` → Task 1 Step 6. ✓
- Delete `check_guest_agent_via_serial` → Task 1 Step 7. ✓
- Doctor adapter with verbatim Pass/Serial/Warning messages → Task 2 Step 1. ✓
- Delete `guest_agent_detected_via_serial` + inline inventory GET → Task 2 Steps 1-2. ✓
- Behavior change (empty-200 no longer auto-reports) → encoded by `inventory_facts` empty-items ⇒ `None`, tested in Task 1 Step 1. ✓
- Testing via pure helpers → Task 1 Step 1 (`inventory_facts`), existing `guest_agent_in_serial` test retained. ✓
- Verification (cargo test + build + release) → Task 1 Step 8, Task 2 Steps 4-5. ✓
- No bridge regen / no Dart changes → no task touches `lib/` or runs codegen. ✓

**2. Placeholder scan:** No TBD/TODO; every code step carries full code. ✓

**3. Type consistency:** `GuestAgentSource` / `GuestAgentDetection` / `detect_guest_agent` signature identical in Task 1 (definition) and Task 2 (consumption); field names `reporting`/`source`/`os_version`/`last_heartbeat` and variants `Inventory`/`Serial`/`None` match across both tasks. Diagnostics adapter uses `d.reporting`, `d.source`, `d.os_version`, `d.last_heartbeat` — all defined. ✓
