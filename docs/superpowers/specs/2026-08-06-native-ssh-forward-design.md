# Diseño: Reenvío SSH nativo (ssh2), opt-in

**Fecha:** 2026-08-06
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Feature (Rust-only; sin bridge/Dart). Opt-in vía env, default = gcloud.

## Objetivo

El reenvío de puertos por SSH usa hoy `gcloud compute ssh <vm> --tunnel-through-iap -- -L <local>:localhost:<remote> -N` (proceso gcloud gestionado en `spawn_ssh_forward`/`start_ssh_forward`, `native/src/tunnel.rs`). Este trabajo añade un motor **nativo con ssh2/libssh2** — túnel IAP nativo a `:22` + sesión ssh2 + reenvío local `channel_direct_tcpip` — para quitar la dependencia de gcloud en el reenvío. Es **opt-in** (`LCC_SSH_FORWARD_ENGINE=native`); gcloud sigue por defecto hasta probarlo.

## Contexto

- **Reenvío gcloud actual:** `start_ssh_forward(project, zone, instance, remote_port, local_port: Option<u16>) -> Result<u16>` (`tunnel.rs`) deduplica por `sshfwd:instance:remote`, llama `spawn_ssh_forward` (lanza el `gcloud compute ssh … -L`), registra un `IapTunnel` en `TUNNELS` y confía en el reaper de inactividad. El puerto local elegible (`Option<u16>`) ya existe.
- **Core ssh2 reutilizable:** `sftp.rs::create_ssh_session(host, port, username) -> Result<Session>` (`:317`): `TcpStream::connect` a `localhost:<puerto IAP>`, `Session::new`, `handshake`, `userauth_agent(username)` con fallback a `userauth_pubkey_file` sobre `~/.ssh/{id_ed25519,id_ecdsa,id_rsa}`. **Asume la clave ya aceptada** (no auto-provisiona como gcloud).
- **Motor IAP nativo:** `iap_tunnel::start(target: TunnelTarget, local_port: Option<u16>) -> Result<NativeTunnel, TunnelError>` (`iap_tunnel/listener.rs`); `NativeTunnel { pub local_port: u16, stop(&self), is_running(&self) }`.
- **Username en Rust:** `crate::sftp::get_current_username() -> Result<String>` (`sftp.rs:1135`, lee `USER`/`USERNAME`) — el forward nativo lo obtiene aquí, sin bridge.
- **Stack de túneles:** `Backend { Native(NativeTunnel), Gcloud(Child) }`; `IapTunnel { backend, local_port, last_active }` con `stop()`/`is_process_alive()`/`is_port_listening()` (por `local_port`)/`is_healthy()`. Reaper agnóstico de backend (detecta inactividad por conexión ESTABLISHED al `local_port`). Patrón de flag: `selected_engine()` lee `LCC_TUNNEL_ENGINE`.
- **Helper del puerto local:** `ensure_local_port_available(port)` + `get_free_port()` (`tunnel.rs`).

## Decisiones

| Decisión | Elección |
|---|---|
| Activación | Env `LCC_SSH_FORWARD_ENGINE=native` (default = gcloud), espejo de `selected_engine()` |
| Transporte IAP a :22 | **Motor nativo** `iap_tunnel::start(:22)` → **100% sin gcloud** en el reenvío |
| Auth | Reusar `create_ssh_session` (extraído a helper compartido); agente/`~/.ssh` keys; **no auto-provisiona** |
| Reenvío | `TcpListener` local + hilo-reactor no-bloqueante por forward: `channel_direct_tcpip("localhost", remote_port)` por conexión + bombeo |
| Concurrencia | Un hilo posee la `Session` (no-bloqueante); reactor de un solo hilo sobre listener + socket SSH + sockets locales (libssh2 no es thread-safe para canales concurrentes) |
| Integración | Nueva variante `Backend::NativeSshForward(NativeSshForward)`; registrado bajo la clave `sshfwd:instance:remote` existente → stop/reaper/manager sin cambios |
| Puerto local | El `Option<u16>` elegible aplica **al listener del forward**; P22 (IAP) es interno/auto |
| Bridge/Dart | **Sin cambios** (flag por env; username en Rust). Rust-only |

