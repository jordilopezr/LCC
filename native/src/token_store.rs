//! Secure storage for OAuth refresh tokens, one entry per Google account.
//!
//! The secret itself lives in the OS keyring (GNOME Keyring / KWallet on Linux,
//! Keychain on macOS, Credential Manager on Windows). The keyring API cannot
//! enumerate its own entries, so a separate JSON index on disk tracks which
//! accounts exist and which one is active — it holds e-mail addresses only and
//! never a secret.

use anyhow::{anyhow, Context, Result};
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::{debug, info, warn};

/// The same keyring service the rest of the app uses.
const SERVICE_NAME: &str = "linux-cloud-connector";

/// What is stored in the keyring for one account. `refresh_token` is a secret
/// and must never be written anywhere but the keyring.
#[derive(Clone, Serialize, Deserialize)]
pub struct StoredAccount {
    pub email: String,
    pub refresh_token: String,
    /// RFC 3339, for FFI consistency with the rest of the repo.
    pub added_at: String,
}

/// Hand-written so the secret never leaks into a log line through `{:?}`.
impl std::fmt::Debug for StoredAccount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoredAccount")
            .field("email", &self.email)
            .field("refresh_token", &"<redacted>")
            .field("added_at", &self.added_at)
            .finish()
    }
}

/// The on-disk index. E-mail addresses only — never a secret. `#[serde(default)]`
/// so that a future added field never turns an existing index file unreadable
/// on upgrade — a missing field just takes its default instead of the whole
/// document failing to parse.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
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
        // Distinct wording from the "no stored session" case in
        // `load_refresh_token`: that one means "nothing in the keyring for
        // this e-mail", this one means "the index doesn't know this e-mail at
        // all". Callers classify on message text, so the two must not collide.
        return Err(anyhow!("{} is not a known account", email));
    }
    index.active = Some(email.to_string());
    Ok(())
}

/// Path to the index that tracks stored accounts. It exists because the keyring
/// API cannot enumerate its own entries.
fn index_file_path() -> Option<PathBuf> {
    let mut path = crate::app_dirs::migrated_app_dir(dirs::data_local_dir()?);
    path.push("oauth_accounts.json");
    Some(path)
}

/// Parse index file contents leniently. Pulled out of `load_index` so the
/// degradation contract (malformed/truncated/unknown-shaped JSON all read as
/// empty rather than erroring) can be unit-tested without touching disk.
fn parse_index(contents: &str) -> AccountIndex {
    serde_json::from_str(contents).unwrap_or_else(|e| {
        warn!("Account index is unreadable, treating it as empty: {}", e);
        AccountIndex::default()
    })
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
        Ok(contents) => parse_index(&contents),
        Err(e) => {
            warn!("Could not read the account index: {}", e);
            AccountIndex::default()
        }
    }
}

