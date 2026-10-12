# SP-1 — Acceso SSH nativo: plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que LCC obtenga acceso SSH a una VM sin `gcloud`: adoptando una clave ya autorizada si la hay, y si no, generando una y publicándola —con consentimiento— por OS Login o por los metadatos de la instancia.

**Architecture:** Un módulo `native/src/ssh_access.rs` expone dos fases, `probe` (¿tengo acceso ya?) y `provision` (escribir la clave), porque el consentimiento del usuario ocurre entre ambas. El núcleo decidible —la fusión de `ssh-keys`, la elección de usuario, los nombres de clave candidatos— son funciones puras testeables sin red. La publicación reutiliza el patrón de petición autenticada de `gcp_rest_client.rs`.

**Tech Stack:** Rust (tokio, reqwest, anyhow, ssh2, ssh-key/RustCrypto), flutter_rust_bridge 2.11.1, Flutter/Dart con Riverpod y SharedPreferences.

**Spec:** [`docs/superpowers/specs/2026-08-20-sp1-native-ssh-access-design.md`](../specs/2026-08-20-sp1-native-ssh-access-design.md)

## Global Constraints

- **La clave privada NUNCA se registra**: ni su contenido, ni volcada en un mensaje de error. Solo se menciona su **ruta**. Los cuerpos de respuesta de error pasan por `crate::redact::redact_sensitive`.
- **Se escribe en metadatos de INSTANCIA, jamás de proyecto.** Escribir a nivel de proyecto autorizaría la clave en todas las VMs y es explícitamente lo que este diseño rechaza.
- **La fusión de `ssh-keys` nunca sobrescribe.** Perder las entradas de otros usuarios en un proyecto compartido es un incidente, no un bug.
- **Toda llamada a `crate::token_store` va por `crate::oauth::store_call`** (`spawn_blocking`): zbus conduce su propio runtime y entra en pánico desde un worker de tokio.
- **Sin scopes nuevos.** `SCOPES` (`native/src/oauth.rs:25`) ya incluye `https://www.googleapis.com/auth/cloud-platform`, que cubre Compute y OS Login.
- **Prohibido `#[allow(dead_code)]`** y cualquier otro silenciado de lints.
- **NO ejecutar `dart format`** en ningún momento.
- Rama `27H1-Preview`. Los commits de código **no** llevan trailer `Co-Authored-By`; el del checklist de QA sí.

## File Structure

| Fichero | Responsabilidad | Tarea |
|---|---|---|
| `native/src/ssh_session.rs` (modificar) | Añade `google_compute_engine` a los candidatos | 1 |
| `native/src/ssh_keys.rs` (**crear**) | Fusión pura de `ssh-keys` y formato de entrada | 2 |
| `native/src/ssh_keys.rs` (ampliar) | Generación ed25519, almacenamiento 0600, huella | 3 |
| `native/src/ssh_access.rs` (**crear**) | Elección de usuario (pura) + perfil OS Login | 4 |
| `native/src/ssh_access.rs` (ampliar) | Publicación: metadatos de instancia y OS Login | 5 |
| `native/src/ssh_access.rs` (ampliar) | `probe` / `provision`, las dos fases | 6 |
| `native/src/api.rs`, `lib/src/features/ssh_consent_dialog.dart`, 3 call sites | Bridge, consentimiento, integración | 7 |
| `docs/superpowers/plans/2026-08-20-sp1-native-ssh-access-manual-qa.md` (**crear**) | QA con evidencia | 8 |

---

### Task 1: La clave de gcloud entra en los candidatos

**Files:**
- Modify: `native/src/ssh_session.rs:39-46`
- Test: `native/src/ssh_session.rs` (módulo de tests nuevo al final)

**Interfaces:**
- Produces: `pub(crate) fn candidate_key_names() -> [&'static str; 4]`, que la tarea 6 usa para mensajes de diagnóstico.

**Contexto que necesitas:** `create_ssh_session` prueba primero el agente SSH y, si falla, recorre `KEY_NAMES` buscando ficheros en `~/.ssh`. Hoy la lista es `["id_ed25519", "id_ecdsa", "id_rsa"]`. Falta `google_compute_engine`, que es **la clave que `gcloud compute ssh` genera y provisiona en las VMs** — quien haya usado gcloud alguna vez la tiene ya autorizada, así que añadirla da la ruta rápida a todos esos usuarios sin provisionar nada.

El orden importa: las claves personales van primero porque son las que el usuario eligió; la de gcloud es el respaldo.

- [ ] **Step 1: Escribe el test que falla**

Añade al final de `native/src/ssh_session.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// La clave que genera `gcloud compute ssh` tiene que estar entre las
    /// candidatas: quien venga de gcloud ya la tiene autorizada en sus VMs, y
    /// sin ella ese usuario iría a provisionar una clave nueva sin necesidad.
    #[test]
    fn the_gcloud_key_is_a_candidate() {
        assert!(candidate_key_names().contains(&"google_compute_engine"));
    }

    /// Las claves personales se prueban antes que la de gcloud.
    #[test]
    fn personal_keys_come_before_the_gcloud_one() {
        let names = candidate_key_names();
        let gcloud = names.iter().position(|n| *n == "google_compute_engine").unwrap();
        let ed25519 = names.iter().position(|n| *n == "id_ed25519").unwrap();
        assert!(ed25519 < gcloud, "orden inesperado: {:?}", names);
    }
}
```

- [ ] **Step 2: Ejecuta el test y comprueba que falla**

```bash
cd native && cargo test --lib ssh_session::
```

Esperado: FAIL de compilación — `cannot find function candidate_key_names`.

- [ ] **Step 3: Implementa**

Sustituye la constante en línea por una función a nivel de módulo. Encima de `create_ssh_session`:

```rust
/// SSH key file names tried in `~/.ssh`, in order, when the agent has none.
///
/// `google_compute_engine` is what `gcloud compute ssh` generates and pushes to
/// the VM, so anyone arriving from gcloud already has it authorised — trying it
/// is what lets them connect without provisioning anything. It goes last: the
/// user's own keys are the ones they chose.
pub(crate) fn candidate_key_names() -> [&'static str; 4] {
    ["id_ed25519", "id_ecdsa", "id_rsa", "google_compute_engine"]
}
```

Y dentro de `create_ssh_session`, sustituye

```rust
        const KEY_NAMES: [&str; 3] = ["id_ed25519", "id_ecdsa", "id_rsa"];
        let existing: Vec<std::path::PathBuf> = KEY_NAMES
```

por

```rust
        let key_names = candidate_key_names();
        let existing: Vec<std::path::PathBuf> = key_names
```

y cambia la única referencia posterior `KEY_NAMES.join(", ")` por `key_names.join(", ")`.

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib ssh_session::
```

Esperado: PASS, los dos.

- [ ] **Step 5: Commit**

```bash
git add native/src/ssh_session.rs
git commit -m "feat(ssh): try the key gcloud provisions

Anyone who has ever run \`gcloud compute ssh\` already has
~/.ssh/google_compute_engine authorised on their VMs. Trying it is what
lets them connect with no provisioning at all."
```

---

### Task 2: Fusionar `ssh-keys` sin destruir nada

**Files:**
- Create: `native/src/ssh_keys.rs`
- Modify: `native/src/lib.rs` (declarar el módulo)
- Test: `native/src/ssh_keys.rs`

**Interfaces:**
- Produces, para las tareas 5 y 6:
  - `pub(crate) fn format_entry(username: &str, public_key: &str) -> String`
  - `pub(crate) fn merge_ssh_keys(current: Option<&str>, entry: &str) -> String`

