# SG-D / D2: almacén de tokens en el keyring — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persistir el `refresh_token` de cada cuenta en el keyring del sistema, con un índice en disco que solo guarda emails, para que la sesión sobreviva al cierre de la app.

**Architecture:** Un módulo nuevo `native/src/token_store.rs`. El secreto va al keyring (`keyring::Entry`, clave `oauth::<email>`); un JSON aparte (`oauth_accounts.json`) lista las cuentas y marca la activa, porque la API del keyring no enumera. La lógica del índice son **funciones puras** sobre un valor `AccountIndex`, con capas finas de E/S encima — así se testea de verdad sin disco ni keyring.

**Tech Stack:** Rust, `keyring` v3, `serde_json`, `anyhow`, `chrono`, `dirs` (todas ya en `Cargo.toml`).

**Spec:** `docs/superpowers/specs/2026-08-13-sgd-d2-token-store-design.md`

## Global Constraints

- **Solo Rust**, y solo estos ficheros: `native/src/lib.rs`, `native/src/token_store.rs`, más un doc de QA. No Dart, no regen del bridge, no `dart format`.
- **Cero dependencias nuevas.** `keyring`, `serde`, `serde_json`, `anyhow`, `chrono`, `dirs` y `tracing` ya están.
- **El secreto solo vive en el keyring.** El fichero índice contiene **únicamente** emails y cuál es la activa. Ningún camino escribe un `refresh_token` en disco.
- **Sin keyring disponible → error claro y accionable**, nunca un fallback a fichero en claro. El mensaje debe distinguirse de "no hay cuenta guardada".
- **El access token NO se persiste** — dura ~1 h y se re-deriva; `gcp_rest_client` ya lo cachea en memoria.
- `Result` es **`anyhow::Result`** (como en `oauth.rs`), no el `Result<_, String>` del módulo de credenciales de Windows.
- **Primera cuenta = cuenta activa:** `save_account` marca la cuenta como activa **solo si no había ninguna**; guardar otra cuando ya hay activa **no** la desplaza.
- Servicio del keyring: `SERVICE_NAME = "linux-cloud-connector"` (el que ya usa el repo), con prefijo de clave `oauth::` para no colisionar con las credenciales de Windows.
- Mensajes de error **en inglés** (capa Rust; se localizarán cuando D4 los exponga por el bridge).
- **Prohibido `#[allow(dead_code)]`** o silenciar lints.
- Verificar: `cargo test` verde, `cargo build --release` sin warnings nuevos, `flutter test` intacto.
- **Commits de código NO llevan trailer `Co-Authored-By`** (solo docs). Rama `27H1-Preview`.

---

### Task 1: Núcleo puro del índice (TDD)

Solo lógica en memoria: el tipo del índice, la clave del keyring y las tres operaciones. Nada de E/S ni de keyring todavía — así los tests son reales y el módulo no emite warnings de código sin usar.

**Files:**
- Modify: `native/src/lib.rs` (declarar el módulo)
- Create: `native/src/token_store.rs`

**Interfaces:**
- Produce (lo que consume la Task 2): `struct StoredAccount { pub email: String, pub refresh_token: String, pub added_at: String }`; `struct AccountIndex { accounts: Vec<String>, active: Option<String> }` (privado); `fn keyring_key(email: &str) -> String`; `fn index_upsert(&mut AccountIndex, &str)`; `fn index_remove(&mut AccountIndex, &str)`; `fn index_set_active(&mut AccountIndex, &str) -> anyhow::Result<()>`.

- [ ] **Step 1: Declarar el módulo**

En `native/src/lib.rs`, junto a las demás declaraciones (p. ej. tras `pub mod oauth;` si existe, o tras `pub mod tunnel;`), añadir:

```rust
pub mod token_store;  // 27H1 SG-D/D2: refresh tokens in the OS keyring
```

- [ ] **Step 2: Crear el fichero solo con los tests (RED)**

Crear `native/src/token_store.rs` con **únicamente** la cabecera y el módulo de tests:

```rust
//! Secure storage for OAuth refresh tokens, one entry per Google account.
//!
//! The secret itself lives in the OS keyring (GNOME Keyring / KWallet on Linux,
//! Keychain on macOS, Credential Manager on Windows). The keyring API cannot
//! enumerate its own entries, so a separate JSON index on disk tracks which
//! accounts exist and which one is active — it holds e-mail addresses only and
//! never a secret.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyring_key_is_namespaced() {
        assert_eq!(keyring_key("a@b.com"), "oauth::a@b.com");
    }

    #[test]
    fn upsert_is_idempotent() {
        let mut index = AccountIndex::default();
        index_upsert(&mut index, "a@b.com");
        index_upsert(&mut index, "a@b.com");
        assert_eq!(index.accounts, vec!["a@b.com".to_string()]);
    }

    #[test]
    fn first_account_becomes_active_later_ones_do_not() {
        let mut index = AccountIndex::default();
        index_upsert(&mut index, "first@b.com");
        assert_eq!(index.active.as_deref(), Some("first@b.com"));
        index_upsert(&mut index, "second@b.com");
        assert_eq!(index.active.as_deref(), Some("first@b.com"));
        assert_eq!(index.accounts.len(), 2);
    }

    #[test]
    fn remove_clears_active_only_when_it_pointed_there() {
        let mut index = AccountIndex::default();
        index_upsert(&mut index, "a@b.com");
        index_upsert(&mut index, "c@d.com");
        // active is a@b.com; removing the other one must leave it alone
        index_remove(&mut index, "c@d.com");
        assert_eq!(index.active.as_deref(), Some("a@b.com"));
        assert_eq!(index.accounts, vec!["a@b.com".to_string()]);
        // removing the active one clears it
        index_remove(&mut index, "a@b.com");
        assert!(index.active.is_none());
        assert!(index.accounts.is_empty());
    }

    #[test]
    fn set_active_requires_a_known_account() {
        let mut index = AccountIndex::default();
        index_upsert(&mut index, "a@b.com");
        index_upsert(&mut index, "c@d.com");
        index_set_active(&mut index, "c@d.com").expect("known account");
        assert_eq!(index.active.as_deref(), Some("c@d.com"));
        assert!(index_set_active(&mut index, "nobody@x.com").is_err());
        // the failed call left the previous choice intact
        assert_eq!(index.active.as_deref(), Some("c@d.com"));
    }

    #[test]
    fn index_round_trips_through_json() {
        let mut index = AccountIndex::default();
        index_upsert(&mut index, "a@b.com");
        let json = serde_json::to_string(&index).expect("serialize");
        let back: AccountIndex = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(index, back);

        let empty = AccountIndex::default();
        let json = serde_json::to_string(&empty).expect("serialize empty");
        let back: AccountIndex = serde_json::from_str(&json).expect("deserialize empty");
        assert_eq!(empty, back);
        assert!(back.active.is_none());
    }

    /// The central security property of this module: what lands on disk must
    /// never carry the secret.
    #[test]
    fn serialized_index_contains_no_secret() {
        const SECRET: &str = "1//0gSECRET-REFRESH-TOKEN-VALUE";
        let account = StoredAccount {
            email: "a@b.com".to_string(),
            refresh_token: SECRET.to_string(),
            added_at: "2026-08-13T00:00:00Z".to_string(),
        };
        let mut index = AccountIndex::default();
        index_upsert(&mut index, &account.email);
        let json = serde_json::to_string(&index).expect("serialize");
        assert!(
            !json.contains(SECRET),
            "the on-disk index leaked the refresh token: {}",
            json
        );
        assert!(json.contains("a@b.com"));
    }

    #[test]
    fn stored_account_round_trips_through_json() {
        let account = StoredAccount {
            email: "a@b.com".to_string(),
            refresh_token: "refresh-value".to_string(),
            added_at: "2026-08-13T00:00:00Z".to_string(),
        };
        let json = serde_json::to_string(&account).expect("serialize");
        let back: StoredAccount = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.email, account.email);
        assert_eq!(back.refresh_token, account.refresh_token);
        assert_eq!(back.added_at, account.added_at);
    }
}
```

- [ ] **Step 3: Verificar que falla (no compila)**