/// Write via a temp file plus rename, so a crash or full disk mid-write can
/// never leave a truncated index on disk. Since the keyring cannot enumerate
/// its own entries, a truncated index would otherwise orphan every other
/// account's secret — unlisted and undeletable through the public API.
fn save_index(index: &AccountIndex) -> Result<()> {
    let path = index_file_path().ok_or_else(|| anyhow!("Cannot determine the data directory"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create the data directory")?;
    }
    let json = serde_json::to_string(index).context("Failed to serialize the account index")?;
    let mut tmp_path = path.clone();
    let tmp_name = format!(
        "{}.tmp",
        path.file_name()
            .ok_or_else(|| anyhow!("Account index path has no file name"))?
            .to_string_lossy()
    );
    tmp_path.set_file_name(tmp_name);
    std::fs::write(&tmp_path, json).context("Failed to write the account index")?;
    std::fs::rename(&tmp_path, &path).context("Failed to finalize the account index")?;
    Ok(())
}

/// Open the keyring entry for `email`. `Entry::new` is a pure constructor —
/// it never touches the backend — so a failure here means the service/key
/// values themselves are invalid, not that the keyring is unreachable. A
/// down backend only becomes visible once the entry is actually used; see
/// `keyring_backend_error`.
fn entry_for(email: &str) -> Result<Entry> {
    Entry::new(SERVICE_NAME, &keyring_key(email))
        .map_err(|e| anyhow!("Invalid keyring entry for {}: {}", email, e))
}

/// Classify an error from an actual keyring store/read/delete call.
///
/// Two backend failures, two messages, because they are two different fixes:
/// an unreachable backend (`PlatformFailure`) usually means no Secret Service
/// is running; a refusing one (`NoStorageAccess`) is running but locked, or
/// its unlock prompt was dismissed. Both used to say "no Secret Service is
/// running", which is false for the second. Anything else gets a generic
/// wrapped message.
fn keyring_backend_error(e: keyring::Error, verb: &str) -> anyhow::Error {
    match &e {
        keyring::Error::PlatformFailure(_) => anyhow!(
            "The system keyring could not be reached, so the sign-in cannot be {}. \
             On Linux this usually means no Secret Service (GNOME Keyring or \
             KWallet) is running: {}",
            verb,
            e
        ),
        // Measured: a locked collection, or an unlock prompt the user
        // dismissed, lands here. A Secret Service IS running, so this message
        // must not send the user off to start one.
        keyring::Error::NoStorageAccess(_) => anyhow!(
            "The system keyring refused access, so the sign-in cannot be {}: it is \
             locked, or the unlock was cancelled: {}",
            verb,
            e
        ),
        _ => anyhow!(
            "Failed to {} the sign-in in the system keyring: {}",
            verb,
            e
        ),
    }
}

/// Store (or replace) the sign-in for `email`. The keyring is written first and
/// the index second. If the index write then fails: for a brand-new account
/// the keyring entry is rolled back, so no secret is left behind that nothing
/// lists; for an account that already existed, the previous credential has
/// already been overwritten in the keyring, so rolling back would destroy a
/// working sign-in and leave the account in a worse state than doing nothing —
/// the index is simply left stale and the error is reported.
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
        .map_err(|e| keyring_backend_error(e, "saved"))?;

    let mut index = load_index();
    let already_present = index.accounts.iter().any(|a| a == email);
    index_upsert(&mut index, email);
    if let Err(e) = save_index(&index) {
        if !already_present {
            let _ = entry.delete_credential();
            return Err(e.context("Rolled back the stored sign-in"));
        }
        return Err(e.context(
            "The sign-in was updated in the keyring, but the account index could not be updated to match",
        ));
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
        Err(e) => return Err(keyring_backend_error(e, "read")),
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
        Err(e) => return Err(keyring_backend_error(e, "deleted")),
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

/// A keyring key that belongs to no account. `keyring_key` prefixes every
/// account with `oauth::`, so nothing here can collide with a real one.
const PROBE_KEY: &str = "doctor::probe";

/// What the probe concludes from what the backend said.
///
/// `NoEntry` is the healthy answer: the service replied and holds no such
/// record. Treating a down backend as health is the defect this row exists to
/// detect — see the sub-project that shipped a token store persisting nothing.
///
/// Pulled out of `probe_keyring` so the decision can be exercised against a
/// fabricated `keyring::Error` without a real backend: a test that only calls
/// `keyring_backend_error` pins the classifier's wording, not whether the
/// probe actually routes through it.
fn classify_probe(result: std::result::Result<String, keyring::Error>) -> Result<()> {
    match result {
        Ok(_) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(keyring_backend_error(e, "read")),
    }
}

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
    classify_probe(entry.get_password())
}

/// What reading the account's own keyring entry says about using it now.
///
/// `auth_status` used to answer "is there an active account?" from the index
/// alone, and the whole app read that as "can I use its credential?". With the
/// keyring down or locked the app believed itself signed in and retried
/// listings that could not succeed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CredentialState {
    /// The entry was read. Its value is dropped on the spot, never logged.
    Readable,
    /// The backend answered and holds no entry for this account.
    Missing,
    /// No Secret Service answered (`PlatformFailure`), e.g. no D-Bus session.
    Unreachable,
    /// A Secret Service answered and refused (`NoStorageAccess`): the
    /// collection is locked, or the unlock prompt was dismissed.
    Refused,
    /// No answer within the deadline: most likely an unlock prompt is waiting
    /// for the user.
    Pending,
    /// Any other error. Treated as usable, today's behaviour: nothing we cannot
    /// classify may put up a keyring screen that could be false.
    Unclear,
}