**Contexto que necesitas:** el metadato `ssh-keys` de una instancia es **un único valor de texto**, con una entrada por línea, de forma `usuario:tipo clave comentario`. Algunas entradas llevan un sufijo `google-ssh {"userName":"…","expireOn":"…"}` que marca caducidad.

**Sobrescribir ese valor en vez de fusionarlo borra el acceso de todos los demás.** En un proyecto compartido eso es un incidente. Esta es la función más peligrosa del sub-proyecto y por eso es pura y lleva la guarda más dura.

- [ ] **Step 1: Declara el módulo**

En `native/src/lib.rs`, junto a las otras declaraciones:

```rust
pub mod ssh_keys;  // 27H1 SP-1: ssh-keys metadata formatting and merging
```

- [ ] **Step 2: Escribe los tests que fallan**

Crea `native/src/ssh_keys.rs` con **solo** el módulo de tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const OTHER: &str = "ana:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI0000 ana@laptop";
    const OURS: &str = "jlopezre:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI1111 lightweight-cloud-connector";

    #[test]
    fn the_entry_has_the_username_prefix_and_our_comment() {
        let e = format_entry("jlopezre", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI1111");
        assert!(e.starts_with("jlopezre:"), "falta el prefijo de usuario: {}", e);
        assert!(e.ends_with(" lightweight-cloud-connector"), "falta el comentario: {}", e);
    }

    /// LA guarda del sub-proyecto: si esto sobrescribe en vez de fusionar,
    /// borra el acceso SSH de los demás en un proyecto compartido.
    #[test]
    fn merging_never_drops_another_users_key() {
        let merged = merge_ssh_keys(Some(OTHER), OURS);
        assert!(
            merged.contains(OTHER),
            "se perdió la clave de otro usuario al fusionar:\n{}",
            merged
        );
        assert!(merged.contains(OURS), "no se añadió la nuestra:\n{}", merged);
    }

    #[test]
    fn merging_preserves_every_existing_entry() {
        let third = "bob:ssh-rsa AAAAB3Nz2222 bob@desk";
        let current = format!("{}\n{}", OTHER, third);
        let merged = merge_ssh_keys(Some(&current), OURS);
        for expected in [OTHER, third, OURS] {
            assert!(merged.contains(expected), "falta {}\nen:\n{}", expected, merged);
        }
    }

    /// Las entradas con caducidad llevan un sufijo JSON que no debe corromperse.
    #[test]
    fn an_expiring_entry_survives_untouched() {
        let expiring = r#"ana:ssh-ed25519 AAAAC3Nz0000 google-ssh {"userName":"ana@x.com","expireOn":"2026-12-01T00:00:00+0000"}"#;
        let merged = merge_ssh_keys(Some(expiring), OURS);
        assert!(merged.contains(expiring), "se corrompió la entrada con expireOn:\n{}", merged);
    }

    #[test]
    fn our_entry_is_not_duplicated() {
        let merged = merge_ssh_keys(Some(OURS), OURS);
        assert_eq!(merged.matches(OURS).count(), 1, "se duplicó:\n{}", merged);
    }

    #[test]
    fn an_absent_or_empty_value_yields_just_our_entry() {
        assert_eq!(merge_ssh_keys(None, OURS), OURS);
        assert_eq!(merge_ssh_keys(Some(""), OURS), OURS);
        assert_eq!(merge_ssh_keys(Some("   \n\n"), OURS), OURS);
    }

    #[test]
    fn blank_lines_do_not_become_entries() {
        let merged = merge_ssh_keys(Some("\n\nana:ssh-rsa AAAAB3Nz0000 ana\n\n"), OURS);
        assert!(!merged.lines().any(|l| l.trim().is_empty()), "líneas en blanco:\n{}", merged);
    }
}
```

- [ ] **Step 3: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib ssh_keys::
```

Esperado: FAIL de compilación — `cannot find function format_entry`.

- [ ] **Step 4: Implementa**

Escribe esto **encima** del `mod tests`:

```rust
//! Formatting and merging of the `ssh-keys` instance metadata value.
//!
//! That value is a single blob with one `user:type key comment` entry per
//! line, shared by everyone with access to the VM. Merging — never
//! overwriting — is the whole point of this module: replacing the blob would
//! revoke every other user's SSH access, which on a shared project is an
//! incident rather than a bug.

/// Comment stamped on the key LCC publishes, so it can be found and removed.
pub(crate) const KEY_COMMENT: &str = "lightweight-cloud-connector";

/// Build the `ssh-keys` entry authorising `public_key` for `username`.
///
/// `public_key` is the OpenSSH one-line form without a comment
/// (`ssh-ed25519 AAAA…`).
pub(crate) fn format_entry(username: &str, public_key: &str) -> String {
    format!("{}:{} {}", username, public_key.trim(), KEY_COMMENT)
}

/// Add `entry` to the existing `ssh-keys` value, keeping every other line.
///
/// Idempotent: an entry already present is not added twice. Blank lines are
/// dropped, because a stray empty line becomes a malformed entry on the VM.
pub(crate) fn merge_ssh_keys(current: Option<&str>, entry: &str) -> String {
    let mut lines: Vec<&str> = current
        .unwrap_or("")
        .lines()
        .map(|l| l.trim_end())
        .filter(|l| !l.trim().is_empty())
        .collect();

    if !lines.iter().any(|l| *l == entry) {
        lines.push(entry);
    }
    lines.join("\n")
}
```

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib ssh_keys::
```

Esperado: PASS, los siete.

- [ ] **Step 6: Comprueba la prueba negativa y ponla en el informe**

Sustituye temporalmente el cuerpo de `merge_ssh_keys` por `entry.to_string()` —que es exactamente el error de sobrescribir— y ejecuta:

```bash
cd native && cargo test --lib ssh_keys::
```

Esperado: **FALLA** `merging_never_drops_another_users_key`. Restaura el cuerpo, vuelve a ejecutar, comprueba que pasa, y pega **ambas** salidas en el informe. Un test que no falla al introducir el defecto que vigila no es una guarda.

- [ ] **Step 7: Commit**

```bash
git add native/src/ssh_keys.rs native/src/lib.rs
git commit -m "feat(ssh): merge the ssh-keys metadata blob, never replace it

