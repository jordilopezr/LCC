# SG-E — Cierre: Doctor nativo, motores visibles y documentación honesta

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cerrar la salida de gcloud: Doctor gana tres comprobaciones de la auth nativa, los tres selectores de motor comparten un mecanismo y dos de ellos se hacen visibles, y la documentación deja de describir una aplicación que ya no existe.

**Architecture:** `engine_pref.rs` pasa de una clave a tres en el mismo `engine.json`, con una precedencia única (entorno > fichero > nativo) y sin cachear nada. Doctor añade tres filas nativas, simétricas a las de gcloud que D5 dejó en `Skipped`. Los seis remedios de administración conservan su comando y ganan la ruta de la consola.

**Tech Stack:** Rust (anyhow, serde, keyring, tracing), Flutter/Dart (Riverpod, flutter_rust_bridge 2.11.1), l10n con ficheros `.arb`.

**Spec:** [docs/superpowers/specs/2026-08-25-sge-cleanup-design.md](../specs/2026-08-25-sge-cleanup-design.md)

## Global Constraints

- **Nunca** `#[allow(dead_code)]` ni ningún otro silenciado de lint, en Rust o en Dart. Lo que no se usa se cablea o se borra.
- `cargo build --lib` con **cero warnings**; `cargo test --lib` en verde.
- `flutter analyze` con **cero líneas `error •`** (las ~89 de nivel info/warning son preexistentes); `flutter test` → `All tests passed!`.
- **NO ejecutar `dart format`.**
- Los commits de **código** no llevan trailer `Co-Authored-By`. Los de **documentación** sí pueden.
- **Paridad i18n obligatoria:** toda clave nueva existe en `lib/l10n/app_en.arb` **y** en `lib/l10n/app_es.arb`; después, `flutter gen-l10n`.
- Ningún secreto (token de acceso, refresh token, `client_secret`, clave privada) puede llegar a una línea de log ni a un mensaje de error. Rutas sí; contenidos no.
- **Toda** llamada a `crate::token_store` pasa por `crate::oauth::store_call` (usa `spawn_blocking`): zbus revienta si se le llama desde un worker de tokio.
- Todo `setState` y todo uso de `context` que siga a un `await` va con guarda `mounted` / `context.mounted`.
- **La prueba negativa:** cada comprobación nativa nueva necesita una guarda que **falle** si se reintroduce el defecto que detecta. Un test que pasa con y sin el fallo no es un test.

## Mapa de ficheros

| Fichero | Responsabilidad tras SG-E |
|---|---|
| `native/src/engine_pref.rs` | Dueño de `engine.json`. Tres ranuras, una precedencia, lectura sin caché |
| `native/src/tunnel.rs` | Deja de leer variables de entorno por su cuenta; pregunta a `engine_pref` |
| `native/src/token_store.rs` | Añade dos consultas de diagnóstico que **no** reparan nada |
| `native/src/doctor.rs` | Tres filas nativas; los remedios de administración ganan ruta de consola |
| `native/src/api.rs` | Los cuatro envoltorios del motor pasan a estar parametrizados por ranura |
| `lib/src/features/settings_dialog.dart` | Un widget de selector reutilizable, usado tres veces; los dos nuevos, plegados |
| `README.md`, `README.es.md` | gcloud como opcional, no como requisito |

---

### Task 1: `engine_pref` con tres ranuras

**Files:**
- Modify: `native/src/engine_pref.rs`
- Modify: `native/src/oauth.rs:39`

**Interfaces:**
- Produces, para las tareas 2 y 3: `engine_pref::Engine` (`Native` | `Gcloud`), `engine_pref::EngineSlot` (`Auth` | `Tunnel` | `SshForward`), `engine_pref::engine_for(EngineSlot) -> Engine`, `engine_pref::stored(EngineSlot) -> Option<String>`, `engine_pref::set_stored(EngineSlot, &str) -> Result<()>`, `engine_pref::env_override(EngineSlot) -> Option<Engine>`, `EngineSlot::from_key(&str) -> Option<EngineSlot>` y `EngineSlot::key(self) -> &'static str`.

**Contexto que necesitas:** hoy `engine_pref` solo conoce el motor de auth y `set_stored_engine` **reescribe el fichero entero** con una sola clave. Generalizarlo sin más borraría las otras dos en cuanto alguien cambiase una: la escritura tiene que ser leer-modificar-escribir.

`AuthEngine` (en `oauth.rs`) y `TunnelEngine` (en `tunnel.rs`) son dos enums distintos con la misma forma. Se introduce un `Engine` neutro en `engine_pref` y cada uno recibe un `From`, en vez de que el motor de túnel dependa del tipo del de auth.

- [ ] **Step 1: Escribe los tests que fallan**