/// Pure, so each outcome is testable with a fabricated `keyring::Error`.
fn classify_credential(result: std::result::Result<String, keyring::Error>) -> CredentialState {
    match result {
        Ok(_) => CredentialState::Readable,
        Err(keyring::Error::NoEntry) => CredentialState::Missing,
        Err(keyring::Error::PlatformFailure(_)) => CredentialState::Unreachable,
        Err(keyring::Error::NoStorageAccess(_)) => CredentialState::Refused,
        Err(_) => CredentialState::Unclear,
    }
}

/// Read `email`'s real entry — not the probe key. "Backend up but this
/// account's entry is gone" is also permanent, and the probe would call it
/// healthy.
fn read_credential(email: &str) -> CredentialState {
    match Entry::new(SERVICE_NAME, &keyring_key(email)) {
        Ok(entry) => classify_credential(entry.get_password()),
        Err(_) => CredentialState::Unclear,
    }
}

/// How long `auth_status` waits for the keyring before calling the credential
/// `Pending`.
///
/// The whole dashboard body hangs on the auth status, so an unanswered unlock
/// prompt must not hold it. The machine answers in about 69 ms (measured) and
/// under 1 ms when the service is down; 3 s is roughly 40 times that plus room
/// for a D-Bus activation start (an estimate, not measured). Past it, the one
/// still to answer is a person, and telling someone mid-typing "waiting for you
/// to unlock" is true, whereas a longer deadline leaves the whole app blank.
pub(crate) const CREDENTIAL_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

type Slot = tokio::sync::watch::Receiver<Option<CredentialState>>;
type Slots = std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, Slot>>>;

/// At most one keyring read per account at a time.
///
/// A read that outlasts its deadline is not cancelled: the unlock prompt stays
/// answerable, and later checks join the same read instead of starting another
/// one — so pressing "Check again" with the prompt still open does not stack
/// prompts, whatever the keyring would do with two.
#[derive(Default)]
struct InFlightReads {
    slots: Slots,
}

/// Frees an account's slot when its read ends — including by panic, so a dead
/// reader cannot leave every later check joined to a slot nobody will fill.
struct FreeSlot {
    slots: Slots,
    email: String,
}

impl Drop for FreeSlot {
    fn drop(&mut self) {
        self.slots.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.email);
    }
}

impl InFlightReads {
    async fn state<R>(&self, email: &str, timeout: std::time::Duration, read: R) -> CredentialState
    where
        R: FnOnce() -> CredentialState + Send + 'static,
    {
        let mut slot = {
            let mut slots = self.slots.lock().unwrap_or_else(|p| p.into_inner());
            match slots.get(email) {
                Some(slot) => slot.clone(),
                None => {
                    let (tx, rx) = tokio::sync::watch::channel(None);
                    slots.insert(email.to_string(), rx.clone());
                    let free = FreeSlot { slots: self.slots.clone(), email: email.to_string() };
                    tokio::task::spawn_blocking(move || {
                        let state = read();
                        // Free before publishing, so a caller that sees this
                        // answer and asks again starts a fresh read.
                        drop(free);
                        let _ = tx.send(Some(state));
                    });
                    rx
                }
            }
        };
        let state = match tokio::time::timeout(timeout, slot.wait_for(Option::is_some)).await {
            Ok(Ok(state)) => (*state).unwrap_or(CredentialState::Unclear),
            // The reader ended without an answer (it panicked).
            Ok(Err(_)) => CredentialState::Unclear,
            Err(_) => CredentialState::Pending,
        };
        state
    }
}

static CREDENTIAL_READS: std::sync::LazyLock<InFlightReads> =
    std::sync::LazyLock::new(InFlightReads::default);

/// `email`'s credential state, waiting at most `timeout` for the keyring.
pub(crate) async fn credential_state_within(
    email: &str,
    timeout: std::time::Duration,
) -> CredentialState {
    let owned = email.to_string();
    CREDENTIAL_READS.state(email, timeout, move || read_credential(&owned)).await
}

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