That value is shared by everyone with access to the VM. Overwriting it
revokes every other user's SSH access — on a shared project that is an
incident, so the merge is pure and carries a test that fails if it ever
becomes an overwrite."
```

---

### Task 3: Generar y guardar la clave de LCC

**Files:**
- Modify: `native/src/ssh_keys.rs`, `native/Cargo.toml`
- Test: `native/src/ssh_keys.rs`

**Interfaces:**
- Consumes de la tarea 2: `KEY_COMMENT`.
- Produces, para las tareas 5 y 6:
  - `pub(crate) struct LccKey { pub private_path: std::path::PathBuf, pub public_openssh: String, pub fingerprint: String }`
  - `pub(crate) fn load_or_create_key() -> anyhow::Result<LccKey>`

**Contexto que necesitas:** la privada vive en `<data dir>/ssh/lcc_ed25519`, donde el data dir es `crate::app_dirs::migrated_app_dir(dirs::data_local_dir().ok_or(...)?)` — el mismo sitio que `oauth_accounts.json`. **No** se escribe en `~/.ssh`: ese directorio es del usuario.

Se genera con el crate **`ssh-key`** (RustCrypto), no invocando `ssh-keygen`: añadir una dependencia de CLI a un proyecto cuyo propósito es quitar una sería contradictorio.

**La clave privada no se registra jamás** — ni su contenido ni un volcado en un error. Solo su ruta.

- [ ] **Step 1: Añade la dependencia**

En `native/Cargo.toml`, junto a las demás:

```toml
# SP-1: generate LCC's own ed25519 key in pure Rust. Shelling out to
# ssh-keygen would add a CLI dependency to a project whose point is
# removing one.
ssh-key = { version = "0.6", features = ["ed25519", "rand_core", "std"] }
rand_core = { version = "0.6", features = ["std"] }
```

Comprueba que resuelve:

```bash
cd native && cargo fetch 2>&1 | tail -3
```

**Si la API de la versión resuelta difiere** de la del paso 3, adáptala y **dilo en el informe** — no la fuerces ni fijes una versión vieja sin decirlo.

- [ ] **Step 2: Escribe los tests que fallan**

Añade al `mod tests` de `native/src/ssh_keys.rs`:

```rust
    #[test]
    fn a_generated_key_is_a_usable_openssh_ed25519_pair() {
        let dir = std::env::temp_dir().join(format!("lcc-key-test-{}", std::process::id()));
        let key = super::create_key_at(&dir).expect("genera la clave");

        assert!(key.public_openssh.starts_with("ssh-ed25519 "), "no es ed25519: {}", key.public_openssh);
        assert!(!key.public_openssh.contains('\n'), "la pública debe ser una línea");
        assert!(key.fingerprint.starts_with("SHA256:"), "huella inesperada: {}", key.fingerprint);
        assert!(key.private_path.exists(), "no se escribió la privada");

        // La privada NO puede quedar legible por otros: es material secreto.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&key.private_path).unwrap().permissions().mode();
            assert_eq!(mode & 0o077, 0, "permisos demasiado abiertos: {:o}", mode);
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn creating_twice_reuses_the_same_key() {
        let dir = std::env::temp_dir().join(format!("lcc-key-reuse-{}", std::process::id()));
        let first = super::create_key_at(&dir).expect("primera");
        let second = super::create_key_at(&dir).expect("segunda");
        assert_eq!(first.public_openssh, second.public_openssh, "se regeneró la clave");
        let _ = std::fs::remove_dir_all(&dir);
    }
```

- [ ] **Step 3: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib ssh_keys::
```

Esperado: FAIL de compilación — `cannot find function create_key_at`.

- [ ] **Step 4: Implementa**

Añade a `native/src/ssh_keys.rs`:

```rust
use anyhow::{anyhow, Context, Result};
use std::path::{Path, PathBuf};

/// LCC's own key pair: where the private half lives, and the public half in the
/// one-line OpenSSH form that GCP wants.
pub(crate) struct LccKey {
    pub private_path: PathBuf,
    pub public_openssh: String,
    pub fingerprint: String,
}

/// Load LCC's key, generating it on first use.
///
/// Lives in the app's data directory, NOT in `~/.ssh`: that directory belongs
/// to the user and LCC has no business writing there uninvited.
pub(crate) fn load_or_create_key() -> Result<LccKey> {
    let base = crate::app_dirs::migrated_app_dir(
        dirs::data_local_dir().ok_or_else(|| anyhow!("Could not determine the data directory"))?,
    );
    create_key_at(&base.join("ssh"))
}

/// The directory is a parameter so the tests can use a throwaway one.
pub(crate) fn create_key_at(dir: &Path) -> Result<LccKey> {
    use ssh_key::{Algorithm, HashAlg, LineEnding, PrivateKey};

    std::fs::create_dir_all(dir)
        .with_context(|| format!("Could not create {}", dir.display()))?;
    let private_path = dir.join("lcc_ed25519");

    let key = if private_path.exists() {
        // NOTE: the error deliberately names only the path. The file's contents
        // are secret and must never reach a log or a message.
        PrivateKey::read_openssh_file(&private_path)
            .map_err(|e| anyhow!("Could not read the SSH key at {}: {}", private_path.display(), e))?
    } else {
        let mut key = PrivateKey::random(&mut rand_core::OsRng, Algorithm::Ed25519)
            .map_err(|e| anyhow!("Could not generate an SSH key: {}", e))?;
        key.set_comment(KEY_COMMENT);
        key.write_openssh_file(&private_path, LineEnding::LF)
            .map_err(|e| anyhow!("Could not write the SSH key to {}: {}", private_path.display(), e))?;
        harden_permissions(&private_path)?;
        tracing::info!(path = %private_path.display(), "Generated LCC's SSH key");
        key
    };

    let public = key.public_key();
    // Without the comment: `format_entry` appends its own.
    let public_openssh = format!(
        "{} {}",
        public.algorithm().as_str(),
        public.key_data()
            .encoded_string()
            .map_err(|e| anyhow!("Could not encode the public key: {}", e))?
    );

    Ok(LccKey {
        private_path,
        public_openssh,
        fingerprint: public.fingerprint(HashAlg::Sha256).to_string(),
    })
}

/// Private key material must not be readable by other users on the machine.
fn harden_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("Could not restrict permissions on {}", path.display()))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}
```

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib ssh_keys::
```

Esperado: PASS, los nueve. Si la API de `ssh-key` difiere en la versión resuelta, adáptala **sin** cambiar lo que los tests exigen, y dilo en el informe.

- [ ] **Step 6: Comprueba que la privada no se filtra**

```bash
cd native && grep -n 'private_path\|PrivateKey' src/ssh_keys.rs | grep -i 'tracing\|anyhow\|format!'
```

Cada aparición debe imprimir **la ruta**, nunca el contenido de la clave ni el objeto `PrivateKey`. Pega la salida en el informe con esa afirmación explícita.

- [ ] **Step 7: Commit**

```bash
git add native/Cargo.toml native/Cargo.lock native/src/ssh_keys.rs
git commit -m "feat(ssh): generate and store LCC's own ed25519 key

Pure Rust via the ssh-key crate rather than shelling out to ssh-keygen:
adding a CLI dependency to a project whose point is removing one would be
self-defeating. The private half lives in the app data dir at 0600, not in
~/.ssh, and never reaches a log or an error message."
```

---

### Task 4: Quién soy en esa VM

**Files:**
- Create: `native/src/ssh_access.rs`
- Modify: `native/src/lib.rs`
- Test: `native/src/ssh_access.rs`

**Interfaces:**
- Produces, para las tareas 5 y 6:
  - `pub enum ProvisionMethod { OsLogin, InstanceMetadata }`
  - `pub(crate) fn choose_username(os_login_enabled: bool, posix: Option<&str>, email: &str, local_user: &str) -> String`
  - `pub(crate) async fn os_login_posix_username(email: &str) -> anyhow::Result<Option<String>>`

**Contexto que necesitas:** hoy `get_current_username()` (`native/src/sftp.rs:1038`) devuelve el `$USER` local y **eso es lo que usan SFTP y el terminal**. Funciona por coincidencia: gcloud provisiona en metadatos con ese mismo nombre. Contra una VM con **OS Login** el usuario correcto es el POSIX (`jlopezre_ntt_enap_cl`), así que hoy fallan — este es el fallo latente que SP-1 arregla.

El POSIX **se consulta**, no se deriva: puede llevar sufijo por colisión o venir fijado por la organización. `email_to_oslogin_username` (`native/src/gcloud.rs:893`) queda como respaldo si el perfil no trae `posixAccounts`.

El endpoint es `GET https://oslogin.googleapis.com/v1/users/{email}/loginProfile`, autenticado igual que el resto: `bearer_auth` con el token de `crate::gcp_rest_client`.

- [ ] **Step 1: Declara el módulo**

En `native/src/lib.rs`:

```rust
pub mod ssh_access;  // 27H1 SP-1: SSH key provisioning and username selection
```

- [ ] **Step 2: Escribe los tests que fallan**

Crea `native/src/ssh_access.rs` con **solo** el módulo de tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// El fallo que SP-1 arregla: con OS Login activo el usuario NO es el local.
    #[test]
    fn os_login_uses_the_posix_account_not_the_local_user() {
        let u = choose_username(true, Some("jlopezre_ntt_enap_cl"), "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre_ntt_enap_cl");
    }

    /// Sin perfil utilizable se deriva del email, que es mejor que el local.
    #[test]
    fn os_login_without_a_profile_falls_back_to_the_derived_name() {
        let u = choose_username(true, None, "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre_ntt_enap_cl");
    }

    /// Un perfil vacío o en blanco no es un nombre de usuario.
    #[test]
    fn a_blank_posix_name_is_not_used() {
        let u = choose_username(true, Some("   "), "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre_ntt_enap_cl");
    }

    /// Sin OS Login manda el usuario local, que es lo que gcloud provisiona.
    #[test]
    fn metadata_mode_keeps_the_local_user() {
        let u = choose_username(false, Some("jlopezre_ntt_enap_cl"), "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre");
    }
}
```

- [ ] **Step 3: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib ssh_access::
```

