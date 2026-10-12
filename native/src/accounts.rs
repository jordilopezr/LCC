//! Account management: list, switch, add, remove, and the projects visible to
//! each account.
//!
//! This module is the single place that decides whether an account operation
//! is served by the `gcloud` CLI or by LCC's own token store, so D5 removes
//! one arm from one file rather than unpicking six `match` blocks scattered
//! across the bridge wrappers.

use anyhow::{anyhow, Result};
use std::future::Future;

use crate::gcloud::GcloudAccount;
use crate::oauth::{AuthEngine, RefreshOutcome, RefreshedToken};
use crate::token_store::CredentialState;
use crate::validation::validate_email;

/// Which implementation serves an account operation. Private: dispatching is
/// this module's job and nobody else's.
enum Route {
    Gcloud,
    Native,
}

/// Every public operation in this module decides with this and nothing else.
/// A hardwired arm — or an operation that forgets to ask — is the failure this
/// separation exists to make visible.
fn route(engine: AuthEngine) -> Route {
    match engine {
        AuthEngine::Gcloud => Route::Gcloud,
        AuthEngine::Native => Route::Native,
    }
}

/// Which gcloud auth command the user has to run themselves.
pub(crate) enum GcloudAuthAction<'a> {
    Add,
    Remove(&'a str),
    RemoveAll,
}

/// Under the gcloud engine LCC does not touch gcloud's own credentials — the
/// user maintains that session. The message carries the exact command, because
/// "LCC cannot do this" without saying what can is a dead end.
fn gcloud_auth_instruction(action: GcloudAuthAction<'_>) -> anyhow::Error {
    match action {
        GcloudAuthAction::Add => anyhow!(
            "With the gcloud engine selected, LCC does not sign in for you. \
             Run this in a terminal, then refresh:\n\n    gcloud auth login"
        ),
        GcloudAuthAction::Remove(email) => anyhow!(
            "With the gcloud engine selected, LCC does not revoke gcloud's own \
             credentials. Run this in a terminal, then refresh:\n\n    gcloud auth revoke {}",
            email
        ),
        GcloudAuthAction::RemoveAll => anyhow!(
            "With the gcloud engine selected, LCC does not revoke gcloud's own \
             credentials. Run this in a terminal, then refresh:\n\n    gcloud auth revoke --all"
        ),
    }
}

/// Present the stored accounts in the shape the Dart layer already consumes.
///
/// `status` is `"ACTIVE"` for the active account and `""` for the rest —
/// the exact contract `AccountNotifier` reads. Order follows the index, which
/// is the order the dialog shows.
fn to_accounts(emails: Vec<String>, active: Option<String>) -> Vec<GcloudAccount> {
    emails
        .into_iter()
        .map(|email| {
            let is_active = active.as_deref() == Some(email.as_str());
            GcloudAccount {
                account: email,
                status: if is_active { "ACTIVE".to_string() } else { String::new() },
            }
        })
        .collect()
}

/// Whether gcloud is present, whether there is a usable session, and whether
/// gcloud is required at all.
///
/// `gcloud_required` exists because a missing gcloud is only fatal on the
/// gcloud route: the dashboard replaces its whole body with an "install the
/// SDK" screen when gcloud is absent, and under the native engine that screen
/// would hide a perfectly working session. Consumers gate that screen on this
/// flag, not on `gcloud_installed` alone.
pub struct AuthStatus {
    pub gcloud_installed: bool,
    pub authenticated: bool,
    pub gcloud_required: bool,
    /// Under the native engine, why `authenticated` is false although the
    /// index has an active account: the keyring kept its sign-in out of reach.
    /// Always `None` under the gcloud engine.
    pub keyring_problem: Option<KeyringProblem>,
}

/// Why the keyring kept the active account's sign-in out of reach. Each one
/// gets its own wording on the dashboard, because each is a different fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyringProblem {
    /// No Secret Service answered.
    Unreachable,
    /// The keyring is locked, or its unlock prompt was dismissed.
    Refused,
    /// No answer within the deadline: an unlock prompt is probably waiting.
    Pending,
}