Run: `cd native && cargo test token_store 2>&1 | tail -20`
Expected: errores de compilación — `cannot find type \`AccountIndex\``, `cannot find function \`keyring_key\``, etc. Ese es el RED del ciclo TDD.

- [ ] **Step 4: Implementar el núcleo puro (GREEN)**

En `native/src/token_store.rs`, **encima** del módulo de tests, añadir:

```rust
use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

/// What is stored in the keyring for one account. `refresh_token` is a secret
/// and must never be written anywhere but the keyring.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredAccount {
    pub email: String,
    pub refresh_token: String,
    /// RFC 3339, for FFI consistency with the rest of the repo.
    pub added_at: String,
}

/// The on-disk index. E-mail addresses only — never a secret.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
struct AccountIndex {
    accounts: Vec<String>,
    active: Option<String>,
}

/// Keyring entry name. The `oauth::` prefix keeps these from colliding with the
/// Windows-credential entries, which share the same keyring service.
fn keyring_key(email: &str) -> String {
    format!("oauth::{}", email)
}

/// Add `email` if absent. Idempotent. The first account added becomes the
/// active one; later accounts never displace an existing choice.
fn index_upsert(index: &mut AccountIndex, email: &str) {
    if !index.accounts.iter().any(|a| a == email) {
        index.accounts.push(email.to_string());
    }
    if index.active.is_none() {
        index.active = Some(email.to_string());
    }
}

/// Remove `email`, clearing `active` if it pointed at that account.
fn index_remove(index: &mut AccountIndex, email: &str) {
    index.accounts.retain(|a| a != email);
    if index.active.as_deref() == Some(email) {
        index.active = None;
    }
}

/// Point `active` at `email`. Errors if it is not a known account, leaving the
/// previous choice untouched.
fn index_set_active(index: &mut AccountIndex, email: &str) -> Result<()> {
    if !index.accounts.iter().any(|a| a == email) {
        return Err(anyhow!("No stored session for {}", email));
    }
    index.active = Some(email.to_string());
    Ok(())
}
```

- [ ] **Step 5: Verificar que pasan**

Run: `cd native && cargo test token_store 2>&1 | tail -20`
Expected: los 8 tests pasan.

- [ ] **Step 6: Suite Rust completa**

Run: `cd native && cargo test 2>&1 | tail -8`
Expected: toda la suite verde.

**Nota sobre warnings — esperados en esta tarea, NO los silencies.** `keyring_key`, `index_upsert`, `index_remove` e `index_set_active` son privadas y en esta tarea solo las usan los tests, así que una compilación **sin** `cfg(test)` (p. ej. `cargo build --release`) avisará de que no se usan. Es correcto y transitorio: la Task 2 las consume desde la API pública y el aviso desaparece solo. **No** añadas `#[allow(dead_code)]` ni ningún silenciador; el listón de esta tarea es `cargo test` en verde. (`StoredAccount` es `pub`, así que no avisa.)

- [ ] **Step 7: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/lib.rs native/src/token_store.rs
git commit -m "feat(token-store): pure account-index core with keyring key naming"
```

---

### Task 2: Capa de keyring y E/S + API pública

Añade lo que toca el mundo exterior: el fichero índice, las entradas del keyring y las seis funciones públicas que consumirán D3 y D4.

**Files:**
- Modify: `native/src/token_store.rs`

**Interfaces:**
- Consume (de la Task 1): `StoredAccount`, `AccountIndex`, `keyring_key`, `index_upsert`, `index_remove`, `index_set_active`.
- Consume (del crate): `crate::app_dirs::migrated_app_dir(base: PathBuf) -> PathBuf`.
- Produce: `pub fn save_account(&str, &str) -> Result<()>`, `pub fn load_refresh_token(&str) -> Result<String>`, `pub fn list_accounts() -> Vec<String>`, `pub fn delete_account(&str) -> Result<()>`, `pub fn active_account() -> Option<String>`, `pub fn set_active_account(&str) -> Result<()>`.

- [ ] **Step 1: Ampliar los imports y añadir el servicio**

En `native/src/token_store.rs`, sustituir la línea de imports de la Task 1 por:

```rust
use anyhow::{anyhow, Context, Result};
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::{debug, info, warn};

