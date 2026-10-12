# Diseño: Elegir el puerto local (Custom Tunnel — Directo IAP + Reenvío SSH)

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature (Dart + Rust + regen de bridge). Iteración sobre el diálogo Custom Tunnel (sub-proyectos A/B de Custom Tunnel ya hechos).

## Objetivo

Hoy el puerto **local** de un túnel Custom siempre se auto-asigna (`get_free_port()` en Rust / bind a `127.0.0.1:0`). El usuario ya elige el puerto **remoto** del servicio; pidió poder fijar también el **puerto local**. Este trabajo añade un campo opcional "Puerto local" al diálogo Custom Tunnel que aplica a **ambos** modos (Directo IAP y Reenvío SSH); vacío = auto (comportamiento actual).

## Contexto

- **Flujo Directo (IAP):** diálogo → `ConnectionsNotifier.connect(...)` → bridge `startConnection` → `api::start_connection` → `tunnel::start_tunnel(project, zone, instance, remote_port)` → despacha a `start_gcloud` (default) o `start_native` (opt-in `LCC_TUNNEL_ENGINE=native`). Ambos backends acaban en un puerto local: `start_gcloud` llama `get_free_port()` y pasa `--local-host-port=localhost:{port}`; `start_native` → `iap_tunnel::start(target)` → `bind_local_port()` (`TcpListener::bind("127.0.0.1:0")`).
- **Flujo Reenvío SSH:** diálogo → `connectSshForward(...)` → bridge `startSshForward` → `api::start_ssh_forward` → `tunnel::start_ssh_forward(...)` → `spawn_ssh_forward(...)` → `get_free_port()` + `ssh_forward_args(instance, zone, project, local, remote)`.
- **Dedup:** ambos flujos dedup­lican por `instance:remote` (`make_tunnel_key` / `make_ssh_forward_key`) y devuelven el `local_port` existente si ya hay túnel.
- **Ya existe** `TunnelError::LocalPortUnavailable` en `iap_tunnel/error.rs` (código `"local_port_unavailable"`), mapeado a `TunnelFailure` por el downcast de `start_connection` — así que el motor nativo ya modela este error.
- **Diálogo** (`overview_tab.dart::_showCustomTunnelDialog`): devuelve `({int port, bool sshForward})?` (`port` = remoto). El puerto remoto se elige con chips de preset o un `TextField` custom (validado 1–65535). En modo SSH forward hoy solo se muestra un hint. El fallo se muestra en `_showCustomTunnelError` (con `localizedError` + detalle crudo + botón Doctor).
- **`connect(...)`** se usa desde muchos sitios (terminal SSH, SFTP, etc.) con `remotePort:22` y sin puerto local → el nuevo parámetro debe ser **opcional** (default = auto) para no romper esos llamadores.

## Decisiones

| Decisión | Elección |
|---|---|
| Alcance | Puerto local elegible en **ambos** modos (Directo IAP + Reenvío SSH) |
| Señal "auto" | `local_port: Option<u16>` en Rust / `int? localPort` en Dart; `None`/`null` = auto (`get_free_port` / bind :0) |
| UI | Campo **"Puerto local (opcional)"** siempre visible en el diálogo (aplica al modo activo); vacío = auto |
| Rango UI | **1–65535** (sin restringir a ≥1024); un puerto privilegiado/ocupado da error limpio del pre-bind |
| Error "no disponible" | Rutas gcloud: helper `ensure_local_port_available(p)` (pre-bind) → error limpio. Ruta nativa: `bind_local_port(Some(p))` → `TunnelError::LocalPortUnavailable` |
| Dedup | Sin cambio (`instance:remote`); si ya existe túnel se devuelve su local real (mostrado en el mensaje de éxito) |
| Reconexión | **Fuera de alcance**: el auto-reconnect del Directo sigue auto-asignando (pasa `null`); preservar el puerto elegido tras reaper = trabajo futuro |
| Bridge | `start_connection` y `start_ssh_forward` ganan `local_port: Option<u16>` → **regen** |

## Diseño

### 1. UX — campo "Puerto local" en el diálogo (`overview_tab.dart`)

- Nuevo `TextEditingController localPortController` + estado `int? localPort` en `_showCustomTunnelDialog`, dispuesto en `finally` como el existente `customPortController`.
- Un `TextField` **"Puerto local (opcional)"** (nueva clave i18n `customTunnelLocalPortLabel` + hint `customTunnelLocalPortHint` "Vacío = automático"), colocado tras la selección de puerto remoto, **visible en ambos modos**. `onChanged`: `int.tryParse`; si vacío → `localPort = null` (auto, válido); si numérico en 1–65535 → `localPort = p`; si no vacío e inválido → marcar error inline y bloquear Connect.
- Estado de validez: el botón **Connect** se habilita cuando el puerto remoto está elegido **y** el campo de puerto local es válido-o-vacío.
- El record devuelto pasa a **`({int port, bool sshForward, int? localPort})?`**; el `Navigator.pop` de Connect devuelve `(port: selectedPort!, sshForward: sshForward, localPort: localPort)`.

### 2. Dart provider (`gcloud_provider.dart`)

- `connect(...)` (L847) y su interno `_connect(...)` (L879) ganan `int? localPort` (opcional, default `null`); se pasa a `startConnection(..., localPort: localPort)` (L895). Los demás llamadores de `connect` (terminal/SFTP) no lo pasan → `null` = auto (sin cambio).
- El **path de auto-reconnect** que llama `startConnection` (≈L691) pasa `localPort: null` (auto) — fuera de alcance preservarlo.
- `connectSshForward(...)` (L950) y su interno `_connectSshForward(...)` (L970) ganan `int? localPort`, pasado a `startSshForward(..., localPort: localPort)` (L974). La clave single-flight sigue en `instance:remote`.
- El handler del diálogo (`overview_tab.dart` ≈L476-517) enruta: modo Directo → `connect(..., localPort: choice.localPort)`; modo SSH → `connectSshForward(..., localPort: choice.localPort)`.

