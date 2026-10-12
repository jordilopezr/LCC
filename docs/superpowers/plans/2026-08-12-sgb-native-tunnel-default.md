# SG-B: túnel IAP directo nativo por defecto — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hacer que el túnel IAP **directo** use el motor **nativo por defecto**, con `gcloud` alcanzable solo como opt-out (`LCC_TUNNEL_ENGINE=gcloud`).

**Architecture:** Cambio Rust interno en `native/src/tunnel.rs`: sustituir el resolvedor `selected_engine() -> Option<TunnelEngine>` (default gcloud) por un helper puro `parse_tunnel_engine(Option<&str>) -> TunnelEngine` (Native por defecto) + wrapper `tunnel_engine()`, e invertir la condición en `start()`. Sin cambios en el bridge ni en Dart.

**Tech Stack:** Rust (`native/`), `cargo test`. Spec: `docs/superpowers/specs/2026-08-12-sgb-native-tunnel-default-design.md`. Roadmap: `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Global Constraints

- **Solo Rust**, únicamente `native/src/tunnel.rs` (+ un doc de QA). No Dart, no regen del bridge, no `cargo` fuera de `native/`. Do NOT run `dart format`.
- **Native es el default del túnel IAP directo**; `gcloud compute start-iap-tunnel` solo con `LCC_TUNNEL_ENGINE=gcloud`. **Sin fallback silencioso**: un fallo del nativo se propaga como error de túnel.
- **Solo `gcloud` opta a la salida**; unset / `native` / cualquier otro valor → Native.
- **Conservar** `Backend::Gcloud` + `start_gcloud` (alcanzables por opt-out). Su borrado es **SG-E**.
- **SSH forward sin cambios:** `ssh_forward_engine()`/`start_ssh_forward()` siguen con gcloud por defecto (fase posterior). No tocar.
- `selected_engine` es **interno** de `tunnel.rs` (usado en `start()` y en 4 asserts de test; sin referencias externas) → seguro de reemplazar. Actualizar TODOS sus usos.
- **Tests puros:** sustituir los tests env-based (`engine_defaults_to_none_when_unset`, `engine_can_be_forced`, que mutan `LCC_TUNNEL_ENGINE` a nivel de proceso) por tests de `parse_tunnel_engine` sin env.
- Verificar: `cargo test` (en `native/`) verde, `cargo build --release` OK, `flutter test` (suite) sigue verde. Sin warnings nuevos.
- **Commits de código NO llevan trailer `Co-Authored-By`** (solo docs). Rama `27H1-Preview`.

---

### Task 1: Invertir el motor del túnel IAP directo a Native por defecto

Refactor + wiring + tests, todo en `native/src/tunnel.rs`. TDD: los tests puros nuevos no compilan hasta que exista `parse_tunnel_engine`.

**Files:**
- Modify: `native/src/tunnel.rs` (`selected_engine` ~26-35; `start()` ~174-198; tests env-based ~755-778)

**Interfaces:**
- Produce: `fn parse_tunnel_engine(Option<&str>) -> TunnelEngine` (privada, pura) y `pub fn tunnel_engine() -> TunnelEngine` (Native default). Reemplazan a `pub fn selected_engine() -> Option<TunnelEngine>`.
- Consume: `enum TunnelEngine { Native, Gcloud }` (ya deriva `Debug, Clone, Copy, PartialEq, Eq`), `start_native`/`start_gcloud` (sin cambios).

- [ ] **Step 1: Escribir los tests puros nuevos**

En el módulo de tests de `native/src/tunnel.rs`, añadir (junto a los tests de motor existentes):

```rust
#[test]
fn tunnel_engine_defaults_to_native() {
    assert_eq!(parse_tunnel_engine(None), TunnelEngine::Native);
    assert_eq!(parse_tunnel_engine(Some("native")), TunnelEngine::Native);
    assert_eq!(parse_tunnel_engine(Some("garbage")), TunnelEngine::Native);
}