/// Decide the session state from the engine and what each source said.
///
/// The native arm deliberately ignores `gcloud_installed`: the Dart provider
/// used to short-circuit on it, so on a machine without gcloud the account
/// dialog never even asked for the list — no matter how native the store
/// behind it was. `gcloud_installed` keeps telling the truth about gcloud
/// either way, because Doctor and the dependency row read it — and
/// `gcloud_required` says whether that truth should block the UI.
///
/// `native_credential` is `None` when the index has no active account, and
/// otherwise what reading that account's keyring entry said. Only a readable
/// credential is a session; `Unclear` keeps the old answer, so a keyring error
/// nobody has classified cannot put up a keyring screen that may be false.
fn auth_status_for(
    engine: AuthEngine,
    gcloud_installed: bool,
    gcloud_authenticated: bool,
    native_credential: Option<CredentialState>,
) -> AuthStatus {
    let (authenticated, keyring_problem) = match route(engine) {
        Route::Gcloud => (gcloud_installed && gcloud_authenticated, None),
        Route::Native => match native_credential {
            None => (false, None),
            Some(CredentialState::Readable | CredentialState::Unclear) => (true, None),
            Some(CredentialState::Missing) => (false, None),
            Some(CredentialState::Unreachable) => (false, Some(KeyringProblem::Unreachable)),
            Some(CredentialState::Refused) => (false, Some(KeyringProblem::Refused)),
            Some(CredentialState::Pending) => (false, Some(KeyringProblem::Pending)),
        },
    };
    // Pure, so the flag the dashboard gate reads is unit-testable without a
    // machine that lacks gcloud.
    let gcloud_required = matches!(route(engine), Route::Gcloud);
    AuthStatus { gcloud_installed, authenticated, gcloud_required, keyring_problem }
}

/// Revoke at Google, then delete locally — and delete locally even when the
/// revocation failed.
///
/// Keeping the local entry because Google did not answer is the worse of the
/// two outcomes: the user is left looking at an account that no longer works
/// and cannot remove it. The revocation failure is logged, not propagated.
async fn revoke_then_delete<R, RF, D, DF>(email: &str, revoke: R, delete: D) -> Result<()>
where
    R: FnOnce(String) -> RF,
    RF: Future<Output = Result<()>>,
    D: FnOnce(String) -> DF,
    DF: Future<Output = Result<()>>,
{
    if let Err(e) = revoke(email.to_string()).await {
        tracing::warn!(
            error = %e,
            "Could not revoke the account at Google; removing it locally anyway"
        );
    }
    delete(email.to_string()).await
}

/// The exact wording `classifyRustError` (Dart) maps to `notAuthenticated`.
fn no_active_account_error() -> anyhow::Error {
    anyhow!("No active GCP account")
}

/// Turn a refresh outcome into an access token, or into the signal the session
/// banner recognises.
fn token_from_outcome(email: &str, outcome: RefreshOutcome) -> Result<String> {
    match outcome {
        RefreshOutcome::Token(RefreshedToken { access_token, .. }) => Ok(access_token),
        // `invalid_grant` is what `classifyRustError` looks for; without it a
        // dead token reads as a generic failure and offers the user no way out.
        RefreshOutcome::NeedsReauth => Err(anyhow!(
            "Session expired for {} (invalid_grant); sign in again",
            email
        )),
    }
}

/// An access token for `email`, minted from that account's stored refresh
/// token. Never reads or writes the active account's token cache.
async fn access_token_for_account(email: &str) -> Result<String> {
    validate_email(email)?;
    let owned = email.to_string();
    let refresh_token =
        crate::oauth::store_call(move || crate::token_store::load_refresh_token(&owned)).await??;
    let outcome = crate::oauth::refresh_access_token(&refresh_token).await?;
    token_from_outcome(email, outcome)
}