/// The same keyring service the rest of the app uses.
const SERVICE_NAME: &str = "linux-cloud-connector";
```

- [ ] **Step 2: Añadir la capa de E/S del índice**

Debajo de `index_set_active`, añadir:

```rust
/// Path to the index that tracks stored accounts. It exists because the keyring
/// API cannot enumerate its own entries.
fn index_file_path() -> Option<PathBuf> {
    let mut path = crate::app_dirs::migrated_app_dir(dirs::data_local_dir()?);
    path.push("oauth_accounts.json");
    Some(path)
}

/// A missing or unreadable index reads as empty: the secrets in the keyring are
/// untouched, and the index rebuilds itself the next time an account is saved.
fn load_index() -> AccountIndex {
    let path = match index_file_path() {
        Some(p) => p,
        None => return AccountIndex::default(),
    };
    if !path.exists() {
        return AccountIndex::default();
    }
    match std::fs::read_to_string(&path) {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or_else(|e| {
            warn!("Account index is unreadable, treating it as empty: {}", e);
            AccountIndex::default()
        }),
        Err(e) => {
            warn!("Could not read the account index: {}", e);
            AccountIndex::default()
        }
    }
}

fn save_index(index: &AccountIndex) -> Result<()> {
    let path = index_file_path().ok_or_else(|| anyhow!("Cannot determine the data directory"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create the data directory")?;
    }
    let json = serde_json::to_string(index).context("Failed to serialize the account index")?;
    std::fs::write(&path, json).context("Failed to write the account index")?;
    Ok(())
}

/// Open the keyring entry for `email`. A missing backend becomes an actionable
/// error, distinct from "this account is not stored".
fn entry_for(email: &str) -> Result<Entry> {
    Entry::new(SERVICE_NAME, &keyring_key(email)).map_err(|e| {
        anyhow!(
            "The system keyring is unavailable, so the sign-in cannot be saved \
             and you would have to sign in again on every start. On Linux this \
             usually means no Secret Service (GNOME Keyring or KWallet) is \
             running: {}",
            e
        )
    })
}
```

- [ ] **Step 3: Añadir la API pública**

A continuación, añadir:

```rust
/// Store (or replace) the sign-in for `email`. The keyring is written first and
/// the index second; if the index write fails the keyring entry is rolled back,
/// so no secret is left behind that nothing lists.
pub fn save_account(email: &str, refresh_token: &str) -> Result<()> {
    let account = StoredAccount {
        email: email.to_string(),
        refresh_token: refresh_token.to_string(),
        added_at: chrono::Utc::now().to_rfc3339(),
    };
    let json = serde_json::to_string(&account).context("Failed to serialize the account")?;
    let entry = entry_for(email)?;
    entry
        .set_password(&json)
        .map_err(|e| anyhow!("Failed to store the sign-in in the system keyring: {}", e))?;

    let mut index = load_index();
    index_upsert(&mut index, email);
    if let Err(e) = save_index(&index) {
        let _ = entry.delete_credential();
        return Err(e.context("Rolled back the stored sign-in"));
    }
    info!("Stored the sign-in for {}", email);
    Ok(())
}

/// The refresh token for `email`, or an error explaining why there is none.
pub fn load_refresh_token(email: &str) -> Result<String> {
    let entry = entry_for(email)?;
    let json = match entry.get_password() {
        Ok(json) => json,
        Err(keyring::Error::NoEntry) => return Err(anyhow!("No stored session for {}", email)),
        Err(e) => {
            return Err(anyhow!(
                "Failed to read the sign-in from the system keyring: {}",
                e
            ))
        }
    };
    let account: StoredAccount =
        serde_json::from_str(&json).context("The stored sign-in is malformed")?;
    Ok(account.refresh_token)
}

/// Accounts that are listed *and* still present in the keyring. Entries whose
/// keyring record vanished are pruned on the way out, and an active account
/// that no longer exists is cleared.
pub fn list_accounts() -> Vec<String> {
    let mut index = load_index();
    let before = index.clone();
    index.accounts.retain(|email| {
        match Entry::new(SERVICE_NAME, &keyring_key(email)) {
            Ok(entry) => !matches!(entry.get_password(), Err(keyring::Error::NoEntry)),
            // Keyring unavailable: keep the list rather than erasing the user's
            // accounts just because a service is not running.
            Err(_) => true,
        }
    });
    if let Some(active) = index.active.clone() {
        if !index.accounts.contains(&active) {
            index.active = None;
        }
    }
    if index != before {
        debug!("Pruned accounts that are no longer in the keyring");
        let _ = save_index(&index);
    }
    index.accounts
}

/// Forget the sign-in for `email`. Deleting an account that is not stored is
/// not an error.
pub fn delete_account(email: &str) -> Result<()> {
    let entry = entry_for(email)?;
    match entry.delete_credential() {
        Ok(()) => {}
        Err(keyring::Error::NoEntry) => debug!("No stored sign-in to delete for {}", email),
        Err(e) => {
            return Err(anyhow!(
                "Failed to delete the sign-in from the system keyring: {}",
                e
            ))
        }
    }
    let mut index = load_index();
    index_remove(&mut index, email);
    save_index(&index)?;
    info!("Deleted the stored sign-in for {}", email);
    Ok(())
}

/// The account currently marked active, if any.
pub fn active_account() -> Option<String> {
    load_index().active
}

/// Mark `email` as the active account. Errors if it is not a stored account.
pub fn set_active_account(email: &str) -> Result<()> {
    let mut index = load_index();
    index_set_active(&mut index, email)?;
    save_index(&index)
}
```

- [ ] **Step 4: Añadir el test de round-trip real (ignorado por defecto)**

Dentro del módulo `mod tests`, al final, añadir — siguiendo el precedente de `native/src/windows_credentials/storage.rs`:

```rust
    /// Exercises the real keyring. Ignored by default because it needs a live
    /// Secret Service, and it mutates the real account index (it cleans up
    /// after itself).
    #[test]
    #[ignore] // Requires system keyring
    fn save_load_delete_round_trip() {
        let email = "d2-round-trip@example.test";
        save_account(email, "test-refresh-token").expect("save");
        assert_eq!(
            load_refresh_token(email).expect("load"),
            "test-refresh-token"
        );
        assert!(list_accounts().iter().any(|a| a == email));

        delete_account(email).expect("delete");
        assert!(load_refresh_token(email).is_err());
        assert!(!list_accounts().iter().any(|a| a == email));
    }
```

- [ ] **Step 5: Verificar compilación y tests**

Run: `cd native && cargo test token_store 2>&1 | tail -20`
Expected: los 8 tests puros pasan; el de round-trip aparece como `ignored`.

- [ ] **Step 6: Suite completa, release y Flutter**

Run: `cd native && cargo test 2>&1 | tail -8`
Expected: toda la suite Rust verde.

Run: `cd native && cargo build --release 2>&1 | tail -6`
Expected: compila **sin warnings nuevos**. En particular, los avisos de código sin usar que dejó la Task 1 (`keyring_key`, `index_upsert`, `index_remove`, `index_set_active`) deben haber desaparecido porque la API pública ya los consume. Si alguno persiste, resuélvelo **consumiéndolo**, nunca silenciándolo.

Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6`
Expected: suite Flutter verde (D2 no toca Dart).

- [ ] **Step 7: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/token_store.rs
git commit -m "feat(token-store): keyring-backed account storage with on-disk index"
```

---

### Task 3: Checklist de QA manual

Los tests puros cubren la lógica; esto verifica contra el keyring real lo que un test no puede aseverar solo.

**Files:**
- Create: `docs/superpowers/plans/2026-08-13-sgd-d2-token-store-manual-qa.md`

- [ ] **Step 1: Confirmar la verja**

Run: `cd native && cargo test 2>&1 | tail -6` — Expected: verde.
Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6` — Expected: verde.

- [ ] **Step 2: Escribir el checklist**

Crear `docs/superpowers/plans/2026-08-13-sgd-d2-token-store-manual-qa.md`:

```markdown
# QA manual — SG-D / D2: almacén de tokens

Los tests unitarios cubren la lógica del índice sin tocar disco ni keyring.
Esto verifica lo que solo se ve contra el keyring real.

Prerrequisito: sesión de escritorio con un Secret Service vivo (GNOME Keyring o KWallet).

- [ ] **Round-trip real**: `cd native && cargo test --lib token_store -- --ignored` pasa (guarda, lee, lista y borra contra el keyring del sistema).
- [ ] **El índice no contiene secretos**: tras el round-trip, `cat ~/.local/share/lightweight_cloud_connector/oauth_accounts.json` muestra solo emails y `active` — ninguna cadena que parezca un refresh token.
- [ ] **El secreto sí está en el keyring**: durante una ejecución que haya guardado una cuenta, `secret-tool search service linux-cloud-connector` (paquete `libsecret-tools`) lista una entrada cuyo nombre incluye `oauth::`. Tras el borrado del round-trip ya no aparece.
- [ ] **Sin keyring, error accionable**: en una sesión sin Secret Service — por ejemplo `env -u DBUS_SESSION_BUS_ADDRESS cargo test --lib token_store -- --ignored` — el test falla con un mensaje que menciona que la sesión no puede guardarse y que hace falta GNOME Keyring o KWallet, **no** con un genérico "no encontrado". Y el JSON del índice sigue sin secretos.
- [ ] **La cuenta activa sobrevive al reinicio**: el fichero índice conserva `active` entre ejecuciones (se comprueba leyendo el JSON antes y después).
```

- [ ] **Step 3: Commit** (docs)

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-13-sgd-d2-token-store-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SG-D/D2 token store"
```

---

## Self-Review

**1. Spec coverage:**
- Módulo `token_store.rs` + `pub mod` en lib.rs → Task 1 Steps 1-2. ✓
- `StoredAccount` (email + refresh_token + added_at), sin access token → Task 1 Step 4. ✓
- `AccountIndex` privado, solo emails + active → Task 1 Step 4. ✓
- Operaciones puras `index_upsert`/`index_remove`/`index_set_active` + `keyring_key` → Task 1 Step 4. ✓
- Regla "primera cuenta = activa" → Task 1 Step 4 (`index_upsert`) + test dedicado. ✓
- Las 6 funciones públicas con `anyhow::Result` → Task 2 Step 3. ✓
- Keyring `SERVICE_NAME` + prefijo `oauth::` → Task 1 (clave) + Task 2 Step 1 (servicio). ✓
- Índice en `app_dirs::migrated_app_dir` + `oauth_accounts.json` → Task 2 Step 2. ✓
- Orden keyring→índice con rollback → Task 2 Step 3 (`save_account`). ✓
- Auto-sanado del índice y limpieza de `active` huérfana → Task 2 Step 3 (`list_accounts`). ✓
- Tres errores distinguibles (keyring ausente / cuenta no guardada / índice corrupto) → Task 2 Steps 2-3 (`entry_for`, `NoEntry`, `load_index`). ✓
- Sin fallback a texto plano → no existe tal camino; reforzado en Global Constraints y en el checklist. ✓
- Tests puros incl. el de "índice sin secreto" → Task 1 Step 2. ✓
- `#[ignore]` de round-trip real → Task 2 Step 4. ✓
- Verificación cargo test + release + flutter + QA manual → Task 2 Step 6 + Task 3. ✓
- Cero dependencias nuevas → ninguna se añade. ✓

**2. Placeholder scan:** Sin TBD/TODO. Todo el código (tipos, funciones puras, capa de E/S, API pública, los 9 tests y el checklist) está escrito literalmente. ✓

**3. Type consistency:** `keyring_key`, `index_upsert`, `index_remove`, `index_set_active`, `AccountIndex`, `StoredAccount` se definen en la Task 1 y se usan con esos nombres exactos en la Task 2 y en los tests. `entry_for` devuelve `Entry`, consumido por `save_account`/`load_refresh_token`/`delete_account`. `load_index() -> AccountIndex` y `save_index(&AccountIndex) -> Result<()>` casan con sus llamadas. `AccountIndex` deriva `PartialEq` y `Clone`, requeridos por el `assert_eq!` del round-trip y por la comparación `index != before` del auto-sanado. `chrono::Utc`, `dirs::data_local_dir` y `crate::app_dirs::migrated_app_dir` existen ya en el crate. ✓