#[test]
fn tunnel_engine_gcloud_opt_out() {
    assert_eq!(parse_tunnel_engine(Some("gcloud")), TunnelEngine::Gcloud);
}
```

- [ ] **Step 2: Verificar que fallan (no compila)**

Run: `cd native && cargo test tunnel_engine 2>&1 | tail -15`
Expected: error de compilación `cannot find function \`parse_tunnel_engine\`` (aún no existe).

- [ ] **Step 3: Añadir el helper puro + wrapper; eliminar `selected_engine`**

En `native/src/tunnel.rs`, reemplazar el bloque de `selected_engine` (~26-35):

Antes:
```rust
/// Read `LCC_TUNNEL_ENGINE`. `None` (unset) and `gcloud` both use the default
/// gcloud engine; `native` opts into the experimental native engine. Debug aid
/// only; deliberately not exposed in Settings.
pub fn selected_engine() -> Option<TunnelEngine> {
    match std::env::var("LCC_TUNNEL_ENGINE").ok()?.as_str() {
        "native" => Some(TunnelEngine::Native),
        "gcloud" => Some(TunnelEngine::Gcloud),
        _ => None,
    }
}
```
Después:
```rust
/// Pure parse of the tunnel engine selector (testable without env).
/// Native is the default; only an explicit `gcloud` opts out to the legacy
/// `gcloud compute start-iap-tunnel` engine.
fn parse_tunnel_engine(val: Option<&str>) -> TunnelEngine {
    match val {
        Some("gcloud") => TunnelEngine::Gcloud,
        _ => TunnelEngine::Native, // unset, "native", or any other value
    }
}

/// Read `LCC_TUNNEL_ENGINE`. Native is the default; `gcloud` opts out to the
/// legacy engine. Debug/escape-hatch aid; deliberately not exposed in Settings.
pub fn tunnel_engine() -> TunnelEngine {
    parse_tunnel_engine(std::env::var("LCC_TUNNEL_ENGINE").ok().as_deref())
}
```
(No tocar `parse_ssh_forward_engine`/`ssh_forward_engine`.)

- [ ] **Step 4: Invertir la condición en `start()`**

En `start()` (~174-198), reemplazar:
```rust
    let forced = selected_engine();

    // gcloud is the default engine (reliable). The native engine is still
    // experimental and only runs when explicitly opted in via
    // LCC_TUNNEL_ENGINE=native, with no fallback so its failures are visible
    // during debugging.
    if forced == Some(TunnelEngine::Native) {
```
por:
```rust
    // Native is the default IAP-tunnel engine. `gcloud compute start-iap-tunnel`
    // is reachable only as an explicit opt-out via LCC_TUNNEL_ENGINE=gcloud. A
    // native failure surfaces as a tunnel error (no silent fallback).
    if tunnel_engine() == TunnelEngine::Native {
```
No cambiar los cuerpos native/gcloud que siguen (inserción en `TUNNELS`, `start_reaper_once`, `tracing::info!`).

- [ ] **Step 5: Eliminar los tests env-based obsoletos**

En el módulo de tests (~755-778), eliminar la nota "DEVIATION" asociada y los dos tests `engine_defaults_to_none_when_unset` y `engine_can_be_forced` (referencian `selected_engine`, que ya no existe, y mutan `LCC_TUNNEL_ENGINE` a nivel de proceso). Los reemplazan los tests puros del Step 1.

- [ ] **Step 6: Verificar que compila y pasan los tests**

Run: `cd native && cargo test 2>&1 | tail -20`
Expected: compila; `tunnel_engine_defaults_to_native` y `tunnel_engine_gcloud_opt_out` pasan; el resto de la suite Rust sigue verde. (Si algún test o `start()` aún referencia `selected_engine`, corregirlo.)

- [ ] **Step 7: Build release**

Run: `cd native && cargo build --release 2>&1 | tail -6`
Expected: compila sin errores ni warnings nuevos.

