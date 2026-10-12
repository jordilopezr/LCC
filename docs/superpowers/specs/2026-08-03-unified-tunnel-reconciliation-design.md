# Diseño: `IapTunnel` unificado — reconciliar reaper de seguridad + motor nativo (para sumar tabbed-workspace)

**Fecha:** 2026-08-03
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Reconciliación de integración (Rust, código de red/seguridad)

## Objetivo

Sumar `feature/tabbed-workspace` a `27H1-Preview`. Su `native/src/tunnel.rs` divergió del que ya está en el Preview (el de `security/loopback-listener`), y **depende del motor nativo** de `feature/native-iap-tunnel` (`Backend::Native(crate::iap_tunnel::NativeTunnel)`). Este trabajo diseña un **`IapTunnel` unificado** que combina las tres direcciones —abstracción de motor (native/gcloud), reaper de túneles inactivos (seguridad T1) y endurecimiento de `gcloud`— para que `native-iap-tunnel` y `tabbed-workspace` mergeen limpio.

## Contexto del código actual (tres diseños divergentes)

- **`27H1-Preview` (de `security/loopback-listener`)** — `native/src/tunnel.rs`:
  - `pub struct IapTunnel { process: Child, local_port, last_active: Instant }`.
  - **Reaper**: `IDLE_TIMEOUT = 120s`, `POLL_INTERVAL = 30s`, `read_proc_net_tcp()`, `port_has_active_connection(proc_tcp, proc_tcp6, port)` (detección por conexión ESTABLISHED en loopback sobre el puerto local), `should_reap(last_active, now, idle_timeout)`, `reap_idle_tunnels_once()` (refresca `last_active` de túneles con conexión activa; reapea los inactivos > 120s con `tunnel.stop()` **tras** soltar el lock de `TUNNELS`), `start_reaper_once()` (hilo perezoso `std::sync::Once`), `touch_tunnel_by_local_port(port)`.
  - `IapTunnel::stop()` mata el proceso gcloud (`process.kill()`).
  - **Sin** enum `Backend`, **sin** `iap_tunnel`.
- **`feature/native-iap-tunnel` (y `feature/tabbed-workspace`, idéntico)** — `native/src/tunnel.rs`:
  - `enum Backend { Native(crate::iap_tunnel::NativeTunnel), Gcloud(Child) }`.
  - `pub struct IapTunnel { backend: Backend, local_port }` (**sin** `last_active`).
  - `impl IapTunnel`: `stop()` (despacha a `NativeTunnel::stop()` o `process.kill()`), `is_process_alive()` (despacha a `is_running()` o `try_wait()`), `is_port_listening()`.
  - `start_tunnel(...)`: selecciona motor → `start_native(...)` (`crate::iap_tunnel::start(TunnelTarget::new(...))` → `IapTunnel { backend: Backend::Native(..) }`) o el camino gcloud (`IapTunnel { backend: Backend::Gcloud(child) }`, hoy con `Command::new("gcloud")`). **Sin** reaper.
  - `native/src/iap_tunnel.rs` (motor nativo: `TunnelTarget`, `NativeTunnel` con `stop()`/`is_running()`/`local_port`, `start(target)`), registrado en `native/src/lib.rs` como `pub mod iap_tunnel;` (el Preview **no** lo tiene).
- **`security/gcloud-abs-path` (ya en el Preview)**: los spawns de `gcloud` usan `crate::gcloud_bin::gcloud_path()` en vez de `Command::new("gcloud")`.

**Clave:** abstracción-de-motor y reaping-por-inactividad son **ortogonales**. El reaper detecta por **conexión al puerto local** (no por proceso), así que funciona igual con gcloud (gcloud dueño del socket) que con el motor nativo (LCC dueño del socket vía `NativeTunnel`).

## Decisiones

| Decisión | Elección |
|---|---|
| Motor nativo | **Entra** (`iap_tunnel.rs` + enum `Backend`), opt-in, **default gcloud** (como en native-iap-tunnel) |
| `IapTunnel` unificado | `{ backend: Backend{Native,Gcloud}, local_port, last_active }` |
| Reaper | Se porta el de loopback **tal cual** (agnóstico del backend); reapea con `tunnel.stop()` |
| Endurecimiento gcloud | El backend `Gcloud` spawnea vía `crate::gcloud_bin::gcloud_path()` |
| Timeouts | Los de loopback: `IDLE_TIMEOUT = 120s`, `POLL_INTERVAL = 30s` |
| Orden de integración | 1º mergear native-iap-tunnel (resolviendo tunnel.rs al diseño unificado); 2º mergear tabbed-workspace (tunnel.rs ya coincide) |

## Diseño

### 1. `IapTunnel` unificado (`native/src/tunnel.rs`)

```rust
enum Backend {
    Native(crate::iap_tunnel::NativeTunnel),
    Gcloud(std::process::Child),
}

pub struct IapTunnel {
    backend: Backend,
    pub local_port: u16,
    /// Última vez que se observó una conexión loopback activa a `local_port`
    /// (se fija al crear y lo refresca el reaper). Campo del diseño de loopback.
    pub last_active: std::time::Instant,
}

impl IapTunnel {
    pub fn stop(&mut self) -> Result<()> { /* match backend: Native.stop() | process.kill()+wait() */ }
    pub fn is_process_alive(&mut self) -> bool { /* match backend */ }
    pub fn is_port_listening(&self) -> bool { /* connect 127.0.0.1:local_port */ }
}
```