/// Run a blocking `gcloud` invocation off the async runtime.
///
/// These shell out with `std::process::Command`. They used to reach Rust
/// through the bridge's synchronous path, which runs on a plain thread pool;
/// exposing them as `async fn` moves them onto the shared tokio runtime, where
/// a blocking call would otherwise pin a worker.
async fn gcloud_call<T, F>(f: F) -> Result<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("gcloud task failed: {}", e))
}

// ==========================================
// Public operations — every one dispatches on `route(auth_engine())`
// ==========================================

/// Every known account, with the active one flagged.
pub async fn list() -> Result<Vec<GcloudAccount>> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::list_gcloud_accounts_async().await,
        Route::Native => {
            let emails = crate::oauth::store_call(crate::token_store::list_accounts).await?;
            let active = crate::oauth::store_call(crate::token_store::active_account).await?;
            Ok(to_accounts(emails, active))
        }
    }
}

/// Make `email` the active account.
pub async fn switch(email: &str) -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::switch_gcloud_account_async(email).await,
        Route::Native => {
            validate_email(email)?;
            let owned = email.to_string();
            // Propagated, not swallowed: an unknown account must leave the
            // previous choice untouched and say so.
            crate::oauth::store_call(move || crate::token_store::set_active_account(&owned))
                .await??;
            // The cached token belongs to the account we just left.
            crate::gcp_rest_client::invalidate_cached_access_token().await;
            Ok(())
        }
    }
}

/// Sign in to another account and store it.
///
/// This does NOT make the new account active when one already is: switching is
/// `switch`, which is where the Dart layer disconnects tunnels and saves the
/// outgoing account's project selection. `save_account` sets the active
/// account only when there was none, which is what a first sign-in wants.
pub async fn add() -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => Err(gcloud_auth_instruction(GcloudAuthAction::Add)),
        Route::Native => {
            crate::oauth::sign_in_and_store().await?;
            Ok(())
        }
    }
}

/// Renew the current session after it has expired.
///
/// This is what the "Reauthenticate" banner button calls. Under the native
/// engine it MUST run LCC's own sign-in: `gcloud auth login` writes gcloud's
/// credentials and never touches the token store, so pointing this at gcloud
/// left a native session with a dead refresh token unrecoverable — the button
/// said "Reauthenticate" and could not reauthenticate. `sign_in_and_store`
/// upserts, so the dead refresh token is replaced in place.
pub async fn reauthenticate() -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => Err(gcloud_auth_instruction(GcloudAuthAction::Add)),
        Route::Native => {
            crate::oauth::sign_in_and_store().await?;
            Ok(())
        }
    }
}

/// Revoke `email` at Google and forget it locally.
pub async fn remove(email: &str) -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => Err(gcloud_auth_instruction(GcloudAuthAction::Remove(email))),
        Route::Native => {
            validate_email(email)?;
            revoke_then_delete(
                email,
                |owned| async move {
                    let for_load = owned.clone();
                    let refresh_token = crate::oauth::store_call(move || {
                        crate::token_store::load_refresh_token(&for_load)
                    })
                    .await??;
                    crate::oauth::revoke_refresh_token(&refresh_token).await
                },
                |owned| async move {
                    crate::oauth::store_call(move || crate::token_store::delete_account(&owned))
                        .await?
                },
            )
            .await?;
            // The removed account's access token must not keep answering from
            // cache: `revoke_then_delete` swallows a failed revocation, and
            // without this the removed account would still work for up to the
            // cache's TTL.
            crate::gcp_rest_client::invalidate_cached_access_token().await;
            Ok(())
        }
    }
}

/// Revoke and forget every stored account.
///
/// This is what the "Log out" button calls — the destructive, no-turning-back
/// action, as opposed to `remove` for one account. A "Logged out" message that
/// leaves the token store full is worse than no button at all, so the native
/// arm actually empties it: list every account, then run each through the
/// same revoke-then-delete path `remove` uses.
pub async fn log_out_all() -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => Err(gcloud_auth_instruction(GcloudAuthAction::RemoveAll)),
        Route::Native => {
            let emails = crate::oauth::store_call(crate::token_store::list_accounts).await?;
            for email in emails {
                remove(&email).await?;
            }
            Ok(())
        }
    }
}