## Diseño

### 1. Flag y despacho (`tunnel.rs`)

```rust
pub fn ssh_forward_engine() -> Option<TunnelEngine> {
    match std::env::var("LCC_SSH_FORWARD_ENGINE").ok()?.as_str() {
        "native" => Some(TunnelEngine::Native),
        "gcloud" => Some(TunnelEngine::Gcloud),
        _ => None,
    }
}
```

En `start_ssh_forward`, tras la dedup y antes de `spawn_ssh_forward`, despachar:

```rust
let tunnel = if ssh_forward_engine() == Some(TunnelEngine::Native) {
    let f = crate::ssh_forward::start(project, zone, instance, remote_port, local_port)?;
    IapTunnel { local_port: f.local_port(), backend: Backend::NativeSshForward(f), last_active: Instant::now() }
} else {
    spawn_ssh_forward(project, zone, instance, remote_port, local_port)?
};
```
(el resto de `start_ssh_forward` —inserción en `TUNNELS`, reaper, log— sin cambios).

### 2. Helper de sesión compartido (`ssh_session.rs`, nuevo)

Mover `create_ssh_session(host, port, username)` de `sftp.rs` a `native/src/ssh_session.rs` como `pub(crate) fn create_ssh_session(...) -> Result<ssh2::Session>` (cuerpo idéntico). `sftp.rs` pasa a `use crate::ssh_session::create_ssh_session;` (sus ~9 call-sites intactos). `lib.rs` añade `mod ssh_session;`.

### 3. Módulo del forward nativo (`ssh_forward.rs`, nuevo)

```rust
pub struct NativeSshForward {
    local_port: u16,
    shutdown: std::sync::Arc<std::sync::atomic::AtomicBool>,
    reactor: Option<std::thread::JoinHandle<()>>,
    iap: crate::iap_tunnel::NativeTunnel, // transporte IAP a :22
}

impl NativeSshForward {
    pub fn local_port(&self) -> u16 { self.local_port }
    pub fn is_running(&self) -> bool {
        !self.shutdown.load(std::sync::atomic::Ordering::Relaxed)
            && self.reactor.as_ref().map(|h| !h.is_finished()).unwrap_or(false)
    }
    pub fn stop(&mut self) -> Result<()> {
        self.shutdown.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(h) = self.reactor.take() { let _ = h.join(); }
        self.iap.stop();
        Ok(())
    }
}

pub fn start(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<NativeSshForward>
```
`start`:
1. `username = crate::sftp::get_current_username()?`.
2. `iap = crate::logging::block_on(crate::iap_tunnel::start(TunnelTarget::new(project, zone, instance, 22), None)).map_err(anyhow::Error::new)?;` → `p22 = iap.local_port`.
3. Sesión: `sess = crate::ssh_session::create_ssh_session("127.0.0.1", p22, &username)?`; luego `sess.set_blocking(false)`.
4. Listener local: `let bind_port = match local_port { Some(p) => { ensure_local_port_available(p)?; p } None => get_free_port()? };` (reusar los helpers de `tunnel.rs`, expuestos `pub(crate)`); `TcpListener::bind(("127.0.0.1", bind_port))?` en no-bloqueante.
5. Lanzar el hilo-reactor (posee `sess` + listener + `remote_port` + `shutdown`); devolver `NativeSshForward`.

### 4. El reactor (hilo dedicado, no-bloqueante)