Esperado: FAIL de compilación — `cannot find function choose_username`.

- [ ] **Step 4: Implementa**

Encima del `mod tests`:

```rust
//! Getting SSH access to a VM without gcloud: which user to log in as, and
//! publishing LCC's key when nothing already grants access.

use anyhow::{anyhow, Result};

/// How a key reaches the VM. Decided per instance by its `enable-oslogin`
/// metadata, which `gcp_rest_client` already surfaces as `os_login_enabled`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProvisionMethod {
    OsLogin,
    InstanceMetadata,
}

/// Pick the SSH username for a VM.
///
/// Under OS Login the account is the POSIX one, which is *queried* rather than
/// derived: it can carry a collision suffix or be pinned by the organisation.
/// The derivation is the fallback. Without OS Login the local user is right —
/// it is the name gcloud publishes into `ssh-keys`, and using anything else
/// would break every VM already provisioned by gcloud.
pub(crate) fn choose_username(
    os_login_enabled: bool,
    posix: Option<&str>,
    email: &str,
    local_user: &str,
) -> String {
    if !os_login_enabled {
        return local_user.to_string();
    }
    match posix.map(str::trim).filter(|p| !p.is_empty()) {
        Some(p) => p.to_string(),
        None => crate::gcloud::email_to_oslogin_username(email),
    }
}

/// The POSIX account name from the caller's OS Login profile, if it has one.
pub(crate) async fn os_login_posix_username(email: &str) -> Result<Option<String>> {
    let token = crate::gcp_rest_client::access_token().await?;
    let url = format!(
        "https://oslogin.googleapis.com/v1/users/{}/loginProfile",
        urlencoding::encode(email)
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let response = client
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| anyhow!("OS Login profile request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(anyhow!(
            "OS Login profile lookup failed ({}): {}",
            status,
            crate::redact::redact_sensitive(&body)
        ));
    }

    let profile: serde_json::Value = serde_json::from_str(&response.text().await?)
        .map_err(|e| anyhow!("Could not parse the OS Login profile: {}", e))?;

    Ok(profile["posixAccounts"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|p| p["username"].as_str())
        .map(|s| s.to_string()))
}
```

**Dos cosas que debes comprobar antes de dar el paso por hecho:**

1. `crate::gcp_rest_client::access_token()` puede no existir con ese nombre. Busca cómo obtiene el token el resto del fichero (`self.auth.get_access_token()`, dentro de los clientes) y **expón un ayudante `pub(crate) async fn access_token() -> Result<String>`** en `gcp_rest_client.rs` que devuelva el token de la cuenta activa, reutilizando `GcpAuthClient::get_or_init()`. Dilo en el informe.
2. `urlencoding` puede no ser dependencia. Comprueba con `grep -n urlencoding native/Cargo.toml`; si no está, usa el `encode` que ya emplea `native/src/iap_tunnel/session.rs` o añade el crate, y dilo en el informe.

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib ssh_access:: && cargo build --lib
```

Esperado: PASS los cuatro, y compilación sin warnings nuevos.

- [ ] **Step 6: Commit**

```bash
git add native/src/ssh_access.rs native/src/lib.rs native/src/gcp_rest_client.rs
git commit -m "feat(ssh): pick the right SSH user for the VM

With OS Login enabled the account is the POSIX one, not \$USER — so SFTP
and the terminal have been failing against those VMs all along. The POSIX
name is queried rather than derived, because it can carry a collision
suffix or be pinned by the organisation."
```

---

### Task 5: Publicar la clave

**Files:**
- Modify: `native/src/ssh_access.rs`
- Test: `native/src/ssh_access.rs`

**Interfaces:**
- Consumes: de la tarea 2 `format_entry` y `merge_ssh_keys`; de la tarea 3 `LccKey`; de la tarea 4 `ProvisionMethod`.
- Produces, para la tarea 6:
  - `pub(crate) async fn publish_to_instance_metadata(project: &str, zone: &str, instance: &str, username: &str, key: &LccKey) -> Result<()>`
  - `pub(crate) async fn publish_to_os_login(email: &str, key: &LccKey) -> Result<()>`
  - `pub(crate) fn metadata_items_with_ssh_keys(items: &serde_json::Value, merged: &str) -> Vec<serde_json::Value>`

**Contexto que necesitas:** escribir metadatos son **tres pasos que no se pueden separar**:

1. `GET https://compute.googleapis.com/compute/v1/projects/{p}/zones/{z}/instances/{i}` — devuelve `metadata.fingerprint` y `metadata.items`.
2. Fusionar nuestra entrada con el valor actual de `ssh-keys` (tarea 2).
3. `POST …/instances/{i}/setMetadata` con `{ "fingerprint": …, "items": [ … ] }`.

**El `fingerprint` es obligatorio**: GCP lo usa para concurrencia optimista y rechaza la escritura sin él o con uno viejo. Es el fingerprint **de los metadatos**, no el de la clave.

Se escribe en la **instancia**, jamás en el proyecto.

- [ ] **Step 1: Escribe el test que falla**

Al `mod tests` de `native/src/ssh_access.rs`:

```rust
    /// Reescribir `items` no puede perder los demás metadatos de la VM:
    /// ahí viven startup-script, enable-oslogin y todo lo que la organización
    /// haya puesto.
    #[test]
    fn rewriting_ssh_keys_keeps_every_other_metadata_item() {
        let items = serde_json::json!([
            {"key": "startup-script", "value": "#!/bin/bash\necho hola"},
            {"key": "ssh-keys", "value": "ana:ssh-rsa AAAA0000 ana"},
            {"key": "enable-oslogin", "value": "FALSE"}
        ]);

        let out = metadata_items_with_ssh_keys(&items, "ana:ssh-rsa AAAA0000 ana\nyo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");

        let by_key = |k: &str| out.iter().find(|i| i["key"] == k).cloned();
        assert_eq!(by_key("startup-script").unwrap()["value"], "#!/bin/bash\necho hola");
        assert_eq!(by_key("enable-oslogin").unwrap()["value"], "FALSE");
        assert!(by_key("ssh-keys").unwrap()["value"].as_str().unwrap().contains("lightweight-cloud-connector"));
        assert_eq!(out.len(), 3, "cambió el número de items: {:?}", out);
    }

    /// Una VM sin `ssh-keys` previo gana el item, sin perder los otros.
    #[test]
    fn an_instance_without_ssh_keys_gains_the_item() {
        let items = serde_json::json!([{"key": "startup-script", "value": "x"}]);
        let out = metadata_items_with_ssh_keys(&items, "yo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");
        assert_eq!(out.len(), 2);
        assert!(out.iter().any(|i| i["key"] == "ssh-keys"));
        assert!(out.iter().any(|i| i["key"] == "startup-script"));
    }
```