/// The verdict, given whether the backend answered at all and what the
/// per-account scan found.
///
/// The scan is the only thing that used to talk to the keyring, and it runs
/// once per listed account — so with an **empty** index it never ran, and
/// `classify_index(vec![], Some(vec![]))` returned `Consistent(0)`: the row
/// saying "all present in the keyring" about a keyring nobody asked, with the
/// Secret Service down. Requiring an answer from the probe first is what makes
/// the empty case able to say it could not tell.
fn index_verdict(
    backend_answered: bool,
    listed: Vec<String>,
    present: Option<Vec<String>>,
) -> IndexHealth {
    if !backend_answered {
        return IndexHealth::Unavailable;
    }
    classify_index(listed, present)
}

/// Compare the on-disk index against the keyring **without repairing it**.
///
/// `list_accounts` prunes orphans on the way out and saves the pruned index,
/// so a check built on it would never see anything. This reads the raw index
/// first.
///
/// The probe runs before the scan so that "the index is empty" and "the
/// keyring is unreachable" stay distinguishable. It is one extra read of a key
/// that cannot exist, and it never writes.
pub fn index_health() -> IndexHealth {
    let backend_answered = probe_keyring().is_ok();
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
    index_verdict(backend_answered, listed, Some(present))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// La prueba negativa de la sonda: la clave que usa no puede colisionar
    /// con la de ninguna cuenta. Si colisionara, Doctor leería el token de un
    /// usuario real para decidir si el llavero responde.
    #[test]
    fn the_probe_key_can_belong_to_no_account() {
        assert_ne!(PROBE_KEY, keyring_key(""));
        assert_ne!(PROBE_KEY, keyring_key("someone@example.com"));
        assert!(!PROBE_KEY.starts_with("oauth::"));
    }

    /// La sonda tiene que distinguir "el servicio respondió y no hay registro"
    /// de "el servicio no está". Si tratara ambos como salud, Doctor daría
    /// verde con el llavero caído, que es exactamente lo que pasó en D2.
    #[test]
    fn a_down_backend_is_not_health() {
        let down = keyring_backend_error(
            keyring::Error::PlatformFailure(Box::new(std::io::Error::other("no service"))),
            "read",
        );
        assert!(down.to_string().contains("could not be reached"), "{down}");
    }

    /// Medido el 2026-09-30: con el llavero bloqueado y el diálogo cancelado,
    /// keyring devuelve NoStorageAccess ("SS error: prompt dismissed"). Hay un
    /// Secret Service en marcha; decirle al usuario que arranque uno es mandarle
    /// a arreglar algo que no está roto.
    #[test]
    fn a_locked_keyring_is_not_reported_as_a_missing_service() {
        let refused = keyring_backend_error(
            keyring::Error::NoStorageAccess(Box::new(std::io::Error::other(
                "SS error: prompt dismissed",
            ))),
            "read",
        )
        .to_string();
        assert!(refused.contains("refused access"), "{refused}");
        assert!(refused.contains("locked"), "{refused}");
        assert!(!refused.contains("Secret Service"), "{refused}");
    }

    /// El guardián real de la sonda: ejercita `classify_probe`, que es lo que
    /// `probe_keyring` llama de verdad. Un guardián sobre `keyring_backend_error`
    /// a solas no dice nada de si la sonda pasa por él o lo esquiva.
    #[test]
    fn classify_probe_treats_a_down_backend_as_failure_not_entry_as_health() {
        let down = classify_probe(Err(keyring::Error::PlatformFailure(Box::new(
            std::io::Error::other("no service"),
        ))));
        let down_err = down.expect_err("a down backend must not classify as Ok");
        assert!(down_err.to_string().contains("could not be reached"));

        let refused = classify_probe(Err(keyring::Error::NoStorageAccess(Box::new(
            std::io::Error::other("locked"),
        ))));
        assert!(refused.is_err(), "a refused backend is not health either");

        assert!(classify_probe(Err(keyring::Error::NoEntry)).is_ok());
        assert!(classify_probe(Ok("irrelevant".to_string())).is_ok());
    }

    fn io(msg: &str) -> Box<dyn std::error::Error + Send + Sync> {
        Box::new(std::io::Error::other(msg.to_string()))
    }

    /// Las cinco salidas, cada una con el error que la produce. Las de
    /// PlatformFailure y NoStorageAccess reproducen lo medido el 2026-09-30.
    #[test]
    fn classify_credential_names_each_outcome() {
        assert_eq!(classify_credential(Ok("secret".into())), CredentialState::Readable);
        assert_eq!(classify_credential(Err(keyring::Error::NoEntry)), CredentialState::Missing);
        assert_eq!(
            classify_credential(Err(keyring::Error::PlatformFailure(io(
                "no secret service provider or dbus session found"
            )))),
            CredentialState::Unreachable
        );
        assert_eq!(
            classify_credential(Err(keyring::Error::NoStorageAccess(io("SS error: prompt dismissed")))),
            CredentialState::Refused
        );
        assert_eq!(
            classify_credential(Err(keyring::Error::BadEncoding(vec![0xff]))),
            CredentialState::Unclear
        );
    }

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

    /// El guardián del índice vacío. Sin cuentas el bucle de comparación no
    /// corre, así que `Consistent(0)` —"todas presentes en el llavero"— se
    /// afirmaba sobre un llavero al que nadie preguntó. Con el Secret Service
    /// caído la fila salía en verde. `index_verdict` exige que el backend haya
    /// contestado ANTES de poder concluir nada.
    #[test]
    fn an_empty_index_cannot_be_called_consistent_when_the_keyring_is_silent() {
        assert_eq!(
            index_verdict(false, vec![], Some(vec![])),
            IndexHealth::Unavailable
        );
    }

    /// Y con el backend contestando, el índice vacío sigue siendo consistente:
    /// el arreglo no puede volver amarilla la instalación recién hecha.
    #[test]
    fn an_empty_index_with_a_live_keyring_is_still_consistent() {
        assert_eq!(
            index_verdict(true, vec![], Some(vec![])),
            IndexHealth::Consistent(0)
        );
    }

    /// Un backend que contesta no rescata un escaneo que se quedó a medias:
    /// `present == None` sigue siendo "no se puede saber".
    #[test]
    fn a_live_probe_does_not_override_a_scan_that_could_not_finish() {
        assert_eq!(
            index_verdict(true, vec!["a@example.com".into()], None),
            IndexHealth::Unavailable
        );
    }

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
    fn index_remove_of_absent_email_is_a_no_op() {
        let mut index = AccountIndex::default();
        index_upsert(&mut index, "a@b.com");
        let before = index.clone();
        index_remove(&mut index, "nobody@x.com");
        assert_eq!(index, before);
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

    /// The index degradation contract this module documents: garbage on disk
    /// must never surface as an error, only ever as an empty index.
    #[test]
    fn parse_index_malformed_json_reads_as_empty() {
        let index = parse_index("not json at all");
        assert_eq!(index, AccountIndex::default());
    }

    #[test]
    fn parse_index_truncated_json_reads_as_empty() {
        let index = parse_index(r#"{"accounts": ["a@b.com"], "acti"#);
        assert_eq!(index, AccountIndex::default());
    }

    /// A document from a future version with an extra field must still parse
    /// — `#[serde(default)]` plus serde's own "ignore unknown fields" default
    /// keep an upgrade from orphaning every stored account.
    #[test]
    fn parse_index_with_unknown_field_still_parses() {
        let index =
            parse_index(r#"{"accounts": ["a@b.com"], "active": null, "future_field": 42}"#);
        assert_eq!(index.accounts, vec!["a@b.com".to_string()]);
        assert!(index.active.is_none());
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

    /// Restores the real on-disk index to what it was before the round-trip
    /// test ran, and removes any stray keyring entry for the test account —
    /// on success *and* on a failed assertion (panics still run `Drop`).
    struct RoundTripGuard {
        original_index: AccountIndex,
        email: &'static str,
    }

    impl Drop for RoundTripGuard {
        fn drop(&mut self) {
            if let Ok(entry) = entry_for(self.email) {
                let _ = entry.delete_credential();
            }
            let _ = save_index(&self.original_index);
        }
    }

    /// Exercises the real keyring. Ignored by default because it needs a live
    /// Secret Service, and it mutates the real account index (it cleans up
    /// after itself, even if an assertion below fails).
    #[test]
    #[ignore] // Requires system keyring
    fn save_load_delete_round_trip() {
        let email = "d2-round-trip@example.test";
        let _guard = RoundTripGuard {
            original_index: load_index(),
            email,
        };

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
}

#[cfg(test)]
mod credential_read_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc};
    use std::time::Duration;

    const SHORT: Duration = Duration::from_millis(50);
    const LONG: Duration = Duration::from_secs(5);

    /// A reader that blocks until the test sends it the answer, and counts how
    /// many reads were started.
    fn gated(
        count: &Arc<AtomicUsize>,
    ) -> (mpsc::Sender<CredentialState>, impl FnOnce() -> CredentialState + Send + 'static) {
        let (tx, rx) = mpsc::channel();
        let count = count.clone();
        let reader = move || {
            count.fetch_add(1, Ordering::SeqCst);
            rx.recv().unwrap_or(CredentialState::Unclear)
        };
        (tx, reader)
    }

    #[tokio::test]
    async fn a_quick_answer_is_returned_not_pending() {
        let reads = InFlightReads::default();
        let state = reads.state("a@x", LONG, || CredentialState::Readable).await;
        assert_eq!(state, CredentialState::Readable);
    }

    /// The defect this deadline exists for: the whole dashboard body hangs on
    /// gcloudStatusProvider (main.dart:625), and an unanswered unlock prompt
    /// kept the read waiting for more than 180 s.
    #[tokio::test]
    async fn a_read_that_outlasts_the_deadline_is_pending() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, reader) = gated(&count);
        let reads = InFlightReads::default();

        assert_eq!(reads.state("a@x", SHORT, reader).await, CredentialState::Pending);
        let _ = answer.send(CredentialState::Readable);
    }

    /// Pressing "Check again" with the prompt still open, maybe behind the
    /// window, must not start a second read: we do not know how the keyring
    /// handles two unlock prompts, and this way it does not matter.
    #[tokio::test]
    async fn a_second_check_while_waiting_joins_the_same_read() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, first) = gated(&count);
        let (_unused, second) = gated(&count);
        let reads = InFlightReads::default();

        assert_eq!(reads.state("a@x", SHORT, first).await, CredentialState::Pending);
        assert_eq!(reads.state("a@x", SHORT, second).await, CredentialState::Pending);
        assert_eq!(count.load(Ordering::SeqCst), 1, "a second read was started");
        let _ = answer.send(CredentialState::Readable);
    }

    /// The read is not cancelled at the deadline: when the user finally
    /// unlocks, a waiter still inside its own deadline gets the real answer.
    #[tokio::test]
    async fn a_waiter_gets_the_answer_when_it_arrives() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, reader) = gated(&count);
        let reads = Arc::new(InFlightReads::default());

        assert_eq!(reads.state("a@x", SHORT, reader).await, CredentialState::Pending);
        let joined = {
            let reads = reads.clone();
            tokio::spawn(async move { reads.state("a@x", LONG, || CredentialState::Unclear).await })
        };
        tokio::time::sleep(Duration::from_millis(20)).await;
        answer.send(CredentialState::Refused).unwrap();

        assert_eq!(joined.await.unwrap(), CredentialState::Refused);
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    /// Once a read has answered, the next check starts a fresh one: a stale
    /// answer must not stand for the keyring's state now.
    #[tokio::test]
    async fn an_answered_read_is_not_reused() {
        let reads = InFlightReads::default();
        assert_eq!(reads.state("a@x", LONG, || CredentialState::Refused).await, CredentialState::Refused);
        assert_eq!(reads.state("a@x", LONG, || CredentialState::Readable).await, CredentialState::Readable);
    }

    #[tokio::test]
    async fn different_accounts_do_not_share_a_read() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, blocked) = gated(&count);
        let reads = InFlightReads::default();

        assert_eq!(reads.state("old@x", SHORT, blocked).await, CredentialState::Pending);
        assert_eq!(reads.state("new@x", LONG, || CredentialState::Readable).await, CredentialState::Readable);
        let _ = answer.send(CredentialState::Readable);
    }

    #[tokio::test]
    async fn a_reader_that_dies_leaves_no_stale_slot() {
        let reads = InFlightReads::default();
        let died = reads
            .state("a@x", LONG, || -> CredentialState { panic!("reader died") })
            .await;
        assert_eq!(died, CredentialState::Unclear);
        assert_eq!(reads.state("a@x", LONG, || CredentialState::Readable).await, CredentialState::Readable);
    }
}