### 2. `start_tunnel` (fusión de ambos flujos)

- Mantener la **selección de motor** de native-iap-tunnel (native opt-in vía su flag/ajuste existente; default gcloud).
- Camino **Gcloud**: spawnear con `crate::gcloud_bin::gcloud_path()?` (endurecimiento), no `Command::new("gcloud")`.
- Ambos caminos construyen `IapTunnel { backend, local_port, last_active: Instant::now() }`.
- Tras insertar en `TUNNELS`: soltar el lock y llamar `start_reaper_once()` (idempotente).
- Conservar una comprobación de salud del puerto antes de declarar éxito (la de loopback: esperar a que `local_port` escuche; abortar y `stop()` si no).

### 3. Reaper (portado de loopback, sin cambios de lógica)

`read_proc_net_tcp`, `port_has_active_connection`, `should_reap`, `reap_idle_tunnels_once`, `start_reaper_once`, `touch_tunnel_by_local_port` se mantienen **igual** que en el Preview. Único ajuste: en `reap_idle_tunnels_once`, reapear con `tunnel.stop()` (que ya despacha a ambos backends) — la detección de actividad y los timeouts no cambian. El reaper aplica por igual a túneles gcloud y nativos.

### 4. Motor nativo

- Traer `native/src/iap_tunnel.rs` (de native-iap-tunnel) e inscribir `pub mod iap_tunnel;` en `native/src/lib.rs`.
- Su API (`TunnelTarget`, `NativeTunnel::{stop,is_running,local_port}`, `start(target)`) se usa desde `Backend::Native`.
- Motor opt-in, default gcloud — se conserva el mecanismo de selección de native-iap-tunnel (no se cambia el default).

## Secuencia de integración (implementación)

1. **Merge `feature/native-iap-tunnel` → `27H1-Preview`**, resolviendo `native/src/tunnel.rs` al `IapTunnel` unificado (Backend + `last_active` + reaper + `gcloud_path`), añadiendo `iap_tunnel.rs` + `pub mod iap_tunnel;`. Regenerar el bridge (si native añade bindings de toggle de motor). `cargo build` debug+release. Verificar reaper (tests) + que compila.
2. **Merge `feature/tabbed-workspace` → `27H1-Preview`**: su `tunnel.rs` ya coincide → sin conflicto de túnel. Resolver los conflictos **mecánicos/UI restantes**: `lib/main.dart` (montar el `GcpSessionBanner` dentro del nuevo dashboard por pestañas), `lib/l10n/app_{en,es}.arb` (combinar ambos juegos de claves) + `flutter gen-l10n`, y el bridge frb (regenerar). `cargo build` + `flutter analyze` + tests + `flutter build linux`.

## Verificación

- **Unit (Rust):** los tests existentes del reaper (`port_has_active_connection` con fixtures v4/v6 ESTABLISHED/LISTEN/ausente; `should_reap`) siguen pasando. **Añadir**: un test de que `reap_idle_tunnels_once` reapea un `IapTunnel` con `Backend::Native` inactivo (o al menos que `should_reap` + `stop()` sobre un backend nativo simulado no rompe). `cargo test`.
- **Compilación:** `cargo build` **y** `cargo build --release` (la app carga `native/target/release/libnative.so`).
- **Dart:** `flutter gen-l10n` (paridad EN/ES tras combinar claves), `flutter analyze` (0 errores), `flutter test`, `flutter build linux --debug`.
- **Manual (QA):** con motor **gcloud** (default) abrir un túnel, dejarlo sin conexión → reapea en ≤150s; sesión viva → no se reapea. Repetir con el motor **nativo** activado (opt-in): túnel nativo inactivo reapea; sesión nativa viva no. La app arranca y el workspace por pestañas funciona.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `tunnel.stop()` sobre un `NativeTunnel` no cierra limpio su listener/hilos → fuga | Verificar en QA que reapear un túnel nativo libera el puerto (no queda LISTEN); revisar `NativeTunnel::stop()` |
| El reaper detecta actividad por `/proc/net/tcp`; ¿el socket del motor nativo aparece igual? | El motor nativo bindea un `TcpListener` loopback; una conexión de cliente crea una fila ESTABLISHED igual que con gcloud → mismo mecanismo. Confirmar en QA |
| Regenerar el bridge arrastra cambios inesperados | `git diff --stat lib/src/bridge/` tras regen; revisar que solo entran las bindings de native + las ya existentes |
| Conflicto de `main.dart` (dashboard por pestañas vs banner) mal resuelto | El banner va **encima** del contenido del workspace (mismo patrón `Column[banner, Expanded(child: <workspace>)]`); verificar que renderiza y no rompe las pestañas |

## Fuera de alcance

- El resto de `feature/tabbed-workspace` que no toca el túnel (workspace, terminal, SFTP dual-pane, tab strip) entra tal cual en el merge del paso 2; su lógica ya fue revisada en su rama.
- `feature/sftp-parallel-transfers` sigue separada (decisión previa).
- Cambiar el default de motor (sigue gcloud) o rediseñar el motor nativo.
