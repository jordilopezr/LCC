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

impl Engine {
    /// The engine's name, as the environment variables and the stored file
    /// spell it. The one place that writes this vocabulary; `parse_engine`
    /// is the one that reads it.
    pub fn as_str(self) -> &'static str {
        match self {
            Engine::Native => "native",
            Engine::Gcloud => "gcloud",
        }
    }
}

/// Which level of the precedence rule decided an engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineSource {
    /// The slot's environment variable.
    Env,
    /// The stored preference in [`PREF_FILE`].
    File,
    /// Neither level named an engine.
    Default,
}

/// An engine together with how it was chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resolved {
    pub engine: Engine,
    pub source: EngineSource,
    /// The environment variable is set but names no engine, so it was passed
    /// over. It has no effect, which is exactly why it has to be reported:
    /// whoever set it believes they forced an engine.
    pub env_ignored: bool,
}

/// The file the engine preferences live in, inside the app's data directory.
pub const PREF_FILE: &str = "engine.json";

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
    /// Every slot, for whatever has to report on all of them.
    pub const ALL: [EngineSlot; 3] = [EngineSlot::Auth, EngineSlot::Tunnel, EngineSlot::SshForward];

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
    Some(crate::app_dirs::migrated_app_dir(dirs::data_local_dir()?).join(PREF_FILE))
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
    resolve_with_source(env, file).engine
}

/// [`resolve`], keeping track of which level decided. This is the rule;
/// `resolve` only drops the bookkeeping, so the engine in use and the origin
/// the log reports cannot disagree.
pub(crate) fn resolve_with_source(env: Option<&str>, file: Option<&str>) -> Resolved {
    let from_env = env.and_then(parse_engine);
    let (engine, source) = match (from_env, file.and_then(parse_engine)) {
        (Some(engine), _) => (engine, EngineSource::Env),
        (None, Some(engine)) => (engine, EngineSource::File),
        (None, None) => (Engine::Native, EngineSource::Default),
    };
    Resolved { engine, source, env_ignored: env.is_some() && from_env.is_none() }
}

/// An engine name, or None when the value names no engine we know.
fn parse_engine(value: &str) -> Option<Engine> {
    match value {
        "native" => Some(Engine::Native),
        "gcloud" => Some(Engine::Gcloud),
        _ => None,
    }
}

/// What `slot` is resolved from right now: its environment variable, then its
/// stored preference.
fn inputs(slot: EngineSlot) -> (Option<String>, Option<String>) {
    let env = std::env::var(slot.env_var()).ok();
    (env, stored(slot))
}

/// The engine actually in force for `slot`.
pub fn engine_for(slot: EngineSlot) -> Engine {
    let (env, file) = inputs(slot);
    resolve(env.as_deref(), file.as_deref())
}

/// The engine in force for `slot`, and which level chose it.
pub fn engine_with_source(slot: EngineSlot) -> Resolved {
    let (env, file) = inputs(slot);
    resolve_with_source(env.as_deref(), file.as_deref())
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

/// The temp file `set_stored` writes to before renaming it into place.
///
/// Named per slot: two `set_stored` calls for different slots can be in
/// flight at once (Settings can expose three selectors), and a shared temp
/// name would let one call's `rename` publish the other call's half-applied
/// write with no error anywhere.
fn tmp_path(path: &std::path::Path, slot: EngineSlot) -> PathBuf {
    path.with_extension(format!("{}.tmp", slot.key()))
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
    let tmp = tmp_path(&path, slot);
    std::fs::write(&tmp, json).context("Failed to write the engine preferences")?;
    std::fs::rename(&tmp, &path).context("Failed to replace the engine preferences")?;
    tracing::info!(slot = slot.key(), engine, "Stored an engine preference");
    Ok(())
}

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

    /// Two `set_stored` calls for different slots can be in flight at once
    /// once Settings exposes three selectors. A shared temp file name would
    /// let one call's rename publish the other call's write with no error
    /// anywhere, so each slot must land on its own temp path.
    #[test]
    fn each_slot_writes_to_its_own_temp_file() {
        let path = PathBuf::from("/tmp/engine.json");
        let auth = tmp_path(&path, EngineSlot::Auth);
        let tunnel = tmp_path(&path, EngineSlot::Tunnel);
        let ssh_forward = tmp_path(&path, EngineSlot::SshForward);
        assert_ne!(auth, tunnel);
        assert_ne!(auth, ssh_forward);
        assert_ne!(tunnel, ssh_forward);
    }

    /// El log de arranque dice de dónde sale cada motor. Si el origen se
    /// equivoca, el log manda a mirar el fichero cuando la culpa es de una
    /// variable de entorno olvidada, que es justo lo que venía a destapar.
    #[test]
    fn the_source_names_what_decided() {
        let default = resolve_with_source(None, None);
        assert_eq!((default.engine, default.source), (Engine::Native, EngineSource::Default));
        let file = resolve_with_source(None, Some("gcloud"));
        assert_eq!((file.engine, file.source), (Engine::Gcloud, EngineSource::File));
        let env = resolve_with_source(Some("gcloud"), Some("native"));
        assert_eq!((env.engine, env.source), (Engine::Gcloud, EngineSource::Env));
    }

    /// Un valor que no se entiende no decide, así que tampoco puede figurar
    /// como origen: el origen es el nivel que de verdad eligió el motor.
    #[test]
    fn rubbish_is_never_named_as_the_source() {
        let over_file = resolve_with_source(Some("wat"), Some("gcloud"));
        assert_eq!((over_file.engine, over_file.source), (Engine::Gcloud, EngineSource::File));
        let alone = resolve_with_source(Some("wat"), None);
        assert_eq!((alone.engine, alone.source), (Engine::Native, EngineSource::Default));
        let bad_file = resolve_with_source(None, Some("wat"));
        assert_eq!((bad_file.engine, bad_file.source), (Engine::Native, EngineSource::Default));
    }

    /// Una variable mal escrita ("gcluod") no tiene efecto y no deja rastro:
    /// quien la puso cree haber forzado un motor. Ignorarla está bien; que
    /// nadie se entere, no.
    #[test]
    fn an_environment_value_that_names_no_engine_is_reported_as_ignored() {
        assert!(resolve_with_source(Some("gcluod"), Some("gcloud")).env_ignored);
        assert!(resolve_with_source(Some("gcluod"), None).env_ignored);
        assert!(!resolve_with_source(Some("gcloud"), None).env_ignored);
        assert!(!resolve_with_source(None, Some("gcluod")).env_ignored);
        assert!(!resolve_with_source(None, None).env_ignored);
    }

    /// El log escribe con `as_str` y la variable de entorno se lee con
    /// `parse_engine`: tienen que hablar el mismo idioma, o el log diría un
    /// nombre que al escribirlo en la variable no funciona.
    #[test]
    fn an_engine_name_reads_back_as_the_same_engine() {
        for engine in [Engine::Native, Engine::Gcloud] {
            assert_eq!(parse_engine(engine.as_str()), Some(engine));
        }
        assert_eq!(Engine::Native.as_str(), "native");
        assert_eq!(Engine::Gcloud.as_str(), "gcloud");
    }

    /// El log de arranque recorre `ALL`. Una ranura que faltara ahí
    /// desaparecería del log sin que nada fallase.
    #[test]
    fn all_lists_every_slot_once() {
        assert_eq!(EngineSlot::ALL.map(EngineSlot::key), ["auth", "tunnel", "ssh_forward"]);
    }
}