/// The active account's e-mail.
pub async fn active_email() -> Result<String> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => gcloud_call(crate::gcloud::get_gcloud_account).await?,
        Route::Native => crate::oauth::store_call(crate::token_store::active_account)
            .await?
            .ok_or_else(no_active_account_error),
    }
}

/// The projects visible to `email` — which need not be the active account.
pub async fn projects_for(email: &str) -> Result<Vec<crate::gcloud::GcpProject>> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::get_projects_for_account_async(email).await,
        Route::Native => {
            let token = access_token_for_account(email).await?;
            let projects = crate::gcp_rest_client::list_projects_with_token(&token).await?;
            Ok(projects
                .into_iter()
                .map(|p| crate::gcloud::GcpProject { project_id: p.project_id, name: p.name })
                .collect())
        }
    }
}

/// Whether gcloud is present and whether there is a usable session.
pub async fn auth_status() -> AuthStatus {
    let engine = crate::oauth::auth_engine();
    // A join failure here (the blocking task panicked) is treated as "not
    // usable" rather than propagated: `auth_status` has no `Result` to carry
    // it, and "not installed" / "not authenticated" is the safe fallback.
    let gcloud_installed = gcloud_call(crate::gcloud::is_gcloud_installed).await.unwrap_or(false);
    let (gcloud_authenticated, native_credential) = match route(engine) {
        // `gcloud_installed` above is probed on both routes — Doctor and the
        // dependency row report it regardless of the engine. What the native
        // arm skips is `is_gcloud_authenticated`: a second, heavier shell-out
        // whose answer the native route would ignore anyway.
        Route::Gcloud => (
            gcloud_installed
                && gcloud_call(crate::gcloud::is_gcloud_authenticated).await.unwrap_or(false),
            None,
        ),
        // The index says whether there is an account; only the keyring says
        // whether its sign-in can be used now.
        //
        // NOT COVERED BY ANY TEST (checked by mutation): replacing the read
        // below with a fixed `Readable` leaves every test green, because the
        // decision (`auth_status_for`) and the read (`credential_state_within`)
        // are tested apart and this glue needs a real keyring. The QA with a
        // broken D-Bus session and a locked keyring is what covers it.
        Route::Native => {
            let active = crate::oauth::store_call(crate::token_store::active_account)
                .await
                .ok()
                .flatten();
            let credential = match active {
                Some(email) => Some(
                    crate::token_store::credential_state_within(
                        &email,
                        crate::token_store::CREDENTIAL_READ_TIMEOUT,
                    )
                    .await,
                ),
                None => None,
            };
            (false, credential)
        }
    };
    auth_status_for(engine, gcloud_installed, gcloud_authenticated, native_credential)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oauth::AuthEngine;
    use crate::token_store::CredentialState;

    /// Bajo el motor gcloud, LCC no ejecuta `gcloud auth login`: dice cuál es.
    /// El comando literal es el contenido útil del mensaje — sin él, el usuario
    /// solo sabe que algo no se puede hacer.
    #[test]
    fn the_gcloud_add_instruction_names_the_command() {
        let e = gcloud_auth_instruction(GcloudAuthAction::Add);
        assert!(e.to_string().contains("gcloud auth login"), "mensaje: {}", e);
    }

    #[test]
    fn the_gcloud_remove_instruction_names_the_command_and_the_account() {
        let e = gcloud_auth_instruction(GcloudAuthAction::Remove("ana@x.com"));
        let msg = e.to_string();
        assert!(msg.contains("gcloud auth revoke"), "mensaje: {}", msg);
        assert!(msg.contains("ana@x.com"), "falta la cuenta: {}", msg);
    }

    #[test]
    fn the_gcloud_log_out_all_instruction_names_the_command() {
        let e = gcloud_auth_instruction(GcloudAuthAction::RemoveAll);
        assert!(e.to_string().contains("gcloud auth revoke --all"), "mensaje: {}", e);
    }

    #[test]
    fn the_active_account_is_the_only_one_marked_active() {
        let accounts = to_accounts(
            vec!["a@x.com".into(), "b@x.com".into(), "c@x.com".into()],
            Some("b@x.com".into()),
        );
        let statuses: Vec<&str> = accounts.iter().map(|a| a.status.as_str()).collect();
        assert_eq!(statuses, vec!["", "ACTIVE", ""]);
        // El orden del índice se conserva: la UI lo muestra tal cual.
        let emails: Vec<&str> = accounts.iter().map(|a| a.account.as_str()).collect();
        assert_eq!(emails, vec!["a@x.com", "b@x.com", "c@x.com"]);
    }

    #[test]
    fn without_an_active_account_none_is_marked() {
        let accounts = to_accounts(vec!["a@x.com".into()], None);
        assert_eq!(accounts[0].status, "");
    }

    #[test]
    fn an_empty_store_lists_nothing() {
        assert!(to_accounts(Vec::new(), None).is_empty());
    }

    #[test]
    fn an_active_email_missing_from_the_list_does_not_invent_an_entry() {
        // El índice puede quedar inconsistente (borrado fuera de banda); la
        // lista es la lista, y nadie sale marcado.
        let accounts = to_accounts(vec!["a@x.com".into()], Some("ghost@x.com".into()));
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].status, "");
    }

    #[test]
    fn the_engine_decides_the_route_in_both_directions() {
        assert!(matches!(route(AuthEngine::Gcloud), Route::Gcloud));
        assert!(matches!(route(AuthEngine::Native), Route::Native));
    }

    /// La guarda de la pieza que hace D4 alcanzable: con motor nativo, tener
    /// sesión NO puede depender de que gcloud esté instalado. El provider Dart
    /// cortocircuitaba justo ahí, y sin esto el diálogo de cuentas no llega
    /// nunca a pedir la lista.
    #[test]
    fn native_auth_does_not_depend_on_gcloud_being_installed() {
        let status = auth_status_for(AuthEngine::Native, false, false, Some(CredentialState::Readable));
        assert!(status.authenticated, "una cuenta activa nativa es sesión válida");
        assert!(!status.gcloud_installed, "y gcloud sigue reportándose como ausente");
    }

    #[test]
    fn native_without_a_stored_account_is_not_authenticated() {
        let status = auth_status_for(AuthEngine::Native, true, true, None);
        assert!(!status.authenticated, "gcloud autenticado no da sesión nativa");
    }

    /// La pantalla "instala el SDK" del dashboard se decide con esta bandera.
    /// Si volviera a ser `true` en nativo, una máquina sin gcloud perdería
    /// otra vez la lista de proyectos e instancias con sesión válida.
    #[test]
    fn only_the_gcloud_route_requires_gcloud() {
        assert!(auth_status_for(AuthEngine::Gcloud, true, true, None).gcloud_required);
        assert!(auth_status_for(AuthEngine::Gcloud, false, false, None).gcloud_required);
        assert!(!auth_status_for(AuthEngine::Native, false, false, Some(CredentialState::Readable)).gcloud_required);
        assert!(!auth_status_for(AuthEngine::Native, true, true, Some(CredentialState::Readable)).gcloud_required);
    }

    #[test]
    fn gcloud_engine_keeps_todays_semantics() {
        assert!(auth_status_for(AuthEngine::Gcloud, true, true, None).authenticated);
        assert!(!auth_status_for(AuthEngine::Gcloud, true, false, Some(CredentialState::Readable)).authenticated);
        // Sin gcloud instalado no hay sesión gcloud, haya lo que haya nativo.
        assert!(!auth_status_for(AuthEngine::Gcloud, false, true, Some(CredentialState::Readable)).authenticated);
    }

    /// La tabla de la spec. Cada fila, un motivo: Missing manda a iniciar
    /// sesión (la sesión ya no existe); Unreachable, Refused y Pending mandan a
    /// la pantalla del llavero (la sesión sigue guardada); Unclear se queda en
    /// el comportamiento de antes.
    #[test]
    fn the_native_session_follows_what_the_keyring_said() {
        use CredentialState::*;
        let cases = [
            (None, false, None),
            (Some(Readable), true, None),
            (Some(Missing), false, None),
            (Some(Unreachable), false, Some(KeyringProblem::Unreachable)),
            (Some(Refused), false, Some(KeyringProblem::Refused)),
            (Some(Pending), false, Some(KeyringProblem::Pending)),
            (Some(Unclear), true, None),
        ];
        for (credential, authenticated, problem) in cases {
            let status = auth_status_for(AuthEngine::Native, true, true, credential);
            assert_eq!(status.authenticated, authenticated, "{credential:?}");
            assert_eq!(status.keyring_problem, problem, "{credential:?}");
        }
    }

    /// El motor gcloud no lee el llavero de LCC: jamás informa de un problema
    /// del llavero, diga lo que diga el argumento nativo.
    #[test]
    fn the_gcloud_route_never_reports_a_keyring_problem() {
        let status = auth_status_for(AuthEngine::Gcloud, true, true, Some(CredentialState::Refused));
        assert!(status.authenticated);
        assert_eq!(status.keyring_problem, None);
    }

    /// Si Google no contesta, la entrada local se borra igual: dejarla sería
    /// mostrar al usuario una cuenta rota que no puede quitar.
    #[tokio::test]
    async fn a_failed_revocation_still_deletes_the_local_entry() {
        use std::sync::{Arc, Mutex};

        let calls = Arc::new(Mutex::new(Vec::<&'static str>::new()));
        let revoke_log = calls.clone();
        let delete_log = calls.clone();

        let result = revoke_then_delete(
            "a@x.com",
            move |_email| async move {
                revoke_log.lock().unwrap().push("revoke");
                Err(anyhow::anyhow!("network down"))
            },
            move |_email| async move {
                delete_log.lock().unwrap().push("delete");
                Ok(())
            },
        )
        .await;

        assert_eq!(
            *calls.lock().unwrap(),
            vec!["revoke", "delete"],
            "el borrado local debe ocurrir DESPUÉS de intentar la revocación"
        );
        assert!(result.is_ok(), "un fallo de revocación no debe fallar el remove");
    }

    #[tokio::test]
    async fn a_failed_local_delete_is_an_error() {
        let result = revoke_then_delete(
            "a@x.com",
            |_email| async { Ok(()) },
            |_email| async { Err(anyhow::anyhow!("keyring unavailable")) },
        )
        .await;
        assert!(result.is_err(), "si el borrado local falla, remove falla");
    }

    /// Contrato con el clasificador Dart: `classifyRustError` mapea
    /// `invalid_grant` a `notAuthenticated`, que es lo que hace aparecer el
    /// banner de re-login. Sin ese literal, un token muerto sale como error
    /// genérico y el usuario no tiene salida.
    #[test]
    fn a_dead_refresh_token_surfaces_as_invalid_grant() {
        let err = token_from_outcome("a@x.com", crate::oauth::RefreshOutcome::NeedsReauth)
            .expect_err("NeedsReauth debe ser error");
        assert!(
            err.to_string().contains("invalid_grant"),
            "el banner de sesión no reconocerá este mensaje: {}",
            err
        );
    }

    #[test]
    fn a_live_refresh_token_yields_its_access_token() {
        let outcome = crate::oauth::RefreshOutcome::Token(crate::oauth::RefreshedToken {
            access_token: "ya29.token".into(),
            expires_in_secs: 3599,
        });
        assert_eq!(token_from_outcome("a@x.com", outcome).unwrap(), "ya29.token");
    }

    /// Otro literal que es contrato: `classifyRustError` lo mapea a
    /// `notAuthenticated`.
    #[test]
    fn the_no_active_account_error_keeps_its_wording() {
        assert!(no_active_account_error()
            .to_string()
            .contains("No active GCP account"));
    }
}
