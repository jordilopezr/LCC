//! Formatting and merging of the `ssh-keys` instance metadata value.
//!
//! That value is a single blob with one `user:type key comment` entry per
//! line, shared by everyone with access to the VM. Merging — never
//! overwriting — is the whole point of this module: replacing the blob would
//! revoke every other user's SSH access, which on a shared project is an
//! incident rather than a bug.

/// Comment stamped on the key LCC publishes, so it can be found and removed.
pub(crate) const KEY_COMMENT: &str = "lightweight-cloud-connector";

/// Filename of LCC's private key, inside its `ssh` subdirectory of the app's
/// data directory. Named once here so `key_path` and `create_key_at` can never
/// drift onto different files.
const KEY_FILENAME: &str = "lcc_ed25519";

use anyhow::{anyhow, Context, Result};
use std::path::{Path, PathBuf};

/// LCC's own key pair: the public half in the one-line OpenSSH form GCP
/// wants, and its fingerprint. The private half is never carried on this
/// struct — nothing in the crate reads a private key by value, only by path
/// (see `key_path`), so keeping it here would just be a field nothing uses.
pub(crate) struct LccKey {
    pub public_openssh: String,
    pub fingerprint: String,
}

/// The directory LCC's key pair lives in: the app's data directory, NOT
/// `~/.ssh` — that directory belongs to the user and LCC has no business
/// writing there uninvited.
fn key_dir() -> Result<PathBuf> {
    Ok(crate::app_dirs::migrated_app_dir(
        dirs::data_local_dir().ok_or_else(|| anyhow!("Could not determine the data directory"))?,
    )
    .join("ssh"))
}

/// Where LCC's key lives, without generating one.
///
/// `create_ssh_session` needs to offer this key when it exists, and a login
/// attempt must never have the side effect of generating key material.
pub(crate) fn key_path() -> Result<PathBuf> {
    Ok(key_dir()?.join(KEY_FILENAME))
}

/// Load LCC's key, generating it on first use.
pub(crate) fn load_or_create_key() -> Result<LccKey> {
    create_key_at(&key_dir()?)
}

/// The directory is a parameter so the tests can use a throwaway one.
pub(crate) fn create_key_at(dir: &Path) -> Result<LccKey> {
    use ssh_key::{Algorithm, HashAlg, LineEnding, PrivateKey};

    std::fs::create_dir_all(dir)
        .with_context(|| format!("Could not create {}", dir.display()))?;
    let private_path = dir.join(KEY_FILENAME);

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
        tracing::info!(path = %private_path.display(), "Generated LCC's SSH key");
        key
    };

    // Unconditional, not just on the generation branch: a key file that ever
    // ends up loosened — backup/restore, a manual copy, external tooling —
    // must not stay loosened forever just because LCC didn't generate it
    // this time.
    harden_permissions(&private_path)?;

    // Without the comment: `format_entry` appends its own. `ssh-key` 0.6 has no
    // "encode without comment" call directly on the key's public half (unlike
    // the brief's assumed `key_data().encoded_string()`, which this resolved
    // version doesn't have) — so a comment-less clone of the public key is
    // encoded instead, via `PublicKey::to_openssh()`.
    let mut public = key.public_key().clone();
    public.set_comment("");
    let public_openssh = public
        .to_openssh()
        .map_err(|e| anyhow!("Could not encode the public key: {}", e))?;

    Ok(LccKey {
        public_openssh,
        fingerprint: key.public_key().fingerprint(HashAlg::Sha256).to_string(),
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

    /// A path that no other test run — even one that panicked and left its
    /// directory behind — can already occupy. PIDs get recycled across runs,
    /// so PID alone is not enough: a stale directory from an earlier panicked
    /// run would make `private_path.exists()` true and silently steer a later
    /// run onto the *read* branch instead of the *generate* branch, letting a
    /// real regression in generation hide behind stale state.
    fn unique_test_dir(name: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("el reloj no puede ir antes de 1970")
            .as_nanos();
        std::env::temp_dir().join(format!("{name}-{}-{nanos}", std::process::id()))
    }

    #[test]
    fn a_generated_key_is_a_usable_openssh_ed25519_pair() {
        let dir = unique_test_dir("lcc-key-test");
        let _ = std::fs::remove_dir_all(&dir);
        let key = super::create_key_at(&dir).expect("genera la clave");

        let private_path = dir.join(KEY_FILENAME);

        assert!(key.public_openssh.starts_with("ssh-ed25519 "), "no es ed25519: {}", key.public_openssh);
        assert!(!key.public_openssh.contains('\n'), "la pública debe ser una línea");
        assert!(key.fingerprint.starts_with("SHA256:"), "huella inesperada: {}", key.fingerprint);
        assert!(private_path.exists(), "no se escribió la privada");

        // La privada NO puede quedar legible por otros: es material secreto.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&private_path).unwrap().permissions().mode();
            assert_eq!(mode & 0o077, 0, "permisos demasiado abiertos: {:o}", mode);
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn creating_twice_reuses_the_same_key() {
        let dir = unique_test_dir("lcc-key-reuse");
        let _ = std::fs::remove_dir_all(&dir);
        let first = super::create_key_at(&dir).expect("primera");
        let second = super::create_key_at(&dir).expect("segunda");
        assert_eq!(first.public_openssh, second.public_openssh, "se regeneró la clave");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Finding 1 del round de revisión: una clave existente cuyos permisos se
    /// hayan relajado (backup/restore, copia manual, herramienta externa) debe
    /// quedar re-endurecida a 0600 en cada `create_key_at`, no solo cuando LCC
    /// la genera. Este test debe fallar si `harden_permissions` vuelve a vivir
    /// solo dentro de la rama `else`.
    #[test]
    #[cfg(unix)]
    fn reusing_an_existing_key_reharden_its_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let dir = unique_test_dir("lcc-key-reharden");
        let _ = std::fs::remove_dir_all(&dir);
        let private_path = dir.join(KEY_FILENAME);
        let first = super::create_key_at(&dir).expect("primera");

        std::fs::set_permissions(&private_path, std::fs::Permissions::from_mode(0o644))
            .expect("no se pudieron relajar los permisos para la prueba");
        let loosened = std::fs::metadata(&private_path).unwrap().permissions().mode();
        assert_eq!(loosened & 0o777, 0o644, "el setup de la prueba no relajó los permisos");

        let second = super::create_key_at(&dir).expect("segunda (reutiliza)");
        assert_eq!(first.public_openssh, second.public_openssh, "se regeneró la clave");

        let mode = std::fs::metadata(&private_path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "no se re-endurecieron los permisos: {:o}", mode);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