Reemplaza el `mod tests` de `native/src/engine_pref.rs` por este (los cinco tests existentes siguen, adaptados al tipo neutro, y se añaden los tres nuevos):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// El cutover: sin nada configurado, el motor es el nativo.
    #[test]
    fn the_default_is_native() {
        assert_eq!(resolve(None, None), Engine::Native);
    }

    #[test]
    fn the_stored_preference_is_honoured() {
        assert_eq!(resolve(None, Some("gcloud")), Engine::Gcloud);
        assert_eq!(resolve(None, Some("native")), Engine::Native);
    }

    /// El env gana SIEMPRE. Es la escotilla de diagnóstico, y el QA en entorno
    /// hostil lanza la app con esa variable: si el fichero pudiera ganarle, ese
    /// QA dejaría de poder forzar el motor y probaría otra cosa de la que cree.
    #[test]
    fn the_environment_overrides_the_stored_preference() {
        assert_eq!(resolve(Some("native"), Some("gcloud")), Engine::Native);
        assert_eq!(resolve(Some("gcloud"), Some("native")), Engine::Gcloud);
    }

    #[test]
    fn only_a_recognised_value_counts_as_an_override() {
        assert_eq!(parse_engine("native"), Some(Engine::Native));
        assert_eq!(parse_engine("gcloud"), Some(Engine::Gcloud));
        assert_eq!(parse_engine("wat"), None);
        assert_eq!(parse_engine(""), None);
    }

    #[test]
    fn rubbish_falls_through_instead_of_deciding() {
        assert_eq!(resolve(Some("wat"), Some("gcloud")), Engine::Gcloud);
        assert_eq!(resolve(None, Some("wat")), Engine::Native);
        assert_eq!(resolve(Some("wat"), None), Engine::Native);
    }

    /// Compatibilidad hacia atrás: D5 escribió ficheros con UNA sola clave en
    /// máquinas reales. Si al añadir claves dejan de leerse, esos usuarios
    /// vuelven al motor por defecto sin que nadie se entere.
    #[test]
    fn a_file_written_by_d5_still_names_the_auth_engine() {
        let prefs: EnginePrefs = serde_json::from_str(r#"{"auth_engine":"gcloud"}"#).unwrap();
        assert_eq!(EngineSlot::Auth.get(&prefs), Some("gcloud"));
        assert_eq!(EngineSlot::Tunnel.get(&prefs), None);
        assert_eq!(EngineSlot::SshForward.get(&prefs), None);
    }

    /// Escribir una ranura no puede borrar las otras dos. `set_stored`
    /// reescribe el fichero entero, así que sin leer-modificar-escribir un
    /// cambio en Ajustes se llevaría por delante las otras dos preferencias.
    #[test]
    fn writing_one_slot_leaves_the_others_alone() {
        let mut prefs: EnginePrefs =
            serde_json::from_str(r#"{"auth_engine":"gcloud","tunnel_engine":"gcloud"}"#).unwrap();
        EngineSlot::SshForward.set(&mut prefs, "native");
        assert_eq!(EngineSlot::Auth.get(&prefs), Some("gcloud"));
        assert_eq!(EngineSlot::Tunnel.get(&prefs), Some("gcloud"));
        assert_eq!(EngineSlot::SshForward.get(&prefs), Some("native"));
    }

    /// Las tres ranuras tienen variable propia: si dos compartieran nombre,
    /// forzar una en el QA movería la otra en silencio.
    #[test]
    fn every_slot_has_its_own_environment_variable() {
        let vars = [
            EngineSlot::Auth.env_var(),
            EngineSlot::Tunnel.env_var(),
            EngineSlot::SshForward.env_var(),
        ];
        assert_eq!(vars, ["LCC_AUTH_ENGINE", "LCC_TUNNEL_ENGINE", "LCC_SSH_FORWARD_ENGINE"]);
        assert_eq!(EngineSlot::from_key("tunnel"), Some(EngineSlot::Tunnel));
        assert_eq!(EngineSlot::from_key("wat"), None);
    }
}
```

- [ ] **Step 2: Ejecútalos y comprueba que fallan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib engine_pref::
```

Esperado: FALLO de compilación — `cannot find type Engine`, `cannot find type EngineSlot`, `cannot find type EnginePrefs`.

- [ ] **Step 3: Implementa**

Sustituye la cabecera y el cuerpo de `native/src/engine_pref.rs` por esto, conservando el `mod tests` del paso 1:

```rust
//! Which engines LCC uses, and where those choices are stored.
//!
//! Rust owns the file so the answer is available from the very first call —
//! before any UI exists. A setter that Dart had to call at startup would leave
//! a window in which early calls silently used the default, and "sometimes it
//! starts on the wrong engine" is a bug that costs days to chase.
//!
//! Nothing here caches. The engine can change while the app runs, and the two
//! caches that assumed otherwise were the critical finding of D5's final
//! review. The file is tiny and the OS page cache absorbs the reads.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// An engine choice, independent of what it selects. `AuthEngine` and
/// `TunnelEngine` convert from this, so the precedence rule lives in one place
/// instead of being copied per selector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    Native,
    Gcloud,
}

/// Which selector a preference belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineSlot {
    Auth,
    Tunnel,
    SshForward,
}

#[derive(Serialize, Deserialize, Default)]
struct EnginePrefs {
    #[serde(skip_serializing_if = "Option::is_none")]
    auth_engine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tunnel_engine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ssh_forward_engine: Option<String>,
}

impl EngineSlot {
    /// The environment variable that outranks the stored file for this slot.
    pub fn env_var(self) -> &'static str {
        match self {
            EngineSlot::Auth => "LCC_AUTH_ENGINE",
            EngineSlot::Tunnel => "LCC_TUNNEL_ENGINE",
            EngineSlot::SshForward => "LCC_SSH_FORWARD_ENGINE",
        }
    }

    /// The name Dart uses to address this slot across the bridge.
    pub fn key(self) -> &'static str {
        match self {
            EngineSlot::Auth => "auth",
            EngineSlot::Tunnel => "tunnel",
            EngineSlot::SshForward => "ssh_forward",
        }
    }

    /// Parse a slot name from the bridge. `None` for anything unknown, so a
    /// typo on the Dart side becomes a visible error rather than a silent
    /// write to the wrong slot.
    pub fn from_key(key: &str) -> Option<EngineSlot> {
        match key {
            "auth" => Some(EngineSlot::Auth),
            "tunnel" => Some(EngineSlot::Tunnel),
            "ssh_forward" => Some(EngineSlot::SshForward),
            _ => None,
        }
    }

    fn get(self, prefs: &EnginePrefs) -> Option<&str> {
        match self {
            EngineSlot::Auth => prefs.auth_engine.as_deref(),
            EngineSlot::Tunnel => prefs.tunnel_engine.as_deref(),
            EngineSlot::SshForward => prefs.ssh_forward_engine.as_deref(),
        }
    }

    fn set(self, prefs: &mut EnginePrefs, value: &str) {
        let field = match self {
            EngineSlot::Auth => &mut prefs.auth_engine,
            EngineSlot::Tunnel => &mut prefs.tunnel_engine,
            EngineSlot::SshForward => &mut prefs.ssh_forward_engine,
        };
        *field = Some(value.to_string());
    }
}

fn pref_path() -> Option<PathBuf> {
    Some(crate::app_dirs::migrated_app_dir(dirs::data_local_dir()?).join("engine.json"))
}

/// Everything stored today. A corrupt or absent file is not a crash: it means
/// "no preferences".
fn load_prefs() -> EnginePrefs {
    let Some(path) = pref_path() else {
        return EnginePrefs::default();
    };
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return EnginePrefs::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

/// Resolve one slot from the two sources, most significant first.
///
/// The environment variable wins outright: it is the diagnostic escape hatch,
/// and the hostile-environment QA launches the app with it. An unrecognised
/// value at either level falls through rather than deciding, so a corrupt file
/// cannot silently move a user onto another engine.
pub(crate) fn resolve(env: Option<&str>, file: Option<&str>) -> Engine {
    [env, file]
        .into_iter()
        .flatten()
        .find_map(parse_engine)
        .unwrap_or(Engine::Native)
}

/// An engine name, or None when the value names no engine we know.
fn parse_engine(value: &str) -> Option<Engine> {
    match value {
        "native" => Some(Engine::Native),
        "gcloud" => Some(Engine::Gcloud),
        _ => None,
    }
}

/// The engine actually in force for `slot`.
pub fn engine_for(slot: EngineSlot) -> Engine {
    let env = std::env::var(slot.env_var()).ok();
    let prefs = load_prefs();
    resolve(env.as_deref(), slot.get(&prefs))
}

/// The engine this slot's environment variable is forcing, when it names one.
///
/// `None` means the environment is not overriding: either the variable is
/// unset, or its value is not an engine and `resolve` falls through to the
/// stored preference. Settings surfaces this so a user whose environment
/// outranks their choice is told so instead of watching the radio move with
/// no effect.
pub fn env_override(slot: EngineSlot) -> Option<Engine> {
    parse_engine(std::env::var(slot.env_var()).ok()?.as_str())
}

/// The stored choice for `slot`, or `None` when the user has never made one.
pub fn stored(slot: EngineSlot) -> Option<String> {
    slot.get(&load_prefs()).map(str::to_string)
}

/// Persist the user's choice for one slot, leaving the other slots untouched.
pub fn set_stored(slot: EngineSlot, engine: &str) -> Result<()> {
    if parse_engine(engine).is_none() {
        return Err(anyhow!("Unknown engine: {}", engine));
    }
    let path = pref_path().ok_or_else(|| anyhow!("Cannot determine the data directory"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create the data directory")?;
    }
    // Read-modify-write: this function rewrites the whole file, so building it
    // from a fresh default would erase the other two slots.
    let mut prefs = load_prefs();
    slot.set(&mut prefs, engine);
    let json = serde_json::to_string(&prefs).context("Failed to serialize the engine preferences")?;
    // Write through a temp file: a half-written engine.json would read as "no
    // preference" on the next launch and silently move the user's engine.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json).context("Failed to write the engine preferences")?;
    std::fs::rename(&tmp, &path).context("Failed to replace the engine preferences")?;
    tracing::info!(slot = slot.key(), engine, "Stored an engine preference");
    Ok(())
}
```

- [ ] **Step 4: Cablea `oauth::auth_engine`**

En `native/src/oauth.rs`, sustituye el cuerpo de `auth_engine()` (línea 39) por:

```rust
pub fn auth_engine() -> AuthEngine {
    crate::engine_pref::engine_for(crate::engine_pref::EngineSlot::Auth).into()
}
```

y añade la conversión justo debajo de la declaración de `AuthEngine`:

```rust
impl From<crate::engine_pref::Engine> for AuthEngine {
    fn from(e: crate::engine_pref::Engine) -> Self {
        match e {
            crate::engine_pref::Engine::Native => AuthEngine::Native,
            crate::engine_pref::Engine::Gcloud => AuthEngine::Gcloud,
        }
    }
}
```

Borra de `oauth.rs` cualquier lectura directa de `LCC_AUTH_ENGINE` que quede: la única fuente es ahora `engine_pref`.

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
```

Esperado: PASS, y `cargo build --lib` con cero warnings. Si `set_stored_engine`, `stored_engine` o `env_override()` sin argumento quedan sin llamadores, **bórralos**; no los marques como permitidos.

- [ ] **Step 6: Commit**

```bash
git add native/src/engine_pref.rs native/src/oauth.rs
git commit -m "refactor(engines): una sola regla de precedencia para las tres ranuras

engine.json pasa de una clave a tres. La escritura es leer-modificar-escribir
porque reescribe el fichero entero: construirlo desde un default borraría las
otras dos preferencias en cuanto alguien cambiara una.

Nada cachea. El motor cambia con la app en marcha, y las dos cachés que
asumían lo contrario fueron el hallazgo crítico de la revisión final de D5."
```

---

### Task 2: El túnel y el reenvío SSH usan ese mecanismo

**Files:**
- Modify: `native/src/tunnel.rs:24-58`

**Interfaces:**
- Consumes de la tarea 1: `engine_pref::{Engine, EngineSlot, engine_for}`.
- Produces: `tunnel_engine()` y `ssh_forward_engine()` con la misma firma pública que hoy (`-> TunnelEngine`), ya respaldadas por el fichero.

**Contexto que necesitas:** hoy ambas leen su variable de entorno directamente y no consultan ningún fichero, así que un ajuste no puede alcanzarlas. `tunnel.rs:37` dice "Debug/escape-hatch aid; deliberately not exposed in Settings": ese comentario deja de ser cierto en la tarea 4 y se actualiza aquí.

Ojo: `parse_tunnel_engine` y `parse_ssh_forward_engine` tienen tests propios en ese fichero. Al desaparecer las funciones, **borra también sus tests** — la precedencia ya la cubre `engine_pref`. No dejes tests que prueben funciones que ya no existen.

- [ ] **Step 1: Escribe el test que falla**

Al `mod tests` de `native/src/tunnel.rs`:

```rust
    /// Las dos ranuras nuevas pasan por el mismo sitio que la de auth. Si
    /// alguna volviera a leer el entorno por su cuenta, el selector de Ajustes
    /// no la alcanzaría y el radio se movería sin efecto.
    #[test]
    fn both_tunnel_selectors_resolve_through_the_shared_preference() {
        use crate::engine_pref::{Engine, EngineSlot};
        assert_eq!(
            TunnelEngine::from(Engine::Gcloud),
            TunnelEngine::Gcloud
        );
        assert_eq!(TunnelEngine::from(Engine::Native), TunnelEngine::Native);
        assert_eq!(EngineSlot::Tunnel.env_var(), "LCC_TUNNEL_ENGINE");
        assert_eq!(EngineSlot::SshForward.env_var(), "LCC_SSH_FORWARD_ENGINE");
    }
```

- [ ] **Step 2: Ejecútalo y comprueba que falla**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib tunnel::
```

Esperado: FALLO de compilación — `From<Engine>` no está implementado para `TunnelEngine`.

- [ ] **Step 3: Implementa**

En `native/src/tunnel.rs`, borra `parse_tunnel_engine` y `parse_ssh_forward_engine` con sus tests, y sustituye las dos funciones públicas por:

```rust
impl From<crate::engine_pref::Engine> for TunnelEngine {
    fn from(e: crate::engine_pref::Engine) -> Self {
        match e {
            crate::engine_pref::Engine::Native => TunnelEngine::Native,
            crate::engine_pref::Engine::Gcloud => TunnelEngine::Gcloud,
        }
    }
}

/// Which engine opens IAP tunnels. Native is the default; `gcloud` opts out to
/// the legacy engine. Selectable in Settings under Advanced since SG-E, and
/// still forceable with `LCC_TUNNEL_ENGINE`, which outranks the stored choice.
pub fn tunnel_engine() -> TunnelEngine {
    crate::engine_pref::engine_for(crate::engine_pref::EngineSlot::Tunnel).into()
}

/// Which engine opens SSH port forwards. Native is the default since SP-2. The
/// gcloud forward is **kept**, not retired: the 2026-08-21 decision keeps it as
/// a selectable escape hatch for environments the native one cannot serve.
pub fn ssh_forward_engine() -> TunnelEngine {
    crate::engine_pref::engine_for(crate::engine_pref::EngineSlot::SshForward).into()
}
```

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
```

Esperado: PASS y cero warnings.

- [ ] **Step 5: Commit**

```bash
git add native/src/tunnel.rs
git commit -m "refactor(tunnel): los dos motores de túnel salen del entorno al fichero

Leían su variable directamente, así que ningún ajuste podía alcanzarlos. Ahora
pasan por engine_pref, con la misma precedencia que el de auth: el entorno
sigue mandando, que es lo que el QA en entorno hostil necesita."
```

---

### Task 3: El bridge, parametrizado por ranura

**Files:**
- Modify: `native/src/api.rs:995-1030`
- Modify (regenerado): `lib/src/bridge/api.dart/`
- Modify: `lib/src/features/settings_dialog.dart:37-38,135`, `lib/src/features/engine_change_notice.dart:19`, `lib/src/features/account_management_dialog.dart:206,277`, `lib/main.dart:534`

**Interfaces:**
- Consumes de la tarea 1: `engine_pref::{EngineSlot, engine_for, stored, set_stored, env_override}`.
- Produces, para la tarea 4: en Dart, `engineFor(slot: String) -> Future<String>`, `storedEngine(slot: String) -> Future<String?>`, `engineOverride(slot: String) -> Future<String?>` y `setEngine(slot: String, engine: String) -> Future<void>`. Los valores de `slot` son `'auth'`, `'tunnel'` y `'ssh_forward'`.

**Contexto que necesitas:** hoy hay cuatro envoltorios específicos de auth (`auth_engine`, `stored_auth_engine`, `auth_engine_override`, `set_auth_engine`). Se sustituyen por cuatro parametrizados. Son **ocho** los sitios de Dart que llaman a los antiguos, todos listados arriba; recablearlos es mecánico.

`set_auth_engine` invalida hoy la caché de tokens. En la versión parametrizada eso **solo** debe ocurrir para la ranura `auth`: cambiar el motor de túnel no toca credenciales.

Regeneración del bridge:

```bash
cd /home/jlopezre/GitHub/LCC && flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```

Una regeneración puede romper call sites; arréglalos a mano en el call site, nunca en la salida generada, y di qué cambió.

- [ ] **Step 1: Sustituye los cuatro envoltorios**

En `native/src/api.rs`, borra `auth_engine`, `stored_auth_engine`, `auth_engine_override` y `set_auth_engine`, y pon en su lugar:

```rust
/// Parse a slot name from Dart, or fail loudly. A typo must not resolve to a
/// default slot: that would read one preference and write another.
fn slot_from_key(slot: &str) -> anyhow::Result<crate::engine_pref::EngineSlot> {
    crate::engine_pref::EngineSlot::from_key(slot)
        .ok_or_else(|| anyhow::anyhow!("Unknown engine slot: {}", slot))
}

fn engine_name(engine: crate::engine_pref::Engine) -> String {
    match engine {
        crate::engine_pref::Engine::Native => "native".to_string(),
        crate::engine_pref::Engine::Gcloud => "gcloud".to_string(),
    }
}

/// The engine actually in force for this slot, with the environment override
/// already applied.
pub fn engine_for(slot: String) -> anyhow::Result<String> {
    Ok(engine_name(crate::engine_pref::engine_for(slot_from_key(&slot)?)))
}

/// The user's explicit choice for this slot, or None when they have never
/// made one.
pub fn stored_engine(slot: String) -> anyhow::Result<Option<String>> {
    Ok(crate::engine_pref::stored(slot_from_key(&slot)?))
}

/// The engine this slot's environment variable is forcing, or None when the
/// environment is not overriding.
pub fn engine_override(slot: String) -> anyhow::Result<Option<String>> {
    Ok(crate::engine_pref::env_override(slot_from_key(&slot)?).map(engine_name))
}

/// Persist the user's choice for one slot.
pub async fn set_engine(slot: String, engine: String) -> anyhow::Result<()> {
    let slot = slot_from_key(&slot)?;
    crate::engine_pref::set_stored(slot, &engine)?;
    // Only the auth slot changes which credentials serve tokens. Invalidating
    // on a tunnel-engine change would be noise pretending to be care.
    if slot == crate::engine_pref::EngineSlot::Auth {
        crate::gcp_rest_client::invalidate_cached_access_token().await;
    }
    Ok(())
}
```

Si quedaba un `engine_name` que tomaba `crate::oauth::AuthEngine`, bórralo: ya no lo llama nadie.

- [ ] **Step 2: Regenera el bridge**

```bash
cd /home/jlopezre/GitHub/LCC && flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
cd native && cargo build --lib
```

Esperado: `cargo build --lib` sin warnings.

- [ ] **Step 3: Recablea los ocho sitios de Dart**

| Fichero:línea | Antes | Después |
|---|---|---|
| `settings_dialog.dart:37` | `await authEngineOverride()` | `await engineOverride(slot: 'auth')` |
| `settings_dialog.dart:38` | `await storedAuthEngine() ?? await authEngine()` | `await storedEngine(slot: 'auth') ?? await engineFor(slot: 'auth')` |
| `settings_dialog.dart:135` | `await setAuthEngine(engine: value)` | `await setEngine(slot: 'auth', engine: value)` |
| `engine_change_notice.dart:19` | `await storedAuthEngine() != null` | `await storedEngine(slot: 'auth') != null` |
| `account_management_dialog.dart:206` | `await authEngine() == 'gcloud'` | `await engineFor(slot: 'auth') == 'gcloud'` |
| `account_management_dialog.dart:277` | ídem | ídem |
| `main.dart:534` | ídem | ídem |

Comprueba los nombres de parámetro que el bridge haya generado de verdad (posicional frente a nombrado) y ajústalos; el generador usa nombrados para funciones de más de un argumento.

- [ ] **Step 4: Verifica**

```bash
cd /home/jlopezre/GitHub/LCC && flutter analyze && flutter test
grep -rn 'authEngine()\|storedAuthEngine()\|setAuthEngine(\|authEngineOverride()' lib/ --include="*.dart"
```

Esperado: cero líneas `error •`; `All tests passed!`; y el `grep` **sin resultados**, incluido el bridge generado.

- [ ] **Step 5: Commit**

```bash
git add native/src/api.rs lib/src/bridge/ lib/src/features/ lib/main.dart
git commit -m "refactor(bridge): los envoltorios del motor, parametrizados por ranura

Cuatro funciones específicas de auth pasan a cuatro que toman la ranura. Una
ranura desconocida es un error, no un defecto silencioso: resolver un typo a
la ranura por defecto leería una preferencia y escribiría otra.

Solo la ranura de auth invalida la caché de tokens; el motor de túnel no toca
credenciales."
```

---

### Task 4: El bloque «Avanzado» en Ajustes

**Files:**
- Modify: `lib/src/features/settings_dialog.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Consumes de la tarea 3: `engineFor`, `storedEngine`, `engineOverride`, `setEngine`.

**Contexto que necesitas:** el selector de auth ocupa hoy unas cien líneas de `settings_dialog.dart` (aviso de anulación por entorno, `FutureBuilder`, `try/catch` con snackbar, guardas `mounted`, invalidación de providers). Copiarlo dos veces sería duplicación literal de un bloque de lógica, que la rúbrica de revisión trata como defecto. **Extráelo a un widget privado parametrizado** y úsalo tres veces.

La invalidación de providers **solo aplica a la ranura de auth**: cambiar el motor de túnel no cambia qué cuentas ni qué proyectos se ven. El widget la recibe como callback opcional.

- [ ] **Step 1: Claves i18n**

En `lib/l10n/app_en.arb`:

```json
  "settingsAdvancedTitle": "Advanced",
  "settingsAdvancedSubtitle": "Diagnostic settings. The native engines are recommended; change these only to work around a problem.",
  "settingsTunnelEngineTitle": "IAP tunnel engine",
  "settingsTunnelEngineNative": "Native (recommended)",
  "settingsTunnelEngineNativeSubtitle": "LCC opens the IAP tunnel itself, with no gcloud process.",
  "settingsTunnelEngineGcloud": "gcloud CLI",
  "settingsTunnelEngineGcloudSubtitle": "Uses 'gcloud compute start-iap-tunnel'. Requires gcloud installed.",
  "settingsSshForwardEngineTitle": "SSH port forward engine",
  "settingsSshForwardEngineNative": "Native (recommended)",
  "settingsSshForwardEngineNativeSubtitle": "LCC forwards the port itself, with no ssh process.",
  "settingsSshForwardEngineGcloud": "gcloud CLI",
  "settingsSshForwardEngineGcloudSubtitle": "Uses gcloud and the system ssh. Requires gcloud installed.",
  "settingsEngineAppliesToNewOnly": "Tunnels already open keep the engine they were opened with. This applies to the next one.",
```

En `lib/l10n/app_es.arb`, los mismos identificadores:

```json
  "settingsAdvancedTitle": "Avanzado",
  "settingsAdvancedSubtitle": "Ajustes de diagnóstico. Los motores nativos son los recomendados; cámbielos solo para sortear un problema.",
  "settingsTunnelEngineTitle": "Motor del túnel IAP",
  "settingsTunnelEngineNative": "Nativo (recomendado)",
  "settingsTunnelEngineNativeSubtitle": "LCC abre el túnel IAP por sí mismo, sin ningún proceso de gcloud.",
  "settingsTunnelEngineGcloud": "CLI de gcloud",
  "settingsTunnelEngineGcloudSubtitle": "Usa 'gcloud compute start-iap-tunnel'. Requiere gcloud instalado.",
  "settingsSshForwardEngineTitle": "Motor del reenvío de puertos SSH",
  "settingsSshForwardEngineNative": "Nativo (recomendado)",
  "settingsSshForwardEngineNativeSubtitle": "LCC reenvía el puerto por sí mismo, sin ningún proceso ssh.",
  "settingsSshForwardEngineGcloud": "CLI de gcloud",
  "settingsSshForwardEngineGcloudSubtitle": "Usa gcloud y el ssh del sistema. Requiere gcloud instalado.",
  "settingsEngineAppliesToNewOnly": "Los túneles ya abiertos conservan el motor con el que se abrieron. Esto se aplica al siguiente.",
```

Luego `flutter gen-l10n`.

- [ ] **Step 2: Extrae el selector a un widget**

En `lib/src/features/settings_dialog.dart`, mueve el bloque del selector de auth a un widget privado con esta forma, sin cambiar su comportamiento:

```dart
/// One engine selector: the environment-override notice, the two radios, and
/// the error handling. Three of these exist; the logic lives here once.
class _EngineSelector extends StatefulWidget {
  const _EngineSelector({
    required this.slot,
    required this.title,
    required this.nativeLabel,
    required this.nativeSubtitle,
    required this.gcloudLabel,
    required this.gcloudSubtitle,
    this.footnote,
    this.onChanged,
  });

  final String slot;
  final String title;
  final String nativeLabel;
  final String nativeSubtitle;
  final String gcloudLabel;
  final String gcloudSubtitle;

  /// Shown under the radios when the choice has a caveat worth stating.
  final String? footnote;

  /// Ran after a successful change. Only the auth slot needs one: it decides
  /// which accounts and projects the rest of the UI is showing.
  final VoidCallback? onChanged;

  @override
  State<_EngineSelector> createState() => _EngineSelectorState();
}
```

`_EngineSelectorState` conserva exactamente lo que hoy hace `_SettingsDialogState` para el motor de auth: `late Future<_EngineChoice> _future` creado en `initState`, `_load()` que llama a `engineOverride(slot: widget.slot)` y `storedEngine(slot: widget.slot) ?? engineFor(slot: widget.slot)`, el `FutureBuilder`, el `try/catch` con el snackbar de `settingsAuthEngineChangeFailed`, las guardas `mounted` en ambos puntos posteriores a un `await`, y el aviso naranja de anulación por entorno.

Renombra `_AuthEngineChoice` a `_EngineChoice`; su forma no cambia.

- [ ] **Step 3: Úsalo tres veces**

La sección de auth pasa a ser:

```dart
              _EngineSelector(
                slot: 'auth',
                title: l10n.settingsAuthEngineTitle,
                nativeLabel: l10n.settingsAuthEngineNative,
                nativeSubtitle: l10n.settingsAuthEngineNativeSubtitle,
                gcloudLabel: l10n.settingsAuthEngineGcloud,
                gcloudSubtitle: l10n.settingsAuthEngineGcloudSubtitle,
                onChanged: () {
                  // Without this the UI keeps showing the previous engine's
                  // accounts and projects until something else invalidates.
                  ref.invalidate(gcloudStatusProvider);
                  ref.invalidate(accountProvider);
                  ref.invalidate(projectsProvider);
                  ref.invalidate(instancesProvider);
                },
              ),
```

Y al final de la columna, antes del cierre, el bloque plegado:

```dart
              const Divider(height: 32),
              ExpansionTile(
                title: Text(
                  l10n.settingsAdvancedTitle,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(l10n.settingsAdvancedSubtitle),
                initiallyExpanded: false,
                childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                children: [
                  _EngineSelector(
                    slot: 'tunnel',
                    title: l10n.settingsTunnelEngineTitle,
                    nativeLabel: l10n.settingsTunnelEngineNative,
                    nativeSubtitle: l10n.settingsTunnelEngineNativeSubtitle,
                    gcloudLabel: l10n.settingsTunnelEngineGcloud,
                    gcloudSubtitle: l10n.settingsTunnelEngineGcloudSubtitle,
                    footnote: l10n.settingsEngineAppliesToNewOnly,
                  ),
                  const SizedBox(height: 16),
                  _EngineSelector(
                    slot: 'ssh_forward',
                    title: l10n.settingsSshForwardEngineTitle,
                    nativeLabel: l10n.settingsSshForwardEngineNative,
                    nativeSubtitle: l10n.settingsSshForwardEngineNativeSubtitle,
                    gcloudLabel: l10n.settingsSshForwardEngineGcloud,
                    gcloudSubtitle: l10n.settingsSshForwardEngineGcloudSubtitle,
                    footnote: l10n.settingsEngineAppliesToNewOnly,
                  ),
                ],
              ),
```

- [ ] **Step 4: Verifica**

```bash
cd /home/jlopezre/GitHub/LCC && flutter analyze && flutter test
```

Esperado: cero líneas `error •`; `All tests passed!`. El `es_overflow_test` renderiza `SettingsDialog` en español a 1024x640: si el bloque nuevo desborda, ahí saldrá — arréglalo con `Wrap`/`Flexible`, no bajando el tamaño de letra.

- [ ] **Step 5: Commit**

```bash
git add lib/src/features/settings_dialog.dart lib/l10n/
git commit -m "feat(settings): los tres motores, y los dos de diagnóstico plegados

El selector se extrae a un widget y se usa tres veces en vez de copiarse dos.
El de auth es una elección real del usuario —decide qué cuentas ve—; los de
túnel y reenvío son escotillas: van detrás de un desplegable cerrado, con la
advertencia de que el nativo es el recomendado.

Solo el de auth invalida los providers: los otros dos no cambian qué se ve."
```

---

### Task 5: Doctor — ¿responde el almacén de credenciales?

**Files:**
- Modify: `native/src/token_store.rs`
- Modify: `native/src/doctor.rs`

**Interfaces:**
- Produces, para las tareas 6 y 7: `token_store::probe_keyring() -> Result<()>`, y en `doctor.rs` la función pura `native_check_status(engine: crate::oauth::AuthEngine) -> DoctorCheckStatus`.

**Contexto que necesitas:** **D2 pasó su QA en verde compilando contra el *mock* del crate `keyring` y sin persistir nada.** Esta comprobación existe por eso. `token_store` ya distingue el fallo de backend (`NoStorageAccess` / `PlatformFailure`) del "esta cuenta no está guardada" (`NoEntry`) en `keyring_backend_error` (`token_store.rs:163`); la sonda reutiliza esa clasificación en vez de inventar la suya.

**La sonda no escribe nada.** Lee una clave que no puede pertenecer a ninguna cuenta. Si escribiera, dejaría basura en el llavero del usuario cada vez que abre Doctor.

Simétrica a lo que D5 hizo al revés: bajo el motor **gcloud** esta fila sale en `Skipped`.

- [ ] **Step 1: Escribe los tests que fallan**

Al `mod tests` de `native/src/doctor.rs`:

```rust
    /// Bajo el motor gcloud, el almacén nativo no se usa: preguntarle es ruido.
    #[test]
    fn a_native_check_is_skipped_under_the_gcloud_engine() {
        assert_eq!(
            native_check_status(crate::oauth::AuthEngine::Gcloud),
            DoctorCheckStatus::Skipped
        );
    }

    /// Y bajo el nativo es determinante: es el almacén del que depende todo.
    #[test]
    fn a_native_check_decides_under_the_native_engine() {
        assert_ne!(
            native_check_status(crate::oauth::AuthEngine::Native),
            DoctorCheckStatus::Skipped
        );
    }
```

Y al `mod tests` de `native/src/token_store.rs`:

```rust
    /// La prueba negativa de la sonda: la clave que usa no puede colisionar
    /// con la de ninguna cuenta. Si colisionara, Doctor leería el token de un
    /// usuario real para decidir si el llavero responde.
    #[test]
    fn the_probe_key_can_belong_to_no_account() {
        assert_ne!(PROBE_KEY, keyring_key(""));
        assert_ne!(PROBE_KEY, keyring_key("someone@example.com"));
        assert!(!PROBE_KEY.starts_with("oauth::"));
    }
```

- [ ] **Step 2: Ejecútalos y comprueba que fallan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib
```

Esperado: FALLO de compilación — `cannot find function native_check_status`, `cannot find value PROBE_KEY`.

- [ ] **Step 3: La sonda, en `token_store.rs`**

```rust
/// A keyring key that belongs to no account. `keyring_key` prefixes every
/// account with `oauth::`, so nothing here can collide with a real one.
const PROBE_KEY: &str = "doctor::probe";

/// Is the system keyring answering?
///
/// Reads a key that cannot exist and reports what the backend said. `NoEntry`
/// is the healthy answer: the service replied and has no such record. A down
/// backend gets the actionable message `keyring_backend_error` already writes.
///
/// This never writes. Doctor runs on demand and a probe that stored something
/// would leave litter in the user's keyring every time.
pub fn probe_keyring() -> Result<()> {
    let entry = Entry::new(SERVICE_NAME, PROBE_KEY)
        .map_err(|e| anyhow!("Invalid keyring probe entry: {}", e))?;
    match entry.get_password() {
        Ok(_) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(keyring_backend_error(e, "read")),
    }
}
```

- [ ] **Step 4: La fila, en `doctor.rs`**

A nivel de módulo:

```rust
/// How a native-auth check reports, given the engine in use.
///
/// The mirror of `gcloud_check_status`: under the gcloud engine LCC's own
/// store serves nothing, so asking it is noise. Under the native engine it is
/// what everything depends on.
fn native_check_status(engine: crate::oauth::AuthEngine) -> DoctorCheckStatus {
    match engine {
        crate::oauth::AuthEngine::Gcloud => DoctorCheckStatus::Skipped,
        crate::oauth::AuthEngine::Native => DoctorCheckStatus::Pass,
    }
}

/// Message for a check skipped because the auth engine is gcloud.
const NOT_APPLICABLE_GCLOUD_ENGINE: &str = "Skipped: not applicable, the auth engine is gcloud";
```

Y en `impl DoctorClient`:

```rust
    // ==========================================
    // CHECK: LCC credential store reachable
    // ==========================================

    async fn check_credential_store(&self) -> DoctorCheckResult {
        let start = Instant::now();
        if native_check_status(crate::oauth::auth_engine()) == DoctorCheckStatus::Skipped {
            return self.skipped_check(
                "auth_credential_store",
                "LCC Credential Store",
                DoctorCheckCategory::Authentication,
                NOT_APPLICABLE_GCLOUD_ENGINE,
                start,
            );
        }
        // token_store touches zbus, which panics on a tokio worker thread.
        // `store_call` returns Result<T> where T is already the wrapped
        // function's Result, so this is a Result<Result<()>>: flatten it or the
        // match arms will not typecheck.
        match crate::oauth::store_call(crate::token_store::probe_keyring)
            .await
            .and_then(|r| r)
        {
            Ok(()) => DoctorCheckResult {
                check_id: "auth_credential_store".to_string(),
                name: "LCC Credential Store".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Pass,
                message: "The system keyring is reachable".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "auth_credential_store".to_string(),
                name: "LCC Credential Store".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "The system keyring is not reachable".to_string(),
                details: Some(e.to_string()),
                suggestion: Some(
                    "Sign-ins cannot be stored without a Secret Service. On Linux, start \
                     GNOME Keyring or KWallet, or run LCC inside a desktop session."
                        .to_string(),
                ),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }
```

Añádela a `run_diagnostics` justo después del bloque de `check_adc_credentials` (alrededor de `doctor.rs:1053`):

```rust
        checks.push(self.check_credential_store().await);
```

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
```

Esperado: PASS y cero warnings.

- [ ] **Step 6: Verifica la prueba negativa**

Rompe a mano `probe_keyring` para que trate `NoStorageAccess` como `Ok(())` y ejecuta los tests: el de `PROBE_KEY` seguirá pasando, así que **añade** este a `token_store.rs` si no cubre el caso, y **revierte** la rotura después:

```rust
    /// La sonda tiene que distinguir "el servicio respondió y no hay registro"
    /// de "el servicio no está". Si tratara ambos como salud, Doctor daría
    /// verde con el llavero caído, que es exactamente lo que pasó en D2.
    #[test]
    fn a_down_backend_is_not_health() {
        let down = keyring_backend_error(
            keyring::Error::NoStorageAccess(Box::new(std::io::Error::other("no service"))),
            "read",
        );
        assert!(down.to_string().contains("keyring is unavailable"));
    }
```

Di en el informe qué rompiste y qué test falló.

- [ ] **Step 7: Commit**

```bash
git add native/src/token_store.rs native/src/doctor.rs
git commit -m "feat(doctor): preguntar al llavero si responde

D2 pasó su QA en verde compilando contra el mock del crate y sin persistir
nada. Esta fila existe por eso: lee una clave que no puede existir y reporta
lo que dijo el backend. NoEntry es la respuesta sana.

No escribe. Doctor se abre a demanda, y una sonda que guardara algo dejaría
basura en el llavero del usuario cada vez."
```

---

### Task 6: Doctor — ¿coinciden el índice y el llavero?

**Files:**
- Modify: `native/src/token_store.rs`
- Modify: `native/src/doctor.rs`

**Interfaces:**
- Consumes de la tarea 5: `native_check_status`, `NOT_APPLICABLE_GCLOUD_ENGINE`.
- Produces: `token_store::IndexHealth` y `token_store::index_health() -> IndexHealth`.

**Contexto que necesitas, y es la trampa de esta tarea:** `list_accounts()` **ya poda** las entradas cuyo registro del llavero desapareció, y guarda el índice podado (`token_store.rs:231-252`). Es decir, repara la incoherencia en silencio. Una comprobación construida sobre `list_accounts()` no vería nunca nada: hay que leer el índice **crudo**, antes de la reparación.

Y hay un segundo caso que no se puede confundir con el primero: **con el llavero caído, todas las cuentas parecen huérfanas.** Reportar "tiene 4 cuentas huérfanas" cuando lo que pasa es que no hay Secret Service sería un diagnóstico falso. Ese caso lo posee la fila de la tarea 5, así que aquí se reporta como "no se puede saber".

- [ ] **Step 1: Escribe el test que falla**

Al `mod tests` de `native/src/token_store.rs`:

```rust
    /// Con el llavero caído TODAS las cuentas parecen huérfanas. Reportar
    /// "4 cuentas huérfanas" cuando lo que pasa es que no hay Secret Service
    /// es un diagnóstico falso; ese caso lo posee la fila del almacén.
    #[test]
    fn an_unreachable_keyring_is_not_a_pile_of_orphans() {
        assert_eq!(
            classify_index(vec!["a@example.com".into()], None),
            IndexHealth::Unavailable
        );
    }

    /// Cuentas listadas sin registro detrás: "aparece en la lista pero no
    /// autentica", que es como se manifiesta de cara al usuario.
    #[test]
    fn accounts_without_a_keyring_record_are_orphans() {
        assert_eq!(
            classify_index(
                vec!["a@example.com".into(), "b@example.com".into()],
                Some(vec!["a@example.com".into()])
            ),
            IndexHealth::Orphaned(vec!["b@example.com".into()])
        );
    }

    #[test]
    fn a_matching_index_is_consistent() {
        assert_eq!(
            classify_index(
                vec!["a@example.com".into()],
                Some(vec!["a@example.com".into()])
            ),
            IndexHealth::Consistent(1)
        );
        assert_eq!(classify_index(vec![], Some(vec![])), IndexHealth::Consistent(0));
    }
```

- [ ] **Step 2: Ejecútalo y comprueba que falla**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib token_store::
```

Esperado: FALLO de compilación — `cannot find type IndexHealth`, `cannot find function classify_index`.

- [ ] **Step 3: Implementa en `token_store.rs`**

```rust
/// What the account index says versus what the keyring actually holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexHealth {
    /// Every listed account has a record behind it. Carries how many.
    Consistent(usize),
    /// Listed accounts with no keyring record. They show up as "it is in the
    /// list but it does not authenticate".
    Orphaned(Vec<String>),
    /// The keyring did not answer, so the question cannot be settled here.
    Unavailable,
}

/// Pure classification, so the three cases are testable without a keyring.
/// `present` is `None` when the backend did not answer.
fn classify_index(listed: Vec<String>, present: Option<Vec<String>>) -> IndexHealth {
    let Some(present) = present else {
        return IndexHealth::Unavailable;
    };
    let orphans: Vec<String> = listed
        .into_iter()
        .filter(|email| !present.contains(email))
        .collect();
    if orphans.is_empty() {
        IndexHealth::Consistent(present.len())
    } else {
        IndexHealth::Orphaned(orphans)
    }
}

/// Compare the on-disk index against the keyring **without repairing it**.
///
/// `list_accounts` prunes orphans on the way out and saves the pruned index,
/// so a check built on it would never see anything. This reads the raw index
/// first.
pub fn index_health() -> IndexHealth {
    let listed = load_index().accounts;
    let mut present = Vec::new();
    for email in &listed {
        match Entry::new(SERVICE_NAME, &keyring_key(email)) {
            Ok(entry) => match entry.get_password() {
                Ok(_) => present.push(email.clone()),
                Err(keyring::Error::NoEntry) => {}
                // The backend is down: nothing here can be concluded.
                Err(_) => return IndexHealth::Unavailable,
            },
            Err(_) => return IndexHealth::Unavailable,
        }
    }
    classify_index(listed, Some(present))
}
```

- [ ] **Step 4: La fila, en `doctor.rs`**

En `impl DoctorClient`:

```rust
    // ==========================================
    // CHECK: account index matches the keyring
    // ==========================================

    async fn check_account_index(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let id = "auth_account_index";
        let name = "LCC Account Index";
        if native_check_status(crate::oauth::auth_engine()) == DoctorCheckStatus::Skipped {
            return self.skipped_check(
                id, name, DoctorCheckCategory::Authentication,
                NOT_APPLICABLE_GCLOUD_ENGINE, start,
            );
        }
        let health = crate::oauth::store_call(crate::token_store::index_health)
            .await
            .unwrap_or(crate::token_store::IndexHealth::Unavailable);
        let (status, message, suggestion) = match &health {
            crate::token_store::IndexHealth::Consistent(n) => (
                DoctorCheckStatus::Pass,
                format!("{} stored sign-in(s), all present in the keyring", n),
                None,
            ),
            // The credential-store check owns this diagnosis; saying it twice
            // would read as two problems.
            crate::token_store::IndexHealth::Unavailable => (
                DoctorCheckStatus::Skipped,
                "Skipped: the keyring did not answer".to_string(),
                None,
            ),
            crate::token_store::IndexHealth::Orphaned(emails) => (
                DoctorCheckStatus::Warning,
                format!("{} account(s) listed with no stored sign-in: {}", emails.len(), emails.join(", ")),
                Some("Remove and add those accounts again to restore their sign-in.".to_string()),
            ),
        };
        DoctorCheckResult {
            check_id: id.to_string(),
            name: name.to_string(),
            category: DoctorCheckCategory::Authentication,
            status,
            message,
            details: None,
            suggestion,
            fix_command: None,
            fix_action_id: None,
            duration_ms: start.elapsed().as_millis() as u64,
        }
    }
```

Y en `run_diagnostics`, justo después de la fila de la tarea 5:

```rust
        checks.push(self.check_account_index().await);
```

**Un correo electrónico no es un secreto, pero un refresh token sí.** El mensaje lista correos, nunca lo que hay dentro de la entrada del llavero.

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
```

Esperado: PASS y cero warnings.

- [ ] **Step 6: Verifica la prueba negativa**

Cambia `classify_index` para que devuelva `IndexHealth::Orphaned(listed)` cuando `present` es `None` —el defecto que la tarea evita— y ejecuta `cargo test --lib token_store::`. Esperado: falla `an_unreachable_keyring_is_not_a_pile_of_orphans`. **Revierte** y dilo en el informe.

- [ ] **Step 7: Commit**

```bash
git add native/src/token_store.rs native/src/doctor.rs
git commit -m "feat(doctor): mirar el índice antes de que se repare solo

list_accounts poda las cuentas sin registro y guarda el índice podado, así que
una comprobación construida sobre él no vería nunca nada. index_health lee el
índice crudo.

Con el llavero caído todas las cuentas parecen huérfanas: ese caso se reporta
como 'no se puede saber' en vez de inventar cuatro huérfanas, porque quien lo
diagnostica es la fila del almacén."
```

---

### Task 7: Doctor — ¿se acuña el token ahora?

**Files:**
- Modify: `native/src/doctor.rs`

**Interfaces:**
- Consumes de las tareas 5 y 6: `native_check_status`, `NOT_APPLICABLE_GCLOUD_ENGINE`.

**Contexto que necesitas:** es la única comprobación de punta a punta, y la única que hace red. Refresca de verdad con el refresh token guardado, usando `crate::oauth::refresh_access_token` (`oauth.rs:400`).

**Tiene que distinguir dos casos, y ésta es la razón de ser de la tarea.** Sin una fila de "cuenta activa" —que se decidió no añadir—, alguien recién instalado vería un error de refresco cuando lo que le pasa es que no ha entrado. Un mensaje de token roto ante una app que nunca se ha usado manda al usuario a diagnosticar algo que no existe.

- [ ] **Step 1: Escribe los tests que fallan**

Al `mod tests` de `native/src/doctor.rs`:

```rust
    /// Nadie ha entrado todavía: eso no es un token roto, es una app sin usar.
    /// Sin esta distinción, un usuario recién instalado se pone a diagnosticar
    /// un fallo de refresco que no existe.
    #[test]
    fn no_account_is_not_a_broken_token() {
        let r = token_check_outcome(None);
        assert_eq!(r.0, DoctorCheckStatus::Warning);
        assert!(r.1.contains("No account"));
        assert_eq!(r.3, Some("re_authenticate".to_string()));
    }

    /// Hay cuenta y el refresco falló: eso sí es un fallo, y su remedio es
    /// volver a entrar.
    #[test]
    fn a_failed_refresh_is_a_failure() {
        let r = token_check_outcome(Some(Err("network is unreachable".to_string())));
        assert_eq!(r.0, DoctorCheckStatus::Fail);
        assert!(r.1.contains("could not be renewed"));
        assert_eq!(r.3, Some("re_authenticate".to_string()));
    }

    /// Y el camino sano nombra la cuenta, para que se vea CUÁL respondió.
    #[test]
    fn a_fresh_token_names_the_account() {
        let r = token_check_outcome(Some(Ok("someone@example.com".to_string())));
        assert_eq!(r.0, DoctorCheckStatus::Pass);
        assert!(r.1.contains("someone@example.com"));
        assert_eq!(r.3, None);
    }

    /// La prueba negativa del secreto: el mensaje nunca lleva el token.
    #[test]
    fn no_outcome_can_carry_a_token() {
        for r in [
            token_check_outcome(None),
            token_check_outcome(Some(Ok("someone@example.com".to_string()))),
            token_check_outcome(Some(Err("ya29.A0ARR-a-real-looking-token".to_string()))),
        ] {
            assert!(!r.1.contains("ya29."));
            assert!(!r.2.clone().unwrap_or_default().contains("ya29."));
        }
    }
```

- [ ] **Step 2: Ejecútalos y comprueba que fallan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib doctor::
```

Esperado: FALLO de compilación — `cannot find function token_check_outcome`.

- [ ] **Step 3: Implementa**

A nivel de módulo en `doctor.rs`:

```rust
/// What the token check reports, given what happened.
///
/// `None` means no account is signed in; `Some(Ok(email))` a token that minted
/// just now; `Some(Err(message))` an account whose refresh failed. Returns
/// `(status, message, suggestion, fix_action_id)`.
///
/// The first case is not a failure. Without a separate "active account" row,
/// conflating them would tell a freshly installed user their token is broken
/// when they simply have not signed in.
///
/// The error text is never the refreshed token — only the reason the refresh
/// failed. A secret must not reach a Doctor report the user can export.
fn token_check_outcome(
    outcome: Option<std::result::Result<String, String>>,
) -> (DoctorCheckStatus, String, Option<String>, Option<String>) {
    match outcome {
        None => (
            DoctorCheckStatus::Warning,
            "No account is signed in to LCC".to_string(),
            Some("Sign in to LCC to use your Google Cloud resources.".to_string()),
            Some("re_authenticate".to_string()),
        ),
        Some(Ok(email)) => (
            DoctorCheckStatus::Pass,
            format!("Access token renewed for {}", email),
            None,
            None,
        ),
        Some(Err(reason)) => (
            DoctorCheckStatus::Fail,
            format!("The session could not be renewed: {}", reason),
            Some("Sign in to LCC again to renew your session.".to_string()),
            Some("re_authenticate".to_string()),
        ),
    }
}
```

Y en `impl DoctorClient`:

```rust
    // ==========================================
    // CHECK: LCC can mint an access token now
    // ==========================================

    async fn check_native_token(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let id = "auth_native_token";
        let name = "LCC Session";
        if native_check_status(crate::oauth::auth_engine()) == DoctorCheckStatus::Skipped {
            return self.skipped_check(
                id, name, DoctorCheckCategory::Authentication,
                NOT_APPLICABLE_GCLOUD_ENGINE, start,
            );
        }
        let active = crate::oauth::store_call(crate::token_store::active_account)
            .await
            .ok()
            .flatten();
        let outcome = match active {
            None => None,
            Some(email) => {
                let loaded = {
                    let e = email.clone();
                    // Result<Result<String>> — `store_call`'s own Result is
                    // about the join, not about the store. Flatten it.
                    crate::oauth::store_call(move || crate::token_store::load_refresh_token(&e))
                        .await
                        .and_then(|r| r)
                };
                match loaded {
                    Err(e) => Some(Err(crate::redact::redact_sensitive(&e.to_string()))),
                    Ok(refresh) => match crate::oauth::refresh_access_token(&refresh).await {
                        Ok(_) => Some(Ok(email)),
                        Err(e) => Some(Err(crate::redact::redact_sensitive(&e.to_string()))),
                    },
                }
            }
        };
        let (status, message, suggestion, fix_action_id) = token_check_outcome(outcome);
        DoctorCheckResult {
            check_id: id.to_string(),
            name: name.to_string(),
            category: DoctorCheckCategory::Authentication,
            status,
            message,
            details: None,
            suggestion,
            fix_command: None,
            fix_action_id,
            duration_ms: start.elapsed().as_millis() as u64,
        }
    }
```

El valor `Ok(_)` del refresco **se descarta a propósito**: el token nunca entra en la variable que acaba en el informe.

Y en `run_diagnostics`, tras la fila de la tarea 6:

```rust
        checks.push(self.check_native_token().await);
```

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
```

Esperado: PASS y cero warnings. Comprueba que `crate::redact::redact_sensitive` existe con esa ruta; si no, localiza el módulo de redacción y usa el suyo, y dilo en el informe.

- [ ] **Step 5: Verifica la prueba negativa**

Haz que `token_check_outcome` devuelva `Fail` también para `None` —el defecto que la tarea evita— y ejecuta `cargo test --lib doctor::`. Esperado: falla `no_account_is_not_a_broken_token`. **Revierte** y dilo en el informe.

- [ ] **Step 6: Commit**

```bash
git add native/src/doctor.rs
git commit -m "feat(doctor): refrescar de verdad, y no confundir dos cosas

Es la única comprobación de punta a punta. Y distingue 'no hay cuenta' de 'el
refresco falló': sin esa distinción, alguien recién instalado se pone a
diagnosticar un token roto cuando lo que pasa es que no ha entrado.

El token acuñado se descarta a propósito; el informe de Doctor se exporta."
```

---

### Task 8: Los remedios de administración ganan la consola

**Files:**
- Modify: `native/src/doctor.rs:396,437,451,656,770,810`

**Contexto que necesitas:** los comandos `gcloud …` que quedan en Doctor **no son de autenticación**: habilitan APIs, crean la regla de firewall de IAP, arrancan o listan VMs. Se conservan —el roadmap ya lo decidió, y con la escotilla viva siguen siendo accionables— pero ofrecerle a un usuario sin gcloud una única salida que pasa por gcloud es dejarlo sin salida.

Cada uno gana, en su campo `details`, la ruta equivalente en la consola. Si `details` ya tiene texto, **añade** la línea; no lo sustituyas.

- [ ] **Step 1: Escribe el test que falla**

Al `mod tests` de `native/src/doctor.rs`:

```rust
    /// El remedio de administración se CONSERVA y se le AÑADE la alternativa.
    /// Sustituirlo le quitaría la buena salida a quien sí tiene gcloud.
    #[test]
    fn the_console_alternative_is_added_not_substituted() {
        let d = with_console_alternative(
            Some("The VM is not running.".to_string()),
            "https://console.cloud.google.com/compute/instances",
        );
        let d = d.unwrap();
        assert!(d.contains("The VM is not running."));
        assert!(d.contains("https://console.cloud.google.com/compute/instances"));
    }

    /// Y cuando no había detalles, la alternativa los crea: si devolviera None
    /// el usuario sin gcloud se quedaría sin ninguna salida, que es justo lo
    /// que esta tarea existe para evitar.
    #[test]
    fn a_remedy_without_details_still_offers_the_console() {
        let d = with_console_alternative(None, "https://console.cloud.google.com/compute/instances");
        assert!(d.unwrap().contains("console.cloud.google.com"));
    }
```

- [ ] **Step 2: Ejecútalos y comprueba que fallan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib doctor::
```

Esperado: FALLO de compilación — `cannot find function with_console_alternative`.

- [ ] **Step 3: Implementa el ayudante**

A nivel de módulo en `doctor.rs`:

```rust
/// Append the Cloud Console route to a remedy's details.
///
/// The gcloud command stays: enabling an API or opening the IAP firewall is
/// still done with gcloud or the console, whatever auth engine the user runs.
/// What must not happen is the only offered way out being the tool this
/// release stopped needing.
fn with_console_alternative(details: Option<String>, console_url: &str) -> Option<String> {
    Some(match details {
        Some(existing) => format!("{}\n\nWithout gcloud: {}", existing, console_url),
        None => format!("Without gcloud: {}", console_url),
    })
}
```

- [ ] **Step 4: Úsalo en los seis remedios**

En cada uno, envuelve el `details` que ya tuviera:

| Línea | Comando que se conserva | URL de consola |
|---|---|---|
| `:396` | `gcloud projects list` | `https://console.cloud.google.com/cloud-resource-manager` |
| `:437` | `gcloud services enable compute.googleapis.com` | `https://console.cloud.google.com/apis/library/compute.googleapis.com` |
| `:451` | `gcloud services enable iap.googleapis.com` | `https://console.cloud.google.com/apis/library/iap.googleapis.com` |
| `:656` | la regla de firewall de IAP | `https://console.cloud.google.com/networking/firewalls/list` |
| `:770` | `gcloud compute instances start …` | `https://console.cloud.google.com/compute/instances` |
| `:810` | `gcloud compute instances list …` | `https://console.cloud.google.com/compute/instances` |

El patrón en el sitio de uso:

```rust
                details: with_console_alternative(
                    Some("The VM is not running.".to_string()),
                    "https://console.cloud.google.com/compute/instances",
                ),
```

y donde `details` era `None`, pásale `None` como primer argumento.

**Ninguno de los seis pierde su `fix_command`.** Si al terminar algún `fix_command` con `gcloud` ha desaparecido, lo has sustituido en vez de añadirle la alternativa.

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
grep -c "with_console_alternative" native/src/doctor.rs
```

Esperado: PASS, cero warnings, y el `grep` contando **siete** apariciones: la definición y los seis usos.

- [ ] **Step 6: Verifica la prueba negativa**

Haz que `with_console_alternative` devuelva `details` sin tocar —el defecto que la tarea evita— y ejecuta `cargo test --lib doctor::`. Esperado: fallan los dos tests nuevos. **Revierte** y dilo en el informe.

- [ ] **Step 7: Commit**

```bash
git add native/src/doctor.rs
git commit -m "feat(doctor): que el remedio no sea la herramienta que no tienes

Los comandos de administración se conservan: habilitar una API o abrir el
firewall de IAP se sigue haciendo con gcloud o con la consola, tenga el
usuario el motor que tenga. Lo que no puede pasar es que la única salida
ofrecida sea la herramienta que este release dejó de necesitar."
```

---

### Task 9: La documentación deja de describir otra aplicación

**Files:**
- Modify: `README.md`, `README.es.md`, `SECURITY.md`, `docs/THREAT_MODEL.md`, `docs/SSOT.md`, `scripts/setup_environment.sh`

**Contexto que necesitas:** `README.md:144` lista *"Google Cloud SDK (`gcloud`): installed and on the PATH"* como **requisito número 1**, y `:200` explica el login con `gcloud auth application-default login`. Hoy eso es falso: LCC inicia sesión por su cuenta desde D5. Es el primer documento que lee quien se encuentra el proyecto, y LCC se distribuye como software libre.

`scripts/setup_environment.sh:101` instala gcloud como paso obligatorio 4/9. Si el README dice "opcional" y el script lo instala siempre, se contradicen — y el script es lo que ejecuta quien clona el repo por primera vez.

`scripts/setup_macos.sh` queda **fuera**: el release de macOS está diferido.

- [ ] **Step 1: Los dos README**

En `README.md` y `README.es.md`, con el mismo contenido en ambos idiomas:

1. **Requisitos:** `gcloud` sale de la lista de requisitos y pasa a una sección de **opcionales**, con una frase que diga para qué sirve todavía: es el motor de auth alternativo (seleccionable en Ajustes) y la herramienta de los comandos de administración que Doctor sugiere.
2. **Autenticación:** el flujo descrito pasa a ser el nativo — LCC abre el navegador y mantiene su propia sesión —, con el motor gcloud mencionado como alternativa.
3. **Doctor:** la sección que hoy dice "verifies gcloud CLI, active account, and ADC credentials" pasa a describir las filas que hay de verdad: las nativas —llavero, índice de cuentas, sesión— y las de gcloud, que se saltan bajo el motor nativo.
4. **Dual API:** revisa si sigue siendo cierta tras SG-A; si describe una elección que ya no existe, dilo en el informe en vez de inventar texto.
5. **Túnel nativo:** `README.md:34` dice "with automatic fallback to the `gcloud` engine if the native path fails". Eso es **falso desde SG-B**: no hay fallback silencioso, un fallo nativo se reporta como error. Corrígelo.

- [ ] **Step 2: Pasada de coherencia por los otros tres**

En `SECURITY.md`, `docs/THREAT_MODEL.md` y `docs/SSOT.md`, corrige toda afirmación que presente gcloud como requerido o como la única vía de autenticación. **No reescribas** esos documentos: son de seguridad, y una pasada de estilo en un modelo de amenazas es una forma de introducir errores. Cambia lo que es falso y deja lo demás.

- [ ] **Step 3: El script de entorno**

En `scripts/setup_environment.sh`, el paso de gcloud pasa de obligatorio a opcional: pregunta o se salta por defecto, y el texto explica que LCC ya no lo necesita para iniciar sesión y que sirve como motor alternativo. Renumera los pasos (`4/9`, `5/9`…) si el paso deja de ser incondicional, para que la cuenta no mienta. Y `:180`, que hoy imprime `gcloud auth application-default login` como instrucción final, pasa a decir que se inicia sesión desde la propia aplicación.

- [ ] **Step 4: Verifica**

```bash
cd /home/jlopezre/GitHub/LCC && bash -n scripts/setup_environment.sh
grep -rn -i "requiere gcloud\|requires gcloud\|gcloud.*required" README.md README.es.md
```

Esperado: `bash -n` sin errores de sintaxis, y el `grep` sin ninguna afirmación de que gcloud sea obligatorio.

- [ ] **Step 5: Commit**

```bash
git add README.md README.es.md SECURITY.md docs/THREAT_MODEL.md docs/SSOT.md scripts/setup_environment.sh
git commit -m "docs: gcloud pasa de requisito a opcional

El README listaba el SDK de Google Cloud como requisito número 1 y explicaba
el login con 'gcloud auth application-default login'. Las dos cosas dejaron de
ser ciertas en D5, y es el primer documento que lee quien se encuentra el
proyecto.

También caía el 'automatic fallback to the gcloud engine', que es falso desde
SG-B: un fallo del túnel nativo se reporta, no se tapa.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Checklist de QA manual

**Files:**
- Create: `docs/superpowers/plans/2026-08-25-sge-cleanup-manual-qa.md`

**Contexto que necesitas:** el criterio de corte de SG-E tiene cuatro partes y ninguna es opcional. El entorno hostil se monta con **`bwrap`, no con `chmod`**: la receta de `chmod` produjo dos falsos verdes en el QA de D4. Y hay que enmascarar **`$HOME/google-cloud-sdk` además** del SDK del sistema, porque `gcloud_bin::resolve()` lo prueba **primero**.

- [ ] **Step 1: Escribe el documento**

Crea `docs/superpowers/plans/2026-08-25-sge-cleanup-manual-qa.md` con estos ítems, cada uno nombrando su evidencia:

1. **Doctor entero en verde sin gcloud.** Sandbox de `bwrap` con `$HOME/google-cloud-sdk`, el SDK del sistema y `~/.config/gcloud` enmascarados, motor nativo. Evidencia: **ninguna fila en rojo**; las tres de gcloud en `SKIP` con su motivo; las tres nativas en verde; y `/proc/$P/root/usr/bin/gcloud` inexistente sobre el PID **sandboxeado** —el que tiene distinto `/proc/$P/ns/mnt` que la shell—.
2. **Doctor con el motor gcloud.** Evidencia: las filas de gcloud vuelven a `Pass`/`Fail` y las tres nativas pasan a `SKIP`. Es la mitad que evita que la escotilla se pudra.
3. **El llavero caído se ve.** Sesión sin Secret Service. Evidencia: la fila del almacén en rojo con su mensaje, y **no** un Doctor entero en verde. Éste es el ítem que D2 no tuvo.
4. **Ninguna cuenta ≠ token roto.** Con el almacén vacío. Evidencia: la fila de sesión dice "no account is signed in", en amarillo, no un fallo de refresco en rojo.
5. **Los tres selectores surten efecto sin reiniciar.** Cambia cada uno en Ajustes y ejercítalo. Evidencia **por log**: `engine="gcloud"` en la línea de túnel establecido tras cambiar el de túnel, y lo propio con el reenvío. La UI **no** sirve como evidencia: dos rutas que dan el mismo resultado en pantalla no se distinguen mirando la pantalla, y así se dieron por buenas tres pruebas que iban por la ruta equivocada.
6. **Escribir una ranura no borra las otras.** Cambia el motor de túnel y luego el de auth; abre `engine.json`. Evidencia: las tres claves presentes con los valores esperados.
7. **El entorno sigue mandando en las tres.** Lanza con `LCC_TUNNEL_ENGINE=gcloud` teniendo `native` en el fichero. Evidencia: el bloque Avanzado avisa de la anulación y nombra el motor en vigor; el log confirma cuál se usó.
8. **Un remedio de administración ofrece salida sin gcloud.** Provoca una fila de administración en rojo. Evidencia: sus detalles llevan la ruta de la consola.
9. **El README no afirma nada que la app no haga.** Evidencia: leerlo entero de arriba abajo.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-25-sge-cleanup-manual-qa.md
git commit -m "docs(qa): checklist de QA manual de SG-E

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Cierre

1. `cd native && cargo test --lib` verde y `cargo build --lib` sin warnings.
2. `flutter analyze` con cero líneas `error •`; `flutter test` en verde.
3. `grep -rn 'authEngine()\|storedAuthEngine()\|setAuthEngine(\|authEngineOverride()' lib/ --include="*.dart"` da **cero**, incluido el bridge generado.
4. `grep -rn 'LCC_TUNNEL_ENGINE\|LCC_SSH_FORWARD_ENGINE' native/src` solo aparece dentro de `engine_pref.rs`.
5. Subir `kBuild` en `lib/src/version.dart`, `cargo build --release` y `flutter build linux --release`.
6. Revisión final de todo el rango del plan.

El **criterio de corte** son los ítems 1, 2, 3 y 5 del checklist. Los cuatro: el 1 prueba que Doctor ya no castiga a quien no tiene gcloud, el 2 que la escotilla sigue diagnosticándose, el 3 que Doctor detecta el fallo que D2 no detectó, y el 5 que los selectores nuevos no son decorativos.

---

### Task 11: Doctor deja de saltarse media sesión bajo el motor nativo

**Files:**
- Modify: `native/src/doctor.rs` (la verja `can_run_api_checks` y su rama de salto)
- Test: `native/src/doctor.rs`

**Interfaces:**
- Consumes de la tarea 7: la fila `auth_native_token` (`check_native_token`), que ya dice si LCC puede acuñar un token **ahora**.

**Contexto que necesitas, y es todo el motivo de la tarea:**

```rust
let gcloud_authenticated = checks.iter()
    .find(|c| c.check_id == "auth_gcloud_account")
    .map(|c| c.status == DoctorCheckStatus::Pass)
    .unwrap_or(false);
let can_run_api_checks = has_auth && gcloud_authenticated;
```

Bajo el motor nativo, la fila `auth_gcloud_account` sale en **`Skipped`** desde D5 —
nunca en `Pass`—, así que `can_run_api_checks` es **siempre falso** y las **seis**
comprobaciones de proyecto, IAP y VM se saltan con `"Skipped: gcloud not
authenticated"`. En una instalación por defecto, la mitad útil de Doctor no se
ejecuta, y lleva así desde D5.

Es el mismo patrón que esta iniciativa persigue desde D2: un panel que se ve
verde y en realidad no corrió lo que importaba. La pregunta correcta no es "¿está
gcloud autenticado?" sino **"¿podemos obtener un token?"** — y esa señal la
construyó la tarea 7.

- [ ] **Step 1: Escribe los tests que fallan**

Al `mod tests` de `native/src/doctor.rs`:

```rust
    /// El defecto que esta tarea arregla. Bajo el motor nativo la fila de
    /// gcloud es Skipped, así que una verja que exija su Pass apaga las seis
    /// comprobaciones de API en una instalación perfecta.
    #[test]
    fn the_native_engine_can_run_the_api_checks() {
        let rows = vec![
            row("auth_gcloud_account", DoctorCheckStatus::Skipped),
            row("auth_native_token", DoctorCheckStatus::Pass),
        ];
        assert!(credentials_usable(&rows));
    }

    /// Bajo el motor gcloud manda su fila, como siempre.
    #[test]
    fn the_gcloud_engine_still_gates_on_its_own_row() {
        let rows = vec![
            row("auth_gcloud_account", DoctorCheckStatus::Pass),
            row("auth_native_token", DoctorCheckStatus::Skipped),
        ];
        assert!(credentials_usable(&rows));
    }

    /// Y si NINGUNA de las dos pasa, no hay con qué llamar a la API: saltar es
    /// correcto. Lo que no vale es saltar cuando sí había credenciales.
    #[test]
    fn no_usable_credentials_still_skips() {
        let rows = vec![
            row("auth_gcloud_account", DoctorCheckStatus::Skipped),
            row("auth_native_token", DoctorCheckStatus::Fail),
        ];
        assert!(!credentials_usable(&rows));
    }
```

Añade también el ayudante `row(id, status)` al `mod tests` si no existe uno
equivalente: construye un `DoctorCheckResult` con ese `check_id` y ese `status` y
el resto de campos vacíos.

- [ ] **Step 2: Ejecuta y comprueba que fallan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib doctor::
```

Esperado: FALLO de compilación — `cannot find function credentials_usable`.

- [ ] **Step 3: Implementa**

A nivel de módulo en `doctor.rs`:

```rust
/// Whether anything on this machine can serve an access token, whichever
/// engine is in use.
///
/// The API checks used to gate on gcloud's row passing. Under the native
/// engine that row is `Skipped` and never `Pass`, so the six project, IAP and
/// VM checks silently did not run on a default install — a Doctor that looks
/// green because it asked nothing. Either auth row passing is enough.
fn credentials_usable(checks: &[DoctorCheckResult]) -> bool {
    checks.iter().any(|c| {
        matches!(c.check_id.as_str(), "auth_gcloud_account" | "auth_native_token")
            && c.status == DoctorCheckStatus::Pass
    })
}
```

Y sustituye la verja:

```rust
        let can_run_api_checks = has_auth && credentials_usable(&checks);
```

El mensaje de salto también miente: dice `"Skipped: gcloud not authenticated"`
cuando el motivo puede no tener nada que ver con gcloud. Cámbialo por
`"Skipped: no usable credentials"` cuando `has_auth` es cierto pero ninguna fila
de auth pasó, y deja el de `!has_auth` como está.

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd /home/jlopezre/GitHub/LCC/native && cargo test --lib && cargo build --lib
```

Esperado: PASS y cero warnings.

- [ ] **Step 5: Verifica la prueba negativa**

Devuelve `credentials_usable` a exigir solo `auth_gcloud_account`, ejecuta
`cargo test --lib doctor::`. Esperado: falla `the_native_engine_can_run_the_api_checks`.
**Revierte** y dilo en el informe.

- [ ] **Step 6: Commit**

```bash
git add native/src/doctor.rs
git commit -m "fix(doctor): las comprobaciones de API dejan de depender de gcloud

La verja exigía que la fila de la cuenta de gcloud pasara. Bajo el motor
nativo esa fila es Skipped y nunca Pass, así que en una instalación por
defecto las seis comprobaciones de proyecto, IAP y VM no se ejecutaban y
el panel se veía verde por no haber preguntado nada.

La pregunta correcta es si alguna credencial puede servir un token, no si
gcloud está autenticado."
```

---