- [ ] **Step 2: Ejecuta el test y comprueba que falla**

```bash
cd native && cargo test --lib ssh_access::
```

Esperado: FAIL de compilación — `cannot find function metadata_items_with_ssh_keys`.

- [ ] **Step 3: Implementa**

Añade a `native/src/ssh_access.rs`:

```rust
use crate::ssh_keys::{format_entry, merge_ssh_keys, LccKey};

/// Replace (or add) the `ssh-keys` item, leaving every other item untouched.
///
/// `items` carries whatever the organisation put on the VM — startup scripts,
/// `enable-oslogin`, monitoring flags. `setMetadata` replaces the whole list,
/// so dropping one here deletes it from the instance.
pub(crate) fn metadata_items_with_ssh_keys(
    items: &serde_json::Value,
    merged: &str,
) -> Vec<serde_json::Value> {
    let mut out: Vec<serde_json::Value> = items
        .as_array()
        .map(|a| a.iter().filter(|i| i["key"] != "ssh-keys").cloned().collect())
        .unwrap_or_default();
    out.push(serde_json::json!({ "key": "ssh-keys", "value": merged }));
    out
}

/// Authorise `key` for `username` on ONE instance.
///
/// Instance level, never project level: a project-level write would authorise
/// the key on every VM in the project, present and future.
pub(crate) async fn publish_to_instance_metadata(
    project: &str,
    zone: &str,
    instance: &str,
    username: &str,
    key: &LccKey,
) -> Result<()> {
    let token = crate::gcp_rest_client::access_token().await?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;
    let base = format!(
        "https://compute.googleapis.com/compute/v1/projects/{}/zones/{}/instances/{}",
        project, zone, instance
    );

    // 1) Read: we need the CURRENT metadata fingerprint. GCP uses it for
    //    optimistic concurrency and rejects a write without it.
    let current: serde_json::Value = {
        let r = client.get(&base).bearer_auth(&token).send().await
            .map_err(|e| anyhow!("Failed to read the instance: {}", e))?;
        if !r.status().is_success() {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            return Err(anyhow!("Could not read the instance ({}): {}", status, crate::redact::redact_sensitive(&body)));
        }
        serde_json::from_str(&r.text().await?)
            .map_err(|e| anyhow!("Could not parse the instance: {}", e))?
    };

    let fingerprint = current["metadata"]["fingerprint"].as_str()
        .ok_or_else(|| anyhow!("The instance metadata carries no fingerprint; refusing to write blind"))?;
    let merged = merge_ssh_keys(
        current["metadata"]["items"].as_array()
            .and_then(|a| a.iter().find(|i| i["key"] == "ssh-keys"))
            .and_then(|i| i["value"].as_str()),
        &format_entry(username, &key.public_openssh),
    );

    // 2+3) Write back every item, with ssh-keys merged.
    let body = serde_json::json!({
        "fingerprint": fingerprint,
        "items": metadata_items_with_ssh_keys(&current["metadata"]["items"], &merged),
    });
    let r = client.post(format!("{}/setMetadata", base))
        .bearer_auth(&token)
        .json(&body)
        .send().await
        .map_err(|e| anyhow!("Failed to write the instance metadata: {}", e))?;
    if !r.status().is_success() {
        let status = r.status();
        let text = r.text().await.unwrap_or_default();
        return Err(provisioning_error(status.as_u16(), &text, "compute.instances.setMetadata"));
    }

    tracing::info!(instance, username, fingerprint = %key.fingerprint, "Published LCC's SSH key to the instance metadata");
    Ok(())
}

/// Authorise `key` through OS Login, for the signed-in account.
pub(crate) async fn publish_to_os_login(email: &str, key: &LccKey) -> Result<()> {
    let token = crate::gcp_rest_client::access_token().await?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let url = format!(
        "https://oslogin.googleapis.com/v1/users/{}:importSshPublicKey",
        urlencoding::encode(email)
    );
    let body = serde_json::json!({
        "key": format!("{} {}", key.public_openssh, crate::ssh_keys::KEY_COMMENT),
    });

    let r = client.post(&url).bearer_auth(&token).json(&body).send().await
        .map_err(|e| anyhow!("OS Login key import failed: {}", e))?;
    if !r.status().is_success() {
        let status = r.status();
        let text = r.text().await.unwrap_or_default();
        return Err(provisioning_error(status.as_u16(), &text, "compute.osLogin"));
    }

    tracing::info!(fingerprint = %key.fingerprint, "Imported LCC's SSH key through OS Login");
    Ok(())
}

/// Turn a provisioning failure into something the user can act on.
///
/// Permissions are the likeliest failure in a distributed app: plenty of users
/// hold read-only or operator roles. Naming the missing permission and the two
/// real ways out beats a generic message that sends them looking in the wrong
/// place — the same lesson the tunnel error sweep taught.
fn provisioning_error(status: u16, body: &str, permission: &str) -> anyhow::Error {
    let redacted = crate::redact::redact_sensitive(body);
    if status == 403 || status == 401 {
        return anyhow!(
            "Not allowed to authorise an SSH key on this VM: the account is missing `{}`.\n\
             Either ask an administrator to grant it (or to authorise your key), or open the port \
             in the IAP firewall rule and use a direct tunnel instead.\n\
             Details: {}",
            permission, redacted
        );
    }
    anyhow!("Could not authorise the SSH key ({}): {}", status, redacted)
}
```

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib ssh_access:: && cargo build --lib
```

Esperado: PASS los seis, compilación sin warnings nuevos.

- [ ] **Step 5: Comprueba que no se escribe a nivel de proyecto**

```bash
cd native && grep -n 'setCommonInstanceMetadata\|projects/{}/setMetadata\|/global/' src/ssh_access.rs || echo "(ninguna escritura a nivel de proyecto — correcto)"
```

Pega la salida en el informe.

- [ ] **Step 6: Commit**

```bash
git add native/src/ssh_access.rs
git commit -m "feat(ssh): publish LCC's key to the instance or through OS Login

Instance metadata only: a project-level write would authorise the key on
every VM in the project. The write carries the metadata fingerprint GCP
requires for optimistic concurrency, and rewrites the item list without
dropping startup scripts or any other item the organisation set.

