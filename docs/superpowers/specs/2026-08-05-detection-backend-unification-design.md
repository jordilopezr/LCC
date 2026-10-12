# Diseño: Unificación del backend de detección (guest agent + serial)

**Fecha:** 2026-08-05
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Refactor de deduplicación (Rust-only; sin regen de bridge, sin cambios Dart). Sub-proyecto **A** de dos (A = backend; B = mover Doctor/Diagnostics a pestañas, posterior).

## Objetivo

Connectivity Doctor (`native/src/doctor.rs`) y el panel de Diagnostics (`native/src/diagnostics.rs`) implementan **por separado** la misma detección del *guest agent* (guest attributes → fallback por consola serial) y cada uno lee la consola serial con su propio GET. Esa duplicación ya causó un bug (el Doctor no detectaba un guest agent que Diagnostics sí veía) y **sigue teniendo drift residual** por interpretar distinto la respuesta de `getGuestAttributes`. Este trabajo colapsa ambas detecciones en **una única fuente de verdad** token-based en `diagnostics.rs`, de modo que Doctor y Diagnostics no puedan volver a diverger.

## Contexto

- **Helper ya compartido:** `diagnostics.rs::guest_agent_in_serial(contents) -> bool` (matcher puro de firmas del `google-guest-agent` en la serial) ya existe y el Doctor lo consume (`crate::diagnostics::guest_agent_in_serial`). Precedente de que la detección compartida vive en `diagnostics.rs`.
- **Fix parcial previo (commit `af3cefa`, 2026-08-05):** se añadió el fallback por serial al CHECK 9 del Doctor. Cerró el caso concreto reportado, pero dejó **dos** implementaciones de la lógica de 2 pasos y **dos** GET de serial.
- **Drift residual (la razón de A):** ante `getGuestAttributes` que responde **HTTP 200 con `items` vacío**, `diagnostics.rs::get_guest_agent_status` marca `is_reporting = true` de inmediato, mientras `doctor.rs::check_vm_guest_agent` exige `items` **no vacío** y, si están vacíos, cae al serial. En una VM con inventario 200-pero-vacío y sin firma en serial, **Diagnostics diría "activo" y Doctor "Warning"**. Falso positivo de Diagnostics.
- **Modelos de auth distintos:** `DiagnosticsClient` **exige** auth (`auth: Arc<GcpAuthClient>`, `new() -> Result`); `DoctorClient` **tolera** su ausencia (`auth: Option<Arc<…>>`, checks "Skipped"). El CHECK 9 del Doctor **solo corre cuando ya hay token** (`can_run_api_checks = has_auth && gcloud_authenticated`). Ambos usan `compute_base_url = "https://compute.googleapis.com/compute/v1"`. Una función **token-based** sirve a ambos sin arrastrar el desajuste `Option`/`Result`.

## Decisiones

| Decisión | Elección |
|---|---|
| Alcance | Unificar **guest agent + lectura de serial**. El GET de instancia / estado VM (doble fetch de bajo riesgo) **queda como está** |
| Ubicación | Función compartida **token-based** en `diagnostics.rs`, junto a `guest_agent_in_serial` (Enfoque 1) |
| Regla canónica de inventario | **200 con `items` no vacío ⇒ confirmado por inventario**; **200-vacío / 404 / otro / error ⇒ fallback a serial**; sin firma en serial ⇒ no reporta |
| Tipo de resultado | `GuestAgentDetection { reporting, source: Inventory\|Serial\|None, os_version, last_heartbeat }` |
| Errores | `detect_guest_agent` **nunca devuelve `Err`**: degrada a `source: None` (igual que hoy degradan ambos consumidores) |
| Consumidores | Adaptadores delgados: Diagnostics mapea a `GuestAgentStatus`; Doctor mapea a `DoctorCheckResult` (Pass/Warning) |
| Testing | Extraer la interpretación de inventario a un helper **puro** (`inventory_facts`) y testear el caso del drift (items vacío ⇒ `None`) |
| Bridge / Dart | **Sin cambios.** `GuestAgentStatus`, `VmDiagnostics` y `DoctorCheckResult` conservan su forma; la UI ve tipos idénticos |
| Cambio de comportamiento | Diagnostics deja de reportar `is_reporting=true` ante inventario 200-vacío sin firma en serial (corrección del falso positivo) |

## Diseño