### 3. Bridge (`api.rs`, regen)

- `pub fn start_connection(project_id, zone, instance_name, remote_port: u16, local_port: Option<u16>) -> Result<u16, TunnelFailure>` → `start_tunnel(&project_id, &zone, &instance_name, remote_port, local_port)`.
- `pub fn start_ssh_forward(project_id, zone, instance_name, remote_port: u16, local_port: Option<u16>) -> Result<u16, TunnelFailure>` → `start_ssh_forward(&project_id, &zone, &instance_name, remote_port, local_port)`.
- Regen del bridge (`flutter_rust_bridge_codegen generate`) → los Dart `startConnection`/`startSshForward` ganan `int? localPort`.

### 4. Rust — rutas gcloud (`tunnel.rs`)

- `start_tunnel(project, zone, instance, remote_port, local_port: Option<u16>)`: pasa `local_port` a `start_gcloud`/`start_native`. Dedup sin cambio.
- `start_gcloud(project, zone, instance, remote_port, local_port: Option<u16>)`: reemplaza `let port = get_free_port()?;` por
  ```rust
  let port = match local_port {
      Some(p) => { ensure_local_port_available(p)?; p }
      None => get_free_port()?,
  };
  ```
- `start_ssh_forward(project, zone, instance, remote_port, local_port: Option<u16>)` → `spawn_ssh_forward(project, zone, instance, remote_port, local_port)`; en `spawn_ssh_forward` el mismo `match` para `let local = ...`.
- Nuevo helper:
  ```rust
  /// Pre-bind a specific local port to fail fast with a clean message when it
  /// is occupied or privileged, before spawning gcloud. Same brief TOCTOU
  /// window as get_free_port (bind, drop, then the child rebinds).
  fn ensure_local_port_available(port: u16) -> Result<()> {
      match TcpListener::bind(("127.0.0.1", port)) {
          Ok(_) => Ok(()),
          Err(e) => Err(anyhow!("Local port {} is not available: {}", port, e)),
      }
  }
  ```

### 5. Rust — ruta nativa (`iap_tunnel/listener.rs`)

- `pub async fn start(target: TunnelTarget, local_port: Option<u16>) -> Result<NativeTunnel, TunnelError>` pasa `local_port` a `bind_local_port`.
- `async fn bind_local_port(local_port: Option<u16>) -> Result<TcpListener, TunnelError>` (la variante ya es `TunnelError::LocalPortUnavailable { port: u16 }`):
  ```rust
  let requested = local_port.unwrap_or(0);
  TcpListener::bind(("127.0.0.1", requested))
      .await
      .map_err(|_| TunnelError::LocalPortUnavailable { port: requested })
  ```
  `start(target, local_port)` llama `bind_local_port(local_port).await?`; `start_without_probe` (solo test) pasa `bind_local_port(None)`.
- `tunnel.rs::start_native(project, zone, instance, remote_port, local_port)` → `iap_tunnel::start(target, local_port)`.

### 6. Errores / UX de fallo

El error de puerto no disponible cruza el bridge como `TunnelFailure` (ruta gcloud: `protocol_error` + detalle "Local port N is not available: …"; ruta nativa: `local_port_unavailable`) y se muestra en el `_showCustomTunnelError` existente (`localizedError` + detalle crudo + Doctor). En modo SSH forward se sigue suprimiendo la pista de localhost.

## Testing

- **Rust (`tunnel.rs` tests):** `ensure_local_port_available` — mantener un `TcpListener` sobre un puerto y aserta `Err`; sobre un puerto libre aserta `Ok`.
- **Rust (`iap_tunnel/listener.rs` tests):** con el harness existente, `bind_local_port(Some(p))` sobre un puerto ocupado → `TunnelError::LocalPortUnavailable`; `bind_local_port(None)` → bind a un puerto > 0 (comportamiento actual, no regresión). El test existente `start_binds_a_local_port_immediately` se adapta a la nueva firma (`start(target, None)`).
- **`ssh_forward_args`:** sin cambios (ya recibe `local`); su test se mantiene.
- **Dart:** helper puro de validación del campo si se extrae (p.ej. `parseLocalPort(String) -> int?` con reglas vacío/rango) + su test; el diálogo en sí se cubre por QA manual.

## Alcance / fuera de alcance

- **Dentro:** campo opcional de puerto local en el diálogo (ambos modos), enhebrado `Option<u16>` por las tres rutas, pre-bind/errores limpios, regen de bridge, 2 claves i18n, tests de Rust.
- **Fuera:** preservar el puerto elegido en el **auto-reconnect** (pasa auto); elegir el puerto local desde otros lanzadores (terminal SSH/SFTP usan `:22` auto); cambiar el modelo de dedup (`instance:remote`); migración del reenvío SSH a `ssh2` nativo (trabajo futuro aparte).

## Verificación

- `cd native && cargo test` (nuevos tests + suite existente).
- Regen del bridge; `flutter analyze` (sin issues nuevas sobre el baseline ~85) y `flutter test`.
- `cargo build && cargo build --release` (la app carga `native/target/release/libnative.so`).
- QA manual: elegir un puerto local en Directo y en SSH forward; puerto ocupado → error claro; campo vacío → auto (comportamiento actual).