Bucle mientras `!shutdown`:
- `accept()` no-bloqueante del listener → por cada conexión nueva: `sess.channel_direct_tcpip("localhost", remote_port, None)`, socket en no-bloqueante, registrar `(socket, channel, buffers)` en la tabla de conexiones activas.
- Por cada conexión activa: bombeo bidireccional no-bloqueante (`socket -> channel.write`, `channel.read -> socket`), manejando `WouldBlock` (continuar) y EOF/close (cerrar esa conexión: `channel.send_eof()`/`close()`, drop del socket).
- Mecanismo de readiness: no-bloqueante con **poll acotado** (round-robin con intervalo corto, sin dependencia nueva; ver Riesgos para la alternativa `polling`/`mio`).
- Al salir (`shutdown`): cerrar todos los canales + el listener; el `stop()` del handle hace el resto (join + `iap.stop()`).

libssh2 multiplexa todos los canales sobre el único socket TCP a `p22`; por eso la `Session` la posee **un solo hilo** y todo el I/O de canales ocurre en ese hilo.

### 5. Integración con `Backend`/`IapTunnel` (`tunnel.rs`)

- `enum Backend { Native(..), Gcloud(..), NativeSshForward(crate::ssh_forward::NativeSshForward) }`.
- `IapTunnel::stop()`: brazo `Backend::NativeSshForward(f) => { let _ = f.stop(); }`.
- `IapTunnel::is_process_alive()`: brazo `Backend::NativeSshForward(f) => f.is_running()`.
- `is_port_listening()` (por `local_port`) e `is_healthy()` funcionan sin cambios (el listener del forward escucha en `local_port`).
- `lib.rs` añade `mod ssh_forward;`. `ensure_local_port_available`/`get_free_port` pasan a `pub(crate)`.

## Auth y limitaciones

Igual que SFTP: agente SSH → `~/.ssh/{id_ed25519,id_ecdsa,id_rsa}`. **No auto-provisiona** la clave en la VM (a diferencia de `gcloud compute ssh`); requiere que la clave ya esté aceptada (OS Login / `authorized_keys`). Dado que el SFTP nativo del usuario funciona, su clave ya está aceptada. Se documenta en la ayuda del flag.

## Testing

- **Unit:** `ssh_forward_engine()` (parseo de env → `Native`/`Gcloud`/`None`, puro, como el test de `selected_engine`). Que `create_ssh_session` extraído sigue compilando y en uso desde `sftp.rs`.
- **Integración/manual (el reactor):** requiere un servidor SSH real → **QA manual** con `LCC_SSH_FORWARD_ENGINE=native`: forward a un servicio de la VM, verificar que fluyen los datos, múltiples conexiones, apagado limpio (stop libera el puerto), y que el reaper lo recoge por inactividad. Consistente con cómo se prueba el motor IAP nativo (mayormente integración).

## Alcance / fuera de alcance

- **Dentro:** flag + despacho, helper `create_ssh_session` compartido, módulo `ssh_forward` (start + reactor + handle), variante `Backend::NativeSshForward`, transporte IAP nativo a :22, puerto local elegible aplicado al listener.
- **Fuera:** UI/selector en el diálogo (opt-in por env); auto-provisión de claves (metadata/OS Login); cambiar el default a nativo (queda gcloud hasta probar); reenvío nativo para el modo Directo (solo aplica al reenvío SSH); reactor basado en `polling`/`mio` (optimización futura).

## Verificación

- `cd native && cargo test` (test del flag + suite existente) y `cargo build` + `cargo build --release`.
- Sin regen de bridge, sin cambios en `lib/`.
- QA manual con `LCC_SSH_FORWARD_ENGINE=native` (arriba).

## Riesgos

- **El reactor no-bloqueante** con libssh2 (multiplexar canales en una sesión, `WouldBlock`, cierre por conexión) es la parte más delicada — motivo del opt-in y del default gcloud. Alternativa de readiness más eficiente: crate `polling` o `mio` (dependencia nueva) en vez del round-robin acotado; se deja como refinamiento futuro salvo que el QA muestre latencia/CPU inaceptable.
- **Doble dependencia experimental:** el forward nativo se apoya en el motor IAP nativo (`iap_tunnel`), también experimental. El opt-in lo asume.