A permission failure names the exact missing permission and the two real
ways out, because that is the likeliest failure in a distributed app."
```

---

### Task 6: Las dos fases

**Files:**
- Modify: `native/src/ssh_access.rs`
- Test: `native/src/ssh_access.rs`

**Interfaces:**
- Consumes: todo lo de las tareas 2-5, más `crate::tunnel::start_tunnel(project, zone, instance, 22, None) -> Result<u16>` y `crate::ssh_session::create_ssh_session(host, port, username)`.
- Produces, para la tarea 7:
  - `pub enum SshAccessState { Ready { username: String }, NeedsProvisioning { username: String, method: ProvisionMethod, key_fingerprint: String } }`
  - `pub async fn probe_ssh_access(project: String, zone: String, instance: String) -> Result<SshAccessState>`
  - `pub async fn provision_ssh_access(project: String, zone: String, instance: String) -> Result<String>` (devuelve el usuario)

**Contexto que necesitas:** el consentimiento del usuario ocurre **entre** las dos fases, por eso están separadas. `probe` no escribe nada nunca.

`probe` averigua si ya hay acceso **intentándolo**: túnel IAP nativo al 22 y sesión SSH real. Se adopta lo que está autorizado, no lo que se llama de cierta forma.

Un fallo que **no** sea de autenticación (la VM no responde, el relay no llega) se propaga como error: no es un caso de provisionado, y tratarlo como tal escondería el problema real.

`provision_ssh_access` **no devuelve `Ok` hasta que una sesión real autentica**: el agente invitado tarda unos segundos en recoger la clave, y devolver antes haría fallar la primera conexión justo después de un provisionado correcto.

- [ ] **Step 1: Escribe los tests que fallan**

Al `mod tests`:

```rust
    /// Solo un fallo de AUTENTICACIÓN significa "hay que provisionar". Que la
    /// VM no responda es otro problema y debe propagarse, no disfrazarse de
    /// clave que falta.
    #[test]
    fn only_an_auth_failure_means_provisioning_is_needed() {
        assert!(is_auth_failure("All SSH authentication methods failed:\n  • SSH agent: ..."));
        assert!(is_auth_failure("SSH key file (/home/u/.ssh/id_rsa): Authentication failed"));
        assert!(!is_auth_failure("Failed to connect to SSH server: Connection refused"));
        assert!(!is_auth_failure("SSH handshake failed: timed out"));
    }

    #[test]
    fn the_provisioning_method_follows_os_login() {
        assert_eq!(method_for(true), ProvisionMethod::OsLogin);
        assert_eq!(method_for(false), ProvisionMethod::InstanceMetadata);
    }
```

- [ ] **Step 2: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib ssh_access::
```

Esperado: FAIL de compilación — `cannot find function is_auth_failure`.

- [ ] **Step 3: Implementa**

```rust
/// How long to keep retrying the session after publishing, while the guest
/// agent picks the new key up.
const PROPAGATION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(45);

/// Whether we already have SSH access, or need to publish a key first.
pub enum SshAccessState {
    Ready { username: String },
    NeedsProvisioning { username: String, method: ProvisionMethod, key_fingerprint: String },
}

fn method_for(os_login_enabled: bool) -> ProvisionMethod {
    if os_login_enabled { ProvisionMethod::OsLogin } else { ProvisionMethod::InstanceMetadata }
}

/// Whether an SSH failure is the server rejecting our credentials.
///
/// Anything else — refused connection, failed handshake, dead relay — is a
/// different problem, and provisioning a key would neither fix it nor explain
/// it. Matches the wording `create_ssh_session` produces.
fn is_auth_failure(message: &str) -> bool {
    message.contains("authentication methods failed")
        || message.contains("Authentication failed")
}

/// Do we already have access to this VM, and as whom?
///
/// Finds out by connecting for real: an authorised key is one that
/// authenticates, not one with a familiar file name. Writes nothing.
pub async fn probe_ssh_access(project: String, zone: String, instance: String) -> Result<SshAccessState> {
    let username = resolve_username(&project, &zone, &instance).await?;
    let local_port = crate::tunnel::start_tunnel(&project, &zone, &instance, 22, None)?;

    let user_for_thread = username.clone();
    let attempt = crate::oauth::store_call(move || {
        crate::ssh_session::create_ssh_session("127.0.0.1", local_port, &user_for_thread).map(|_| ())
    })
    .await?;

    match attempt {
        Ok(()) => Ok(SshAccessState::Ready { username }),
        Err(e) if is_auth_failure(&e.to_string()) => {
            let key = crate::ssh_keys::load_or_create_key()?;
            Ok(SshAccessState::NeedsProvisioning {
                username,
                method: method_for(os_login_enabled(&project, &zone, &instance).await?),
                key_fingerprint: key.fingerprint,
            })
        }
        Err(e) => Err(e),
    }
}

/// Publish LCC's key and do not return until a session actually authenticates.
pub async fn provision_ssh_access(project: String, zone: String, instance: String) -> Result<String> {
    let username = resolve_username(&project, &zone, &instance).await?;
    let key = crate::ssh_keys::load_or_create_key()?;
    let email = crate::accounts::active_email().await?;

    match method_for(os_login_enabled(&project, &zone, &instance).await?) {
        ProvisionMethod::OsLogin => publish_to_os_login(&email, &key).await?,
        ProvisionMethod::InstanceMetadata => {
            publish_to_instance_metadata(&project, &zone, &instance, &username, &key).await?
        }
    }

    let local_port = crate::tunnel::start_tunnel(&project, &zone, &instance, 22, None)?;
    let deadline = std::time::Instant::now() + PROPAGATION_TIMEOUT;
    loop {
        let user_for_thread = username.clone();
        let attempt = crate::oauth::store_call(move || {
            crate::ssh_session::create_ssh_session("127.0.0.1", local_port, &user_for_thread).map(|_| ())
        })
        .await?;
        if attempt.is_ok() {
            return Ok(username);
        }
        if std::time::Instant::now() >= deadline {
            // Distinct from "could not write": the key IS authorised, the VM
            // has just not picked it up yet, and retrying is the right advice.
            return Err(anyhow!(
                "The SSH key was authorised, but {} has not picked it up yet after {} seconds. Try again in a moment.",
                instance,
                PROPAGATION_TIMEOUT.as_secs()
            ));
        }
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
}
```

Y los dos ayudantes privados que usan, en el mismo fichero.
`get_instance_client_lib` (`native/src/gcp_rest_client.rs:1185`) devuelve un
`GcpInstanceClientLib` que **ya trae** el campo `os_login_enabled` calculado — no
reimplementes la detección:

```rust
/// Whether this VM uses OS Login. Read from the instance, which
/// `gcp_rest_client` already parses out of its `enable-oslogin` metadata.
async fn os_login_enabled(project: &str, zone: &str, instance: &str) -> Result<bool> {
    Ok(crate::gcp_rest_client::get_instance_client_lib(project, zone, instance)
        .await?
        .os_login_enabled)
}

/// The username to log in as on this VM.
///
/// The OS Login profile is only fetched when OS Login is actually on: under
/// metadata the answer is the local user and the network call would be waste.
async fn resolve_username(project: &str, zone: &str, instance: &str) -> Result<String> {
    let on = os_login_enabled(project, zone, instance).await?;
    let email = crate::accounts::active_email().await?;
    let posix = if on {
        os_login_posix_username(&email).await.ok().flatten()
    } else {
        None
    };
    Ok(choose_username(
        on,
        posix.as_deref(),
        &email,
        &crate::sftp::get_current_username()?,
    ))
}
```

**Una divergencia deliberada respecto al spec:** allí `provision_ssh_access`
devolvía `SshAccess { username }`. Aquí devuelve `String` — la struct tenía un
solo campo y el envoltorio no aportaba nada. Si en el futuro hace falta devolver
más, se reintroduce.

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib && cargo build --lib
```

Esperado: PASS, y `cargo build --lib` **sin warnings**.

- [ ] **Step 5: Commit**

```bash
git add native/src/ssh_access.rs
git commit -m "feat(ssh): probe and provision as two phases

