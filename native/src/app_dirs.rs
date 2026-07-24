//! Application directory naming and one-time migration from the legacy name.
//!
//! Data and cache directories were historically named `linux_cloud_connector`.
//! After the rebrand to Lightweight Cloud Connector the canonical name is
//! `lightweight_cloud_connector`; existing directories are renamed in place the
//! first time they are resolved so users keep their logs and credentials index.

use std::path::PathBuf;

pub const APP_DIR_NAME: &str = "lightweight_cloud_connector";
const LEGACY_APP_DIR_NAME: &str = "linux_cloud_connector";

/// Resolve `base/lightweight_cloud_connector`, migrating `base/linux_cloud_connector`
/// by renaming it if it exists and the new directory does not.
///
/// The rename is best-effort: if it fails (permissions, cross-device), the new
/// path is still returned and callers create it as usual.
pub fn migrated_app_dir(base: PathBuf) -> PathBuf {
    let new_dir = base.join(APP_DIR_NAME);
    let old_dir = base.join(LEGACY_APP_DIR_NAME);
    if old_dir.is_dir() && !new_dir.exists() {
        let _ = std::fs::rename(&old_dir, &new_dir);
    }
    new_dir
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_legacy_directory() {
        let base = std::env::temp_dir().join(format!("lcc_appdirs_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join(LEGACY_APP_DIR_NAME).join("logs")).unwrap();
        std::fs::write(
            base.join(LEGACY_APP_DIR_NAME).join("logs").join("app.log"),
            b"x",
        )
        .unwrap();

        let dir = migrated_app_dir(base.clone());

        assert_eq!(dir, base.join(APP_DIR_NAME));
        assert!(dir.join("logs").join("app.log").exists());
        assert!(!base.join(LEGACY_APP_DIR_NAME).exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn keeps_existing_new_directory() {
        let base = std::env::temp_dir().join(format!("lcc_appdirs_test2_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join(APP_DIR_NAME)).unwrap();
        std::fs::create_dir_all(base.join(LEGACY_APP_DIR_NAME)).unwrap();

        let dir = migrated_app_dir(base.clone());

        // Both existed: nothing is renamed, the new dir wins.
        assert_eq!(dir, base.join(APP_DIR_NAME));
        assert!(base.join(LEGACY_APP_DIR_NAME).exists());
        let _ = std::fs::remove_dir_all(&base);
    }
}
