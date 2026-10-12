# Diseño: SG-B — túnel IAP directo nativo por defecto (salida de gcloud, fase 2)

**Fecha:** 2026-08-12
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Cambio Rust interno (sin regen del bridge). Segundo sub-proyecto de la salida de `gcloud` — ver `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Objetivo

Hacer que el **túnel IAP directo** use el motor **nativo por defecto**, con `gcloud` como opt-out explícito (`LCC_TUNNEL_ENGINE=gcloud`). Retira `gcloud compute start-iap-tunnel` de la ruta por defecto del túnel directo, encogiendo la superficie de gcloud sin tocar auth. El **SSH forward** se deja en gcloud por defecto (fase posterior).

## Contexto (estado real verificado)

- Dos selectores independientes en `native/src/tunnel.rs`, ambos con **default = gcloud** hoy:
  - **Túnel IAP directo:** `selected_engine()` (`LCC_TUNNEL_ENGINE`) → `None`/`gcloud` = gcloud; `native` = opt-in. Usado en `start()` (líneas ~174-198).
  - **SSH forward (`-L`):** `ssh_forward_engine()` (`LCC_SSH_FORWARD_ENGINE`) → `None`/`gcloud` = gcloud; `native` = opt-in. Usado en `start_ssh_forward()` (~339-348).
- `selected_engine` **solo se usa dentro de `tunnel.rs`** (en `start()` y en 4 asserts de test 766-777); **sin referencias** en `api.rs` ni `lib/src` → renombrar/reemplazar es interno, sin impacto en el bridge.
- El motor nativo del túnel directo es `crate::iap_tunnel` (el más maduro). El nativo del SSH forward es `crate::ssh_forward` (reactor ssh2, más reciente).
- Los tests de motor actuales (`engine_defaults_to_none_when_unset`, `engine_can_be_forced`, ~763-778) **mutan `LCC_TUNNEL_ENGINE` a nivel de proceso** (llevan una nota "DEVIATION from brief" por ello) → frágiles.
- El nativo hoy corre "sin fallback para que los fallos sean visibles en debug" (comentario en `start()`).
- El error de túnel ya se propaga con `errorCode` estable y se localiza en la capa Dart (`TunnelFailure`/`localizedError`).

## Decisiones

| Decisión | Elección |
|---|---|
| Alcance | **Solo el túnel IAP directo** pasa a nativo-por-defecto. SSH forward sin cambios (gcloud default) → fase posterior. |
| Fallo del nativo | **Sin fallback**: el fallo se propaga como error de túnel (localizado). `LCC_TUNNEL_ENGINE=gcloud` es la escotilla de opt-out. |
| Resolución del motor | Refactor a helper puro `parse_tunnel_engine(Option<&str>) -> TunnelEngine` con **Native como default**; wrapper `tunnel_engine()`. Reemplaza a `selected_engine()`. |
| gcloud | Se conserva `Backend::Gcloud` + `start_gcloud` (alcanzables por opt-out). Su borrado → **SG-E**. |
| Tests | Sustituir los tests env-based por tests **puros** de `parse_tunnel_engine`. |
| Bridge / auth / SSH forward | Sin cambios. |

## Diseño

### 1. Invertir la resolución del motor (helper puro + wrapper)

En `native/src/tunnel.rs`, reemplazar `selected_engine()` (que devuelve `Option<TunnelEngine>` con `None` = gcloud) por:

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
(Espeja `parse_ssh_forward_engine`/`ssh_forward_engine`, que se dejan intactos.)

### 2. `start()`: nativo por defecto, gcloud solo por opt-out

En `start()` (~174-198), sustituir:
```rust
let forced = selected_engine();
// gcloud is the default engine (reliable). The native engine is still
// experimental and only runs when explicitly opted in via LCC_TUNNEL_ENGINE=native ...
if forced == Some(TunnelEngine::Native) {
    // ...native...
}
// ...gcloud (default)...
```
por:
```rust
// Native is the default IAP-tunnel engine. `gcloud compute start-iap-tunnel`
// is reachable only as an explicit opt-out via LCC_TUNNEL_ENGINE=gcloud. A
// native failure surfaces as a tunnel error (no silent fallback).
if tunnel_engine() == TunnelEngine::Native {
    // ...native... (bloque existente sin cambios)
}
// ...gcloud (opt-out)... (bloque existente sin cambios)
```
Los cuerpos native/gcloud (inserción en `TUNNELS`, `start_reaper_once`, `tracing::info!`) no cambian; solo cambia la condición y el comentario.

### 3. Tests: puros en vez de env-based

Sustituir `engine_defaults_to_none_when_unset` y `engine_can_be_forced` (~763-778, que mutan env) por tests puros sobre `parse_tunnel_engine`:

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
(`TunnelEngine` ya deriva `PartialEq, Eq`.) Esto elimina la mutación de env global y su nota "DEVIATION".

## Errores

El fallo del motor nativo se propaga tal cual (mismo camino de error que hoy tiene el nativo opt-in): error de túnel con su `errorCode`, localizado en Dart. Sin reintento silencioso con gcloud. Para revertir a gcloud puntualmente: `LCC_TUNNEL_ENGINE=gcloud`.

## Testing

- **`cargo test`** (en `native/`): los nuevos tests puros de `parse_tunnel_engine` pasan; el resto de la suite Rust sigue verde.
- **`cargo build --release`** compila.
- Establecer un túnel real no es unit-testeable → **checklist de QA manual** (nuevo doc): con el default (sin env) verificar por el motor **nativo** — RDP, VNC, SSH embebido, SFTP, Custom Tunnel (modo directo), reconexión y reuso de puerto; y comprobar que `LCC_TUNNEL_ENGINE=gcloud` sigue funcionando (opt-out). El SSH forward (`-L`) sigue por gcloud (sin cambios).
- La suite Flutter no se ve afectada; sigue verde.

## Alcance / fuera de alcance

- **Dentro:** `parse_tunnel_engine`/`tunnel_engine` con Native default; `start()` invierte la condición + comentario; sustituir los tests env-based por puros; checklist de QA manual. Solo `native/src/tunnel.rs` (+ doc).
- **Fuera:** SSH forward nativo por defecto (fase posterior); borrar `Backend::Gcloud`/`start_gcloud`/`spawn_ssh_forward` (SG-E); auth/token (SG-C/D); datos/lifecycle (SG-A, hecho); regen del bridge; exponer el selector en Settings.

## Verificación

- `cargo test` (incl. los tests puros nuevos) y `cargo build --release` verdes; `flutter test` (suite) verde.
- Con env sin fijar, el túnel IAP directo se establece por el motor **nativo** (verificable en logs: `engine = "native"`); con `LCC_TUNNEL_ENGINE=gcloud`, por gcloud.
- Checklist de QA manual creado.