- [ ] **Step 8: Suite Flutter (no-regresión)**

Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6`
Expected: la suite Flutter sigue verde (SG-B no toca Dart).

- [ ] **Step 9: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/tunnel.rs
git commit -m "feat(tunnel): default the direct IAP tunnel to the native engine (gcloud opt-out)"
```

---

### Task 2: Checklist de QA manual

Establecer túneles reales no es unit-testeable; esta lista cubre la matriz de conexión que un humano debe verificar con el nativo por defecto.

**Files:**
- Create: `docs/superpowers/plans/2026-08-12-sgb-native-tunnel-default-manual-qa.md`

- [ ] **Step 1: Confirmar la verja**

Run: `cd native && cargo test 2>&1 | tail -6` — Expected: verde.
Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6` — Expected: suite verde.

- [ ] **Step 2: Escribir el checklist**

Crear `docs/superpowers/plans/2026-08-12-sgb-native-tunnel-default-manual-qa.md`:

```markdown
# QA manual — SG-B: túnel IAP directo nativo por defecto

El túnel IAP directo usa ahora el motor **nativo por defecto** (sin `LCC_TUNNEL_ENGINE`).
Establecer túneles reales no es unit-testeable; verificar a mano contra una VM real.

Con el default (sin variable de entorno) — todo debe ir por el motor **nativo**:
- [ ] Conectar RDP a una VM Windows funciona.
- [ ] Conectar VNC funciona.
- [ ] SSH embebido (pestaña) conecta.
- [ ] SFTP (pestaña) abre y lista archivos.
- [ ] Custom Tunnel en **modo directo** (IAP) a un puerto arbitrario conecta.
- [ ] Reconexión de un túnel tras caída y **reuso del puerto local** elegido funcionan.
- [ ] (Opcional, logs) el log muestra `engine = "native"` al establecer el túnel.

Escotilla de opt-out:
- [ ] Con `LCC_TUNNEL_ENGINE=gcloud`, el túnel directo se establece por gcloud (`engine = "gcloud"`), como antes.
- [ ] Con el nativo, si el túnel falla, aparece el error localizado (no cae a gcloud en silencio).

Sin cambios en esta fase:
- [ ] El SSH forward (`-L`) sigue funcionando por gcloud por defecto.
```

- [ ] **Step 3: Commit** (docs)

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-12-sgb-native-tunnel-default-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SG-B native tunnel default"
```

---

## Self-Review

**1. Spec coverage:**
- `parse_tunnel_engine` (puro, Native default) + `tunnel_engine()` wrapper, reemplazan `selected_engine` → Task 1 Steps 3. ✓
- `start()` invierte la condición + comentario → Task 1 Step 4. ✓
- Solo `gcloud` opta a la salida; sin fallback → Steps 3-4 + Global Constraints. ✓
- Conservar `Backend::Gcloud`/`start_gcloud` (opt-out) → no se tocan; Global Constraints. ✓
- SSH forward sin cambios → Global Constraints (no tocar `ssh_forward_engine`). ✓
- Sustituir tests env-based por puros → Task 1 Steps 1-2, 5. ✓
- Verificación cargo test + build + suite Flutter + checklist QA → Task 1 Steps 6-8 + Task 2. ✓
- Solo Rust, sin bridge → Global Constraints. ✓

**2. Placeholder scan:** Sin TBD/TODO. El helper, el wrapper, el cambio de `start()`, los tests y el checklist son código/contenido concreto. ✓

**3. Type consistency:** `parse_tunnel_engine(Option<&str>) -> TunnelEngine` y `tunnel_engine() -> TunnelEngine` coinciden entre definición (Step 3), uso en `start()` (Step 4) y tests (Step 1). `TunnelEngine` deriva `Debug, PartialEq, Eq` → `assert_eq!` válido. Se elimina `selected_engine` en todos sus usos (start + tests). ✓