Consent happens between them, so probe never writes. Probe finds out by
connecting for real — an authorised key is one that authenticates, not one
with a familiar file name — and only an authentication failure means
provisioning is needed.

provision does not return until a session authenticates: the guest agent
takes seconds to pick the key up, and returning at write time would fail
the very first connection after a successful provisioning."
```

---

### Task 7: Bridge, consentimiento y los tres call sites

**Files:**
- Modify: `native/src/api.rs`, `lib/src/services/storage_service.dart`
- Create: `lib/src/features/ssh_consent_dialog.dart`
- Modify: `lib/src/features/workspace/sftp_tab.dart:31`, `lib/src/features/workspace/ssh_terminal_tab.dart:29`, `lib/src/features/gcloud_provider.dart` (el `_connectSshForward`)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Consumes de la tarea 6: `probe_ssh_access`, `provision_ssh_access`, `SshAccessState`, `ProvisionMethod`.
- Produces: `Future<String?> ensureSshAccess(BuildContext, WidgetRef, {required String projectId, required String zone, required String instance})` en el diálogo — devuelve el usuario, o `null` si el usuario denegó.

**Contexto que necesitas:** los tres sitios que abren SSH llaman hoy a `getUsername()` (`$USER` local) justo antes de conectar. Ese es el punto de inserción: `ensureSshAccess` lo sustituye y devuelve el usuario correcto.

El consentimiento se guarda **por id de proyecto** en `StorageService`, que usa `SharedPreferences` (mira `setStringList('selected_project_ids', …)` como patrón). Una **denegación también se recuerda**: no se vuelve a preguntar en cada conexión.

**Regeneración del bridge:**

```bash
cd /home/jlopezre/GitHub/LCC && flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```

Una regeneración puede reescribir structs generadas y romper call sites, históricamente en `gcloud_provider.dart` y `manual_instance_dialog.dart`. Arregla a mano el call site, nunca la salida generada, y di qué cambió.

- [ ] **Step 1: Wrappers del bridge**

En `native/src/api.rs`:

```rust
/// Whether SSH access to this VM already works, and as which user.
pub async fn probe_ssh_access(project_id: String, zone: String, instance_name: String)
    -> anyhow::Result<crate::ssh_access::SshAccessState> {
    crate::ssh_access::probe_ssh_access(project_id, zone, instance_name).await
}

/// Authorise LCC's key on this VM. Only call after the user has consented.
pub async fn provision_ssh_access(project_id: String, zone: String, instance_name: String)
    -> anyhow::Result<String> {
    crate::ssh_access::provision_ssh_access(project_id, zone, instance_name).await
}
```

- [ ] **Step 2: Regenera y comprueba que compila**

```bash
cd /home/jlopezre/GitHub/LCC && flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
cd native && cargo build --lib
cd /home/jlopezre/GitHub/LCC && flutter analyze
```

Esperado: `cargo build --lib` sin warnings; `flutter analyze` con **cero líneas `error •`**.

- [ ] **Step 3: Persistencia del consentimiento**

En `lib/src/services/storage_service.dart`, junto a los otros pares get/set:

```dart
  /// Whether the user has answered the SSH-key provisioning prompt for a
  /// project, and what they answered. A denial is remembered too: re-asking on
  /// every connection is not consent.
  Future<void> setSshProvisionConsent(String projectId, bool allowed) async {
    await _sharedPrefs.setBool('ssh_provision_consent_$projectId', allowed);
  }

  bool? getSshProvisionConsent(String projectId) {
    return _sharedPrefs.getBool('ssh_provision_consent_$projectId');
  }
```

- [ ] **Step 4: Claves i18n**

En `lib/l10n/app_en.arb`:

```json
  "sshConsentTitle": "Authorise LCC on this project?",
  "sshConsentBody": "To open SSH, SFTP and port forwards without gcloud, LCC needs an SSH key authorised on the VMs of {project}. It will add its own key to each VM as you connect to it — never to the project, so no other VM is affected.",
  "@sshConsentBody": {
    "placeholders": { "project": {"type": "String"} }
  },
  "sshConsentFingerprint": "Key: {fingerprint}",
  "@sshConsentFingerprint": {
    "placeholders": { "fingerprint": {"type": "String"} }
  },
  "sshConsentRemoval": "You can remove it any time from the VM's metadata: look for the entry commented 'lightweight-cloud-connector'.",
  "sshConsentAllow": "Authorise",
  "sshConsentDeny": "Not now",
  "sshConsentDenied": "LCC is not authorised to add an SSH key to this project, so SSH, SFTP and port forwards are unavailable. Authorise it from the VM's connection menu, or ask an administrator to authorise your key.",
```

Y en `lib/l10n/app_es.arb` los mismos identificadores:

```json
  "sshConsentTitle": "¿Autorizar LCC en este proyecto?",
  "sshConsentBody": "Para abrir SSH, SFTP y reenvíos de puerto sin gcloud, LCC necesita una clave SSH autorizada en las VMs de {project}. Añadirá su propia clave a cada VM según se vaya conectando a ella — nunca al proyecto, así que ninguna otra VM se ve afectada.",
  "sshConsentFingerprint": "Clave: {fingerprint}",
  "sshConsentRemoval": "Puede retirarla cuando quiera desde los metadatos de la VM: busque la entrada con el comentario 'lightweight-cloud-connector'.",
  "sshConsentAllow": "Autorizar",
  "sshConsentDeny": "Ahora no",
  "sshConsentDenied": "LCC no está autorizado a añadir una clave SSH en este proyecto, así que SSH, SFTP y los reenvíos de puerto no están disponibles. Puede autorizarlo desde el menú de conexión de la VM, o pedir a un administrador que autorice su clave.",
```

Luego:

```bash
flutter gen-l10n
```

- [ ] **Step 5: El diálogo**

Crea `lib/src/features/ssh_consent_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/ssh_access.dart';
import '../services/storage_service.dart';

/// Make sure SSH access to [instance] works, asking for consent the first time
/// LCC needs to write a key into [projectId].
///
/// Returns the username to log in as, or null when the user declined — the
/// caller then reports that SSH is unavailable rather than retrying.
Future<String?> ensureSshAccess(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  required String zone,
  required String instance,
}) async {
  final state = await probeSshAccess(
      projectId: projectId, zone: zone, instanceName: instance);

  if (state is SshAccessState_Ready) return state.username;
  final needs = state as SshAccessState_NeedsProvisioning;

  final storage = StorageService();
  final remembered = storage.getSshProvisionConsent(projectId);
  if (remembered == false) return null;

  if (remembered == null) {
    if (!context.mounted) return null;
    final allowed = await _askConsent(context, projectId, needs.keyFingerprint);
    await storage.setSshProvisionConsent(projectId, allowed);
    if (!allowed) return null;
  }

  return await provisionSshAccess(
      projectId: projectId, zone: zone, instanceName: instance);
}