### 1. Tipo de resultado (nuevo, `pub(crate)` en `diagnostics.rs`)

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum GuestAgentSource {
    /// Confirmado por getGuestAttributes con items de inventario no vacíos.
    Inventory,
    /// Confirmado por la firma del guest agent en la consola serial.
    Serial,
    /// Ni inventario ni serial muestran el agente.
    None,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct GuestAgentDetection {
    /// true si source != None.
    pub reporting: bool,
    pub source: GuestAgentSource,
    /// Solo cuando source == Inventory.
    pub os_version: Option<String>,
    /// Solo cuando source == Inventory.
    pub last_heartbeat: Option<String>,
}
```
`GuestAgentSource` implementa `Default` como `None` (para el `#[derive(Default)]` de `GuestAgentDetection`).

### 2. Interpretación de inventario — helper **puro** (nuevo, testeable)

```rust
/// Extrae los hechos del inventario de una respuesta de getGuestAttributes.
/// Devuelve Some((os_version, last_heartbeat)) SOLO si `queryValue.items` no
/// está vacío (⇒ inventario confirmado). Devuelve None si está vacío o ausente
/// (⇒ el llamador debe caer al fallback por serial). Esta es la regla canónica
/// que elimina el drift Doctor/Diagnostics.
fn inventory_facts(body: &serde_json::Value) -> Option<(Option<String>, Option<String>)>
```
Reglas:
- `queryValue.items` ausente o vacío ⇒ `None`.
- items no vacío ⇒ `Some((os_version, last_heartbeat))`, extrayendo:
  - `os_version` de la clave `LongName` o `KernelRelease`,
  - `last_heartbeat` de la clave `LastUpdated`,
  - (ambos `None` si esas claves no aparecen, pero el retorno sigue siendo `Some` porque hay inventario).

### 3. Función unificada — la fuente de verdad (nueva, `pub(crate)`)

```rust
pub(crate) async fn detect_guest_agent(
    base_url: &str,
    token: &str,
    project: &str,
    zone: &str,
    instance: &str,
) -> GuestAgentDetection
```
Comportamiento:
- Construye un `reqwest::Client` con **timeout de 10s** internamente (la detección no debe colgarse; iguala el timeout que ya usa el Doctor).
- **Paso 1 — inventario:** GET `{base_url}/projects/{p}/zones/{z}/instances/{i}/getGuestAttributes?queryPath=guestInventory/`.
  - Si HTTP 200 y `inventory_facts(&body)` ⇒ `Some((os_version, last_heartbeat))`:
    return `GuestAgentDetection { reporting: true, source: Inventory, os_version, last_heartbeat }`.
  - En cualquier otro caso (200-vacío, 404, otro status, error de red) ⇒ continúa al paso 2.
- **Paso 2 — serial:** GET `{base_url}/projects/{p}/zones/{z}/instances/{i}/serialPort?port=1`, lee `body["contents"]`, aplica `guest_agent_in_serial(contents)`:
  - true ⇒ `GuestAgentDetection { reporting: true, source: Serial, os_version: None, last_heartbeat: None }`.
  - false / error ⇒ `GuestAgentDetection { reporting: false, source: None, .. }`.
- **Nunca devuelve `Err`.**

### 4. Consumidor 1 — Diagnostics (`get_guest_agent_status`)

Se reescribe como adaptador delgado (misma firma, `Result<GuestAgentStatus>`):
```rust
async fn get_guest_agent_status(&self, project, zone, instance) -> Result<GuestAgentStatus> {
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
- Preserva el `os_type = "Detected via Serial"` que hoy pone el camino serial de Diagnostics.
- `get_vm_diagnostics` la sigue llamando con `.unwrap_or_default()` — **sin cambios**.
- Se **borra** `DiagnosticsClient::check_guest_agent_via_serial` (su lógica quedó dentro de `detect_guest_agent`).

### 5. Consumidor 2 — Doctor (`check_vm_guest_agent`, CHECK 9)

Se reescribe el cuerpo tras obtener el token (los guardas de auth/token y el `skipped_check` se conservan):
```rust
let d = crate::diagnostics::detect_guest_agent(
    &self.compute_base_url, &token, project, zone, instance,
).await;
match d.source {
    GuestAgentSource::Inventory => /* Pass: "Guest agent is responding" */,
    GuestAgentSource::Serial    => /* Pass: "Guest agent detected via serial console" */,
    GuestAgentSource::None      => /* Warning: "Guest agent not reporting" + details/suggestion actuales */,
}
```
- Se **borra** `DoctorClient::guest_agent_detected_via_serial` y el GET+parse de inventario inline del paso 1 del CHECK 9.
- `check_id`, `name`, `category`, mensajes, `details` y `suggestion` de cada rama se conservan idénticos a los actuales.

### 6. Qué se borra (prueba de deduplicación)

| Archivo | Elemento eliminado |
|---|---|
| `doctor.rs` | `guest_agent_detected_via_serial` (GET serial recortado) |
| `doctor.rs` | GET+parse de `getGuestAttributes` inline en `check_vm_guest_agent` (paso 1) |
| `diagnostics.rs` | `check_guest_agent_via_serial` |
| `diagnostics.rs` | GET+parse de `getGuestAttributes` en `get_guest_agent_status` |

Tras A queda **una** implementación de la lógica de 2 pasos y **un** camino de lectura de serial para la detección del guest agent.

## Testing (TDD)

La orquestación HTTP de `detect_guest_agent` es glue fino sobre dos helpers **puros**, que son los que se testean:

- **`inventory_facts` (nuevo):**
  - items no vacío con `LongName` y `LastUpdated` ⇒ `Some((Some(os), Some(hb)))`.
  - items no vacío sin esas claves ⇒ `Some((None, None))` (hay inventario, sin metadatos).
  - `queryValue.items` **vacío** ⇒ `None` (**el caso que causaba el drift**).
  - `queryValue` ausente / body arbitrario ⇒ `None`.
- **`guest_agent_in_serial` (existente):** su test `test_guest_agent_in_serial` se conserva.

No se añaden dependencias de mock HTTP; la lógica de decisión vive en los helpers puros.

## Alcance / fuera de alcance

- **Dentro:** detección de guest agent (2 pasos) y lectura de serial para esa detección; sus consumidores en Doctor y Diagnostics.
- **Fuera:** el GET de instancia / estado VM (doble fetch, bajo riesgo, mapeo de estado propio de cada surface); red, discos, audit logs, timestamps (solo Diagnostics); auth/APIs/firewall/local-clients (solo Doctor); `get_serial_port_output` público de Diagnostics (feature "ver consola serial", intacto); mover Doctor/Diagnostics a pestañas (**sub-proyecto B**).

## Verificación

- `cd native && cargo test` (nuevos tests de `inventory_facts` + `test_guest_agent_in_serial` existente en verde).
- `cd native && cargo build && cargo build --release` (la app carga `native/target/release/libnative.so`).
- Sin regen de bridge ni cambios en `lib/` ⇒ no se requiere `flutter test`/`analyze` para A, pero deben seguir en verde (nada cambió en Dart).