Future<bool> _askConsent(
    BuildContext context, String projectId, String fingerprint) async {
  final l10n = AppLocalizations.of(context);
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sshConsentTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.sshConsentBody(projectId)),
            const SizedBox(height: 12),
            SelectableText(
              l10n.sshConsentFingerprint(fingerprint),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Text(l10n.sshConsentRemoval,
                style: Theme.of(dialogContext).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.sshConsentDeny),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.sshConsentAllow),
        ),
      ],
    ),
  );
  return answer ?? false;
}
```

**Comprueba el nombre real** del fichero de bridge generado para `ssh_access` y los nombres de las variantes del enum (`SshAccessState_Ready` es la convención de flutter_rust_bridge para enums con datos, pero confírmalo en la salida generada) y ajusta los imports. Dilo en el informe.

- [ ] **Step 6: Los tres call sites**

En `lib/src/features/workspace/sftp_tab.dart:31` y
`lib/src/features/workspace/ssh_terminal_tab.dart:29`, donde hoy está
`final username = await getUsername();`, este es el patrón exacto — adapta los
nombres de las variables de proyecto/zona/instancia a los de cada pestaña:

```dart
      final username = await ensureSshAccess(
        context,
        ref,
        projectId: widget.target.projectId,
        zone: widget.target.zone,
        instance: widget.target.name,
      );
      if (username == null) {
        if (!mounted) return;
        setState(() => _error = AppLocalizations.of(context).sshConsentDenied);
        return;
      }
```

En `lib/src/features/gcloud_provider.dart`, dentro de `_connectSshForward`, haz
lo mismo antes de llamar a `startSshForward`. Ese notifier no tiene `context`,
así que **pásalo desde el widget que dispara la conexión** en vez de inventar uno
—un diálogo necesita un `BuildContext` vivo— y di en el informe qué firma
cambiaste.

- [ ] **Step 7: Comprueba que todo sigue verde**

```bash
flutter analyze
flutter test
cd native && cargo test --lib
```

Esperado: cero líneas `error •`; `All tests passed!`; los tests de Rust en verde.

- [ ] **Step 8: Commit**

```bash
git add native/src/api.rs lib/src/bridge/ lib/src/services/storage_service.dart \
        lib/src/features/ssh_consent_dialog.dart lib/src/features/workspace/sftp_tab.dart \
        lib/src/features/workspace/ssh_terminal_tab.dart lib/src/features/gcloud_provider.dart \
        lib/l10n/
git commit -m "feat(ssh): ask once per project before authorising LCC's key

Provisioning writes to the user's own infrastructure, and LCC ships to
people connecting to production VMs. gcloud has done this silently for
years, but 'I modified your VM and did not tell you' is a security report
waiting to happen — the entry is visible in the GCP console with the name
of whoever put it there.

A denial is remembered too: re-asking on every connection is not consent."
```

---

### Task 8: Checklist de QA manual

**Files:**
- Create: `docs/superpowers/plans/2026-08-20-sp1-native-ssh-access-manual-qa.md`

**Contexto que necesitas:** el [estándar de verificación](../specs/2026-08-12-gcloud-removal-roadmap.md) es vinculante. Cada ítem nombra la evidencia exacta que lo demuestra. El entorno hostil se monta con `bwrap`, **no** con `chmod` — la receta de `chmod` produjo dos falsos verdes en el QA de D4 porque es estado global con tres pasos manuales.

- [ ] **Step 1: Escribe el documento**

````markdown
# QA manual — SP-1: acceso SSH nativo

**Build:** (rellenar con el `kBuild` probado)
**Requisito:** `LCC_AUTH_ENGINE=native`.

## Entorno hostil (para los ítems 3 y 4)

```bash
pkill -f lightweight_cloud_connector; sleep 2
bwrap --dev-bind / / --tmpfs /usr/lib/google-cloud-sdk --tmpfs "$HOME/.config/gcloud" sh -c '
  echo "gcloud: $(command -v gcloud || echo NINGUNO)"
  exec env LCC_AUTH_ENGINE=native ./build/linux/x64/release/bundle/lightweight_cloud_connector'
```

Verificable **después** del hecho, que es lo que lo hace inmune a errores de
secuencia: el PID cuyo `/proc/$P/ns/mnt` difiera del de la shell es el
sandboxeado, y en él `/proc/$P/root/usr/bin/gcloud` no debe existir.

## 1. Ruta rápida: la clave de gcloud ya vale

- [ ] Con `~/.ssh/google_compute_engine` presente y autorizada, abrir SFTP
      **no** muestra el diálogo de consentimiento y conecta.

**Evidencia:** el log no contiene `Published LCC's SSH key`, y los metadatos de
la VM no ganan ninguna entrada nueva:

```bash
gcloud compute instances describe <VM> --zone=<ZONA> \
  --format="value(metadata.items.filter(\"key:ssh-keys\").extract(\"value\"))" | grep -c lightweight-cloud-connector
```

Debe dar `0`. Si da `1`, se provisionó sin necesidad y la ruta rápida no
funciona.

## 2. Provisionado con consentimiento

Retira temporalmente la autorización (mueve `~/.ssh/google_compute_engine` y
`~/.ssh/id_*` fuera, y vacía el agente con `ssh-add -D`).

- [ ] Abrir SFTP muestra el diálogo, nombrando el proyecto y la huella.
- [ ] Al autorizar, la conexión se establece.

**Evidencia:** el log dice `Published LCC's SSH key to the instance metadata`
con la huella, y el `grep` de arriba pasa a dar `1`. En la consola de GCP la
entrada aparece con el comentario `lightweight-cloud-connector`.

## 3. Sin gcloud, desde cero

En el sandbox, y con las claves personales retiradas como en el ítem 2:

- [ ] SFTP conecta tras autorizar.
- [ ] Un reenvío SSH al 8443 se establece.

**Evidencia:** `/proc/$P/root/usr/bin/gcloud` inexistente, más las dos líneas
del log. Es el criterio de corte de SP-1.

## 4. La denegación se recuerda

- [ ] Denegar el diálogo deja SFTP sin conectar, con el mensaje que explica las
      salidas.
- [ ] Reintentar **no** vuelve a mostrar el diálogo.

**Evidencia:** el mensaje en pantalla, y que el segundo intento no abre diálogo.

## 5. No se destruyeron las claves de otros

Con una VM que ya tenga entradas `ssh-keys` de otro usuario, **antes** y
**después** de provisionar:

```bash
gcloud compute instances describe <VM> --zone=<ZONA> \
  --format="value(metadata.items.filter(\"key:ssh-keys\").extract(\"value\"))"
```

- [ ] Todas las entradas previas siguen ahí, y la nuestra se añadió.

**Evidencia:** las dos salidas, comparadas. **Este es el ítem que no se puede
saltar:** perder las claves de otros en un proyecto compartido es un incidente.

## 6. Permisos insuficientes

Con una cuenta sin `compute.instances.setMetadata` sobre la VM:

- [ ] El mensaje nombra el permiso que falta y las dos salidas reales.

**Evidencia:** el texto en pantalla, que debe contener
`compute.instances.setMetadata`. Un mensaje genérico es un fallo del ítem.

## 7. OS Login

Si hay una VM con `enable-oslogin=TRUE` a mano:

- [ ] Conecta, y el usuario es el POSIX (`usuario_dominio_com`), no el local.

**Evidencia:** el log de `Creating SSH session` con `username=` mostrando el
POSIX. **Si no hay ninguna VM con OS Login disponible, di que el ítem quedó sin
verificar** — no lo marques en verde por analogía.
````

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-20-sp1-native-ssh-access-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SP-1 native SSH access

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Cierre

1. `cd native && cargo test --lib` — verde. `cargo build --lib` — sin warnings.
2. `flutter analyze` — cero líneas `error •`.
3. `flutter test` — `All tests passed!`
4. Subir `kBuild` en `lib/src/version.dart`, `cargo build --release` y `flutter build linux --release`.
5. Revisión final de todo el rango del plan.

El **criterio de corte** es el ítem 3 del checklist —sin gcloud, desde cero,
SFTP y reenvío— junto con el ítem 5, que es el que protege a los demás usuarios
del proyecto. Ninguno de los dos es opcional.
