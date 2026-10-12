/// Connectivity Doctor Module - Sprint 7
///
/// Automated troubleshooter that diagnoses connectivity problems with GCP VMs.
/// Runs 13 checks grouped in 5 categories and generates actionable reports.
///
/// Categories:
/// 1. Authentication - gcloud CLI, gcloud account and ADC credentials (the
///    gcloud engine's three), plus LCC's own credential store, account index
///    and session (the native engine's three). Each group is skipped under the
///    other engine.
/// 2. ProjectPermissions - project access, Compute Engine API
/// 3. IapNetwork - IAP API, firewall rules
/// 4. VmStatus - VM state, guest agent
/// 5. LocalEnvironment - local remote clients (RDP, VNC, SSH)

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Instant;
use tracing::info;

use crate::gcp_rest_client::GcpAuthClient;
use crate::redact::redact_sensitive;

// ==========================================
// ENUMS & STRUCTS
// ==========================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DoctorCheckStatus {
    Pass,
    Warning,
    Fail,
    Skipped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DoctorCheckCategory {
    Authentication,
    ProjectPermissions,
    IapNetwork,
    VmStatus,
    LocalEnvironment,
}

impl DoctorCheckCategory {
    pub fn display_name(&self) -> &'static str {
        match self {
            DoctorCheckCategory::Authentication => "Authentication",
            DoctorCheckCategory::ProjectPermissions => "Project & Permissions",
            DoctorCheckCategory::IapNetwork => "IAP & Network",
            DoctorCheckCategory::VmStatus => "VM Status",
            DoctorCheckCategory::LocalEnvironment => "Local Environment",
        }
    }

    pub fn all() -> Vec<DoctorCheckCategory> {
        vec![
            DoctorCheckCategory::Authentication,
            DoctorCheckCategory::ProjectPermissions,
            DoctorCheckCategory::IapNetwork,
            DoctorCheckCategory::VmStatus,
            DoctorCheckCategory::LocalEnvironment,
        ]
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorCheckResult {
    pub check_id: String,
    pub name: String,
    pub category: DoctorCheckCategory,
    pub status: DoctorCheckStatus,
    pub message: String,
    pub details: Option<String>,
    pub suggestion: Option<String>,
    pub fix_command: Option<String>,
    pub fix_action_id: Option<String>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorReport {
    pub checks: Vec<DoctorCheckResult>,
    pub project_id: String,
    pub zone: String,
    pub instance_name: String,
    pub generated_at: String,
    pub gcloud_version: Option<String>,
    pub gcloud_account: Option<String>,
    pub total_duration_ms: u64,
    pub pass_count: u32,
    pub warning_count: u32,
    pub fail_count: u32,
    pub skipped_count: u32,
}

/// How a gcloud check reports, given the engine in use.
///
/// Under the native engine a missing gcloud is irrelevant, not a failure —
/// the user this release targets is precisely the one without it. Under the
/// gcloud engine it is exactly as decisive as it always was.
fn gcloud_check_status(engine: crate::oauth::AuthEngine, present: bool) -> DoctorCheckStatus {
    match engine {
        crate::oauth::AuthEngine::Native => DoctorCheckStatus::Skipped,
        crate::oauth::AuthEngine::Gcloud if present => DoctorCheckStatus::Pass,
        crate::oauth::AuthEngine::Gcloud => DoctorCheckStatus::Fail,
    }
}

/// Message for a check skipped because the auth engine is native.
const NOT_APPLICABLE_NATIVE_ENGINE: &str = "Skipped: not applicable, the auth engine is native";

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

/// Message for check 2 when check 1 actually looked and did not find gcloud.
const GCLOUD_NOT_INSTALLED: &str = "Skipped: gcloud CLI not installed";

/// Why the gcloud-account row is skipped, or `None` when it should run.
///
/// Under the native engine the gcloud probes are deliberately not run — they
/// cost a subprocess and cannot change the row's status — so check 1 is
/// `Skipped` and "installed" is `false` **by construction**. Deriving the skip
/// reason from that flag made the row state `gcloud CLI not installed` on
/// machines that do have it installed: a fact nobody checked, printed inside a
/// report users export into tickets. Under the native engine the reason is the
/// engine; only under the gcloud engine, where check 1 really looked, may it
/// be the absent binary.
fn gcloud_account_skip_reason(
    engine: crate::oauth::AuthEngine,
    installed: DoctorCheckStatus,
) -> Option<&'static str> {
    match engine {
        crate::oauth::AuthEngine::Native => Some(NOT_APPLICABLE_NATIVE_ENGINE),
        crate::oauth::AuthEngine::Gcloud if installed == DoctorCheckStatus::Pass => None,
        crate::oauth::AuthEngine::Gcloud => Some(GCLOUD_NOT_INSTALLED),
    }
}

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
/// failed, and that reason is redacted here, inside the pure function, so the
/// no-secret guarantee holds for every caller instead of depending on each
/// call site remembering to redact before it gets here.
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
            format!(
                "The session could not be renewed: {}",
                redact_sensitive(&reason)
            ),
            Some("Sign in to LCC again to renew your session.".to_string()),
            Some("re_authenticate".to_string()),
        ),
    }
}

/// What a refresh attempt means for this row.
///
/// `NeedsReauth` is Google reporting the stored refresh token dead — the exact
/// state this row exists to surface — so it must never read as success. A
/// transport-level `Err` (network, timeout, malformed response) is a
/// different failure but is a failure all the same.
///
/// This is the conversion the previous version of this check got wrong: it
/// matched only the outer `Result` from `refresh_access_token`, so
/// `Ok(RefreshOutcome::NeedsReauth)` read as success. Isolating the
/// conversion here lets a guard aim at it directly.
fn refresh_verdict(
    outcome: std::result::Result<crate::oauth::RefreshOutcome, String>,
) -> std::result::Result<(), String> {
    match outcome {
        Ok(crate::oauth::RefreshOutcome::Token(_)) => Ok(()),
        // `invalid_grant` is the keyword `classifyRustError` (Dart) looks
        // for; `accounts.rs`'s `token_from_outcome` uses the same wording for
        // the same reason — a dead token must not read as a generic failure.
        Ok(crate::oauth::RefreshOutcome::NeedsReauth) => {
            Err("Session expired (invalid_grant); sign in again".to_string())
        }
        Err(reason) => Err(reason),
    }
}

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

/// What to offer the user when getting an access token fails, as
/// `(suggestion, fix_command, fix_action_id)`.
///
/// The check itself — is the project reachable — is the same on both engines;
/// only the remedy differs. Under the native engine LCC owns the session, so
/// the remedy is signing in to LCC again, dispatched through the
/// `re_authenticate` fix action. Handing that user a gcloud command, and a
/// **Fix** button that runs it, is the defect this whole sub-project set out
/// to remove. Under the gcloud engine the wording is unchanged.
fn token_failure_remedy(
    engine: crate::oauth::AuthEngine,
) -> (Option<String>, Option<String>, Option<String>) {
    match engine {
        crate::oauth::AuthEngine::Native => (
            Some("Sign in to LCC again to renew your session.".to_string()),
            None,
            Some("re_authenticate".to_string()),
        ),
        crate::oauth::AuthEngine::Gcloud => (
            Some("Re-authenticate with 'gcloud auth application-default login'.".to_string()),
            Some("gcloud auth application-default login".to_string()),
            None,
        ),
    }
}

/// How an API-enabled check reports when the API is not confirmed ENABLED —
/// whether that's a known other state, an unreadable response, or a network
/// error. `required` is whether anything in this codebase actually calls
/// that API.
///
/// Compute Engine gates every other check in this category, so anything
/// short of ENABLED is `Fail`. The IAP API gates nothing LCC calls — the
/// tunnel (native or via `gcloud compute start-iap-tunnel`) talks to the
/// `tunnel.cloudproxy.app` relay directly, never to `iap.googleapis.com` —
/// so the same answer is only a `Warning`: worth knowing, never a reason to
/// paint the whole report red.
fn severity_when_unhealthy(required: bool) -> DoctorCheckStatus {
    if required {
        DoctorCheckStatus::Fail
    } else {
        DoctorCheckStatus::Warning
    }
}

/// What `DoctorClient::check_api_enabled` needs to know about one API.
struct ApiEnabledSpec<'a> {
    api_name: &'a str,
    check_id: &'a str,
    display_name: &'a str,
    fix_cmd: &'a str,
    required: bool,
    not_enabled_detail: &'a str,
}

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

// ==========================================
// DOCTOR CLIENT
// ==========================================

pub struct DoctorClient {
    auth: Option<Arc<GcpAuthClient>>,
    compute_base_url: String,
    serviceusage_base_url: String,
    crm_base_url: String,
}

impl DoctorClient {
    pub fn new() -> Self {
        let auth = GcpAuthClient::get_or_init().ok();

        Self {
            auth,
            compute_base_url: "https://compute.googleapis.com/compute/v1".to_string(),
            serviceusage_base_url: "https://serviceusage.googleapis.com/v1".to_string(),
            crm_base_url: "https://cloudresourcemanager.googleapis.com/v1".to_string(),
        }
    }

    // ==========================================
    // CHECK 1: gcloud CLI installed
    // ==========================================

    fn check_gcloud_installed(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let engine = crate::oauth::auth_engine();
        // Probed only on the engine that cares. Under the native engine the row
        // is Skipped whatever the answer is, and asking costs a gcloud
        // subprocess in the release whose whole point is not needing one.
        let installed = match engine {
            crate::oauth::AuthEngine::Native => false,
            crate::oauth::AuthEngine::Gcloud => crate::gcloud::is_gcloud_installed(),
        };

        match gcloud_check_status(engine, installed) {
            DoctorCheckStatus::Skipped => self.skipped_check(
                "auth_gcloud_installed",
                "gcloud CLI Installed",
                DoctorCheckCategory::Authentication,
                NOT_APPLICABLE_NATIVE_ENGINE,
                start,
            ),
            DoctorCheckStatus::Pass => DoctorCheckResult {
                check_id: "auth_gcloud_installed".to_string(),
                name: "gcloud CLI Installed".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Pass,
                message: "gcloud CLI is installed and accessible".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            _ => DoctorCheckResult {
                check_id: "auth_gcloud_installed".to_string(),
                name: "gcloud CLI Installed".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "gcloud CLI is not installed or not in PATH".to_string(),
                details: Some("The Google Cloud SDK (gcloud) is required for IAP tunneling and authentication.".to_string()),
                suggestion: Some("Install the Google Cloud SDK from https://cloud.google.com/sdk/docs/install".to_string()),
                fix_command: Some("curl https://sdk.cloud.google.com | bash".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 2: gcloud authenticated
    // ==========================================

    fn check_gcloud_account(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let engine = crate::oauth::auth_engine();
        // Not probed under the native engine: see check_gcloud_installed.
        let authenticated = match engine {
            crate::oauth::AuthEngine::Native => false,
            crate::oauth::AuthEngine::Gcloud => crate::gcloud::is_gcloud_authenticated(),
        };

        match gcloud_check_status(engine, authenticated) {
            DoctorCheckStatus::Skipped => self.skipped_check(
                "auth_gcloud_account",
                "gcloud Account Active",
                DoctorCheckCategory::Authentication,
                NOT_APPLICABLE_NATIVE_ENGINE,
                start,
            ),
            DoctorCheckStatus::Pass => {
                let account = crate::gcloud::get_gcloud_account().unwrap_or_default();
                DoctorCheckResult {
                    check_id: "auth_gcloud_account".to_string(),
                    name: "gcloud Account Active".to_string(),
                    category: DoctorCheckCategory::Authentication,
                    status: DoctorCheckStatus::Pass,
                    message: format!("Authenticated as: {}", account),
                    details: None,
                    suggestion: None,
                    fix_command: None,
                    fix_action_id: None,
                    duration_ms: start.elapsed().as_millis() as u64,
                }
            }
            _ => DoctorCheckResult {
                check_id: "auth_gcloud_account".to_string(),
                name: "gcloud Account Active".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "No active gcloud account found".to_string(),
                details: Some("You need to authenticate with gcloud to access GCP resources.".to_string()),
                suggestion: Some("Run 'gcloud auth login' to authenticate.".to_string()),
                fix_command: Some("gcloud auth login".to_string()),
                fix_action_id: Some("re_authenticate".to_string()),
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 3: ADC credentials file
    // ==========================================

    fn check_adc_credentials(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_default();

        let creds_path = std::path::PathBuf::from(&home)
            .join(".config")
            .join("gcloud")
            .join("application_default_credentials.json");

        let engine = crate::oauth::auth_engine();
        // Not probed under the native engine: see check_gcloud_installed.
        let present = match engine {
            crate::oauth::AuthEngine::Native => false,
            crate::oauth::AuthEngine::Gcloud => creds_path.exists(),
        };

        match gcloud_check_status(engine, present) {
            DoctorCheckStatus::Skipped => self.skipped_check(
                "auth_adc_credentials",
                "Application Default Credentials",
                DoctorCheckCategory::Authentication,
                NOT_APPLICABLE_NATIVE_ENGINE,
                start,
            ),
            DoctorCheckStatus::Pass => DoctorCheckResult {
                check_id: "auth_adc_credentials".to_string(),
                name: "Application Default Credentials".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Pass,
                message: "ADC credentials file found".to_string(),
                details: Some(format!("Path: {}", creds_path.display())),
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            _ => DoctorCheckResult {
                check_id: "auth_adc_credentials".to_string(),
                name: "Application Default Credentials".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "ADC credentials file not found".to_string(),
                details: Some(format!("Expected at: {}", creds_path.display())),
                suggestion: Some("Run 'gcloud auth application-default login' to create ADC credentials.".to_string()),
                fix_command: Some("gcloud auth application-default login".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

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
                    Err(e) => Some(Err(e.to_string())),
                    // The minted token is discarded on purpose: the `Ok`
                    // value from `refresh_access_token` never lands in a
                    // variable that reaches the report — `refresh_verdict`
                    // only tells us whether it counts as success.
                    Ok(refresh) => {
                        let attempt = crate::oauth::refresh_access_token(&refresh)
                            .await
                            .map_err(|e| e.to_string());
                        match refresh_verdict(attempt) {
                            Ok(()) => Some(Ok(email)),
                            Err(reason) => Some(Err(reason)),
                        }
                    }
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

    // ==========================================
    // CHECK 4: Project accessible
    // ==========================================

    async fn check_project_accessible(&self, project: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "project_accessible",
                "Project Accessible",
                DoctorCheckCategory::ProjectPermissions,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(e) => {
                let (suggestion, fix_command, fix_action_id) =
                    token_failure_remedy(crate::oauth::auth_engine());
                return DoctorCheckResult {
                    check_id: "project_accessible".to_string(),
                    name: "Project Accessible".to_string(),
                    category: DoctorCheckCategory::ProjectPermissions,
                    status: DoctorCheckStatus::Fail,
                    message: "Failed to get access token".to_string(),
                    details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                    suggestion,
                    fix_command,
                    fix_action_id,
                    duration_ms: start.elapsed().as_millis() as u64,
                };
            }
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!("{}/projects/{}", self.crm_base_url, project);
        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Pass,
                message: format!("Project '{}' is accessible", project),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) if r.status().as_u16() == 403 => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: format!("Permission denied for project '{}'", project),
                details: Some("Your account does not have access to this project.".to_string()),
                suggestion: Some("Ensure you have the 'Viewer' role or higher on the project.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) if r.status().as_u16() == 404 => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: format!("Project '{}' not found", project),
                details: with_console_alternative(
                    Some("The project ID may be incorrect or the project may have been deleted.".to_string()),
                    "https://console.cloud.google.com/cloud-resource-manager",
                ),
                suggestion: Some("Verify the project ID is correct.".to_string()),
                fix_command: Some("gcloud projects list".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: format!("Unexpected response: HTTP {}", r.status()),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: "Network error checking project access".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 5: Compute Engine API enabled
    // ==========================================

    async fn check_compute_api_enabled(&self, project: &str) -> DoctorCheckResult {
        let mut result = self.check_api_enabled(project, ApiEnabledSpec {
            api_name: "compute.googleapis.com",
            check_id: "compute_api_enabled",
            display_name: "Compute Engine API",
            fix_cmd: "gcloud services enable compute.googleapis.com",
            required: true,
            not_enabled_detail: "The Compute Engine API needs to be enabled for this project.",
        }).await;
        if result.fix_command.is_some() {
            result.details = with_console_alternative(
                result.details,
                "https://console.cloud.google.com/apis/library/compute.googleapis.com",
            );
        }
        result
    }

    // ==========================================
    // CHECK 6: IAP API enabled
    // ==========================================

    /// Not required: see `severity_when_unhealthy`. Still checked and shown,
    /// because a project owner who *does* use other IAP features (web-app
    /// IAP, resource-level IAM) benefits from the heads-up — it just must
    /// never read as something LCC's own tunnel needs.
    async fn check_iap_api_enabled(&self, project: &str) -> DoctorCheckResult {
        let mut result = self.check_api_enabled(project, ApiEnabledSpec {
            api_name: "iap.googleapis.com",
            check_id: "iap_api_enabled",
            display_name: "IAP API",
            fix_cmd: "gcloud services enable iap.googleapis.com",
            required: false,
            not_enabled_detail: "LCC's tunnel connects directly to Google's IAP relay \
             (tunnel.cloudproxy.app) and does not need this API. It only \
             matters for other IAP features, such as web-app IAP or \
             resource-level IAM, which LCC does not use.",
        }).await;
        if result.fix_command.is_some() {
            result.details = with_console_alternative(
                result.details,
                "https://console.cloud.google.com/apis/library/iap.googleapis.com",
            );
        }
        result
    }

    /// Generic API enabled check. `spec.required` and
    /// `spec.not_enabled_detail` say how alarming and how explained an
    /// unhealthy answer should be — see `severity_when_unhealthy`.
    async fn check_api_enabled(&self, project: &str, spec: ApiEnabledSpec<'_>) -> DoctorCheckResult {
        let ApiEnabledSpec { api_name, check_id, display_name, fix_cmd, required, not_enabled_detail } = spec;
        let start = Instant::now();
        let category = if check_id.starts_with("iap") {
            DoctorCheckCategory::IapNetwork
        } else {
            DoctorCheckCategory::ProjectPermissions
        };

        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                check_id,
                display_name,
                category,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                check_id,
                display_name,
                category,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/services/{}",
            self.serviceusage_base_url, project, api_name
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let state = body["state"].as_str().unwrap_or("UNKNOWN");
                if state == "ENABLED" {
                    DoctorCheckResult {
                        check_id: check_id.to_string(),
                        name: format!("{} Enabled", display_name),
                        category,
                        status: DoctorCheckStatus::Pass,
                        message: format!("{} is enabled", display_name),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                } else {
                    DoctorCheckResult {
                        check_id: check_id.to_string(),
                        name: format!("{} Enabled", display_name),
                        category,
                        status: severity_when_unhealthy(required),
                        message: format!("{} is not enabled (state: {})", display_name, state),
                        details: Some(not_enabled_detail.to_string()),
                        suggestion: Some(if required {
                            format!("Enable it with: {}", fix_cmd)
                        } else {
                            format!("Not required, but you can enable it with: {}", fix_cmd)
                        }),
                        fix_command: Some(fix_cmd.to_string()),
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                }
            }
            Ok(r) => {
                let status = r.status();
                DoctorCheckResult {
                    check_id: check_id.to_string(),
                    name: format!("{} Enabled", display_name),
                    category,
                    status: severity_when_unhealthy(required),
                    message: format!("Could not check {} status (HTTP {})", display_name, status),
                    details: None,
                    suggestion: Some(format!("Try enabling manually: {}", fix_cmd)),
                    fix_command: Some(fix_cmd.to_string()),
                    fix_action_id: None,
                    duration_ms: start.elapsed().as_millis() as u64,
                }
            }
            Err(e) => DoctorCheckResult {
                check_id: check_id.to_string(),
                name: format!("{} Enabled", display_name),
                category,
                status: severity_when_unhealthy(required),
                message: format!("Network error checking {}", display_name),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 7: IAP firewall rule
    // ==========================================

    async fn check_iap_firewall(&self, project: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "iap_firewall",
                "IAP Firewall Rule",
                DoctorCheckCategory::IapNetwork,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                "iap_firewall",
                "IAP Firewall Rule",
                DoctorCheckCategory::IapNetwork,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/global/firewalls",
            self.compute_base_url, project
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let firewalls = body["items"].as_array();

                let iap_range = "35.235.240.0/20";
                let has_iap_rule = firewalls.map(|rules| {
                    rules.iter().any(|rule| {
                        let direction = rule["direction"].as_str().unwrap_or("");
                        if direction != "INGRESS" {
                            return false;
                        }
                        let disabled = rule["disabled"].as_bool().unwrap_or(false);
                        if disabled {
                            return false;
                        }
                        rule["sourceRanges"].as_array()
                            .map(|ranges| {
                                ranges.iter().any(|r| {
                                    r.as_str().map(|s| s == iap_range).unwrap_or(false)
                                })
                            })
                            .unwrap_or(false)
                    })
                }).unwrap_or(false);

                if has_iap_rule {
                    DoctorCheckResult {
                        check_id: "iap_firewall".to_string(),
                        name: "IAP Firewall Rule".to_string(),
                        category: DoctorCheckCategory::IapNetwork,
                        status: DoctorCheckStatus::Pass,
                        message: "Firewall rule allowing IAP range (35.235.240.0/20) found".to_string(),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                } else {
                    DoctorCheckResult {
                        check_id: "iap_firewall".to_string(),
                        name: "IAP Firewall Rule".to_string(),
                        category: DoctorCheckCategory::IapNetwork,
                        status: DoctorCheckStatus::Warning,
                        message: "No firewall rule found for IAP range (35.235.240.0/20)".to_string(),
                        details: with_console_alternative(
                            Some("IAP tunneling requires a firewall rule that allows ingress from 35.235.240.0/20.".to_string()),
                            "https://console.cloud.google.com/networking/firewalls/list",
                        ),
                        suggestion: Some("Create a firewall rule allowing TCP ingress from 35.235.240.0/20.".to_string()),
                        fix_command: Some(format!(
                            "gcloud compute firewall-rules create allow-iap --project={} --direction=INGRESS --action=ALLOW --rules=tcp:22,tcp:3389 --source-ranges=35.235.240.0/20",
                            project
                        )),
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                }
            }
            Ok(r) if r.status().as_u16() == 403 => DoctorCheckResult {
                check_id: "iap_firewall".to_string(),
                name: "IAP Firewall Rule".to_string(),
                category: DoctorCheckCategory::IapNetwork,
                status: DoctorCheckStatus::Warning,
                message: "Permission denied to list firewall rules".to_string(),
                details: Some("Cannot verify IAP firewall rules without 'compute.firewalls.list' permission.".to_string()),
                suggestion: Some("Ask a project admin to verify IAP firewall rules exist.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) => DoctorCheckResult {
                check_id: "iap_firewall".to_string(),
                name: "IAP Firewall Rule".to_string(),
                category: DoctorCheckCategory::IapNetwork,
                status: DoctorCheckStatus::Fail,
                message: format!("Could not check firewall rules (HTTP {})", r.status()),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "iap_firewall".to_string(),
                name: "IAP Firewall Rule".to_string(),
                category: DoctorCheckCategory::IapNetwork,
                status: DoctorCheckStatus::Fail,
                message: "Network error checking firewall rules".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 8: VM status
    // ==========================================

    async fn check_vm_status(&self, project: &str, zone: &str, instance: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "vm_status",
                "VM Status",
                DoctorCheckCategory::VmStatus,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                "vm_status",
                "VM Status",
                DoctorCheckCategory::VmStatus,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}",
            self.compute_base_url, project, zone, instance
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let status = body["status"].as_str().unwrap_or("UNKNOWN");

                match status {
                    "RUNNING" => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Pass,
                        message: format!("VM '{}' is RUNNING", instance),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                    "TERMINATED" | "STOPPED" => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Fail,
                        message: format!("VM '{}' is {} (not running)", instance, status),
                        details: with_console_alternative(
                            Some("The VM must be running to establish connections.".to_string()),
                            "https://console.cloud.google.com/compute/instances",
                        ),
                        suggestion: Some("Start the VM to enable connections.".to_string()),
                        fix_command: Some(format!(
                            "gcloud compute instances start {} --project={} --zone={}",
                            instance, project, zone
                        )),
                        fix_action_id: Some("start_vm".to_string()),
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                    "STAGING" | "PROVISIONING" => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Warning,
                        message: format!("VM '{}' is {} (starting up)", instance, status),
                        details: Some("The VM is starting up. Wait a few minutes.".to_string()),
                        suggestion: Some("Wait for the VM to reach RUNNING state.".to_string()),
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                    _ => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Warning,
                        message: format!("VM '{}' is in state: {}", instance, status),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                }
            }
            Ok(r) if r.status().as_u16() == 404 => DoctorCheckResult {
                check_id: "vm_status".to_string(),
                name: "VM Status".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Fail,
                message: format!("VM '{}' not found in {}/{}", instance, project, zone),
                details: with_console_alternative(
                    Some("The instance name or zone may be incorrect.".to_string()),
                    "https://console.cloud.google.com/compute/instances",
                ),
                suggestion: Some("Verify the instance name and zone.".to_string()),
                fix_command: Some(format!("gcloud compute instances list --project={}", project)),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) => DoctorCheckResult {
                check_id: "vm_status".to_string(),
                name: "VM Status".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Fail,
                message: format!("Could not check VM status (HTTP {})", r.status()),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "vm_status".to_string(),
                name: "VM Status".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Fail,
                message: "Network error checking VM status".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 9: Guest agent
    // ==========================================

    async fn check_vm_guest_agent(&self, project: &str, zone: &str, instance: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "vm_guest_agent",
                "VM Guest Agent",
                DoctorCheckCategory::VmStatus,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                "vm_guest_agent",
                "VM Guest Agent",
                DoctorCheckCategory::VmStatus,
                "Skipped: failed to get access token",
                start,
            ),
        };

        // Unified detection shared with the Diagnostics panel so both agree.
        let detection = crate::diagnostics::detect_guest_agent(
            &self.compute_base_url,
            &token,
            project,
            zone,
            instance,
        )
        .await;

        match detection.source {
            crate::diagnostics::GuestAgentSource::Inventory => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Pass,
                message: "Guest agent is responding".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            crate::diagnostics::GuestAgentSource::Serial => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Pass,
                message: "Guest agent detected via serial console".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            crate::diagnostics::GuestAgentSource::None => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Warning,
                message: "Guest agent not reporting".to_string(),
                details: Some("Neither guest attributes (OS inventory) nor the serial console show the guest agent. It may not be installed, or the VM may be stopped/booting.".to_string()),
                suggestion: Some("Ensure the VM is running and the Google guest agent is installed.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 10: Local clients installed
    // ==========================================

    fn check_local_clients(&self) -> DoctorCheckResult {
        let start = Instant::now();

        // Check RDP clients
        let rdp_clients: Vec<String> = crate::rdp_client::RdpClientType::fallback_order()
            .into_iter()
            .filter(|c| c.is_available())
            .map(|c| c.display_name().to_string())
            .collect();

        // Check VNC clients
        let vnc_clients: Vec<String> = crate::vnc_client::VncClientType::fallback_order()
            .into_iter()
            .filter(|c| c.is_available())
            .map(|c| c.display_name().to_string())
            .collect();

        // Check SSH
        let ssh_available = std::process::Command::new("ssh")
            .arg("-V")
            .output()
            .is_ok();

        let mut details_parts = Vec::new();
        if !rdp_clients.is_empty() {
            details_parts.push(format!("RDP: {}", rdp_clients.join(", ")));
        } else {
            details_parts.push("RDP: none found".to_string());
        }
        if !vnc_clients.is_empty() {
            details_parts.push(format!("VNC: {}", vnc_clients.join(", ")));
        } else {
            details_parts.push("VNC: none found".to_string());
        }
        details_parts.push(format!("SSH: {}", if ssh_available { "available" } else { "not found" }));

        let has_any = !rdp_clients.is_empty() || !vnc_clients.is_empty() || ssh_available;
        let has_all = !rdp_clients.is_empty() && !vnc_clients.is_empty() && ssh_available;

        let (status, message) = if has_all {
            (DoctorCheckStatus::Pass, "All remote client types available".to_string())
        } else if has_any {
            (DoctorCheckStatus::Warning, "Some remote client types are missing".to_string())
        } else {
            (DoctorCheckStatus::Fail, "No remote clients found".to_string())
        };

        DoctorCheckResult {
            check_id: "local_clients".to_string(),
            name: "Local Remote Clients".to_string(),
            category: DoctorCheckCategory::LocalEnvironment,
            status,
            message,
            details: Some(details_parts.join("\n")),
            suggestion: if !has_all {
                Some("Install missing clients: sudo apt install remmina openssh-client".to_string())
            } else {
                None
            },
            fix_command: if !has_all {
                Some("sudo apt install remmina openssh-client".to_string())
            } else {
                None
            },
            fix_action_id: None,
            duration_ms: start.elapsed().as_millis() as u64,
        }
    }

    // ==========================================
    // HELPER: skipped check
    // ==========================================

    fn skipped_check(
        &self,
        check_id: &str,
        name: &str,
        category: DoctorCheckCategory,
        message: &str,
        start: Instant,
    ) -> DoctorCheckResult {
        DoctorCheckResult {
            check_id: check_id.to_string(),
            name: name.to_string(),
            category,
            status: DoctorCheckStatus::Skipped,
            message: message.to_string(),
            details: None,
            suggestion: None,
            fix_command: None,
            fix_action_id: None,
            duration_ms: start.elapsed().as_millis() as u64,
        }
    }

    // ==========================================
    // ORCHESTRATOR: run all checks
    // ==========================================

    pub async fn run_all_checks(
        &self,
        project_id: &str,
        zone: &str,
        instance_name: &str,
    ) -> DoctorReport {
        let total_start = Instant::now();
        let mut checks = Vec::new();

        info!("🩺 Running Connectivity Doctor for {}/{}/{}", project_id, zone, instance_name);

        // Check 1: gcloud installed
        let c1 = self.check_gcloud_installed();
        let gcloud_installed = c1.status == DoctorCheckStatus::Pass;
        // Decided before the row moves into `checks`, and by the engine as
        // well as the flag: see `gcloud_account_skip_reason`.
        let account_skip = gcloud_account_skip_reason(crate::oauth::auth_engine(), c1.status.clone());
        checks.push(c1);

        // Check 2: gcloud account
        match account_skip {
            None => checks.push(self.check_gcloud_account()),
            Some(reason) => checks.push(self.skipped_check(
                "auth_gcloud_account",
                "gcloud Account Active",
                DoctorCheckCategory::Authentication,
                reason,
                Instant::now(),
            )),
        }

        // Check 3: ADC credentials (always runs)
        checks.push(self.check_adc_credentials());

        // Check: LCC credential store reachable (always runs)
        checks.push(self.check_credential_store().await);

        // Check: on-disk account index matches the keyring (always runs)
        checks.push(self.check_account_index().await);

        // Check: LCC can mint an access token right now (always runs)
        checks.push(self.check_native_token().await);

        // Determine if we can run authenticated checks
        let has_auth = self.auth.is_some();
        let gcloud_authenticated = checks.iter()
            .find(|c| c.check_id == "auth_gcloud_account")
            .map(|c| c.status == DoctorCheckStatus::Pass)
            .unwrap_or(false);

        let can_run_api_checks = has_auth && credentials_usable(&checks);

        // Checks 4-9: API-based checks (skip if no auth)
        if can_run_api_checks {
            checks.push(self.check_project_accessible(project_id).await);
            checks.push(self.check_compute_api_enabled(project_id).await);
            checks.push(self.check_iap_api_enabled(project_id).await);
            checks.push(self.check_iap_firewall(project_id).await);
            checks.push(self.check_vm_status(project_id, zone, instance_name).await);
            checks.push(self.check_vm_guest_agent(project_id, zone, instance_name).await);
        } else {
            let skip_msg = if !has_auth {
                "Skipped: no ADC credentials available"
            } else {
                "Skipped: no usable credentials"
            };
            checks.push(self.skipped_check("project_accessible", "Project Accessible", DoctorCheckCategory::ProjectPermissions, skip_msg, Instant::now()));
            checks.push(self.skipped_check("compute_api_enabled", "Compute Engine API Enabled", DoctorCheckCategory::ProjectPermissions, skip_msg, Instant::now()));
            checks.push(self.skipped_check("iap_api_enabled", "IAP API Enabled", DoctorCheckCategory::IapNetwork, skip_msg, Instant::now()));
            checks.push(self.skipped_check("iap_firewall", "IAP Firewall Rule", DoctorCheckCategory::IapNetwork, skip_msg, Instant::now()));
            checks.push(self.skipped_check("vm_status", "VM Status", DoctorCheckCategory::VmStatus, skip_msg, Instant::now()));
            checks.push(self.skipped_check("vm_guest_agent", "VM Guest Agent", DoctorCheckCategory::VmStatus, skip_msg, Instant::now()));
        }

        // Check 10: local clients (always runs)
        checks.push(self.check_local_clients());

        // Build report
        let pass_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Pass).count() as u32;
        let warning_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Warning).count() as u32;
        let fail_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Fail).count() as u32;
        let skipped_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Skipped).count() as u32;

        let gcloud_version = if gcloud_installed {
            match crate::gcloud_bin::gcloud_path() {
                Ok(bin) => std::process::Command::new(bin)
                    .arg("--version")
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8(o.stdout).ok())
                    .and_then(|s| s.lines().next().map(|l| l.trim().to_string())),
                Err(_) => None,
            }
        } else {
            None
        };

        let gcloud_account = if gcloud_authenticated {
            crate::gcloud::get_gcloud_account().ok()
        } else {
            None
        };

        info!("🩺 Doctor complete: {} pass, {} warn, {} fail, {} skipped",
            pass_count, warning_count, fail_count, skipped_count);

        DoctorReport {
            checks,
            project_id: project_id.to_string(),
            zone: zone.to_string(),
            instance_name: instance_name.to_string(),
            generated_at: chrono::Utc::now().to_rfc3339(),
            gcloud_version,
            gcloud_account,
            total_duration_ms: total_start.elapsed().as_millis() as u64,
            pass_count,
            warning_count,
            fail_count,
            skipped_count,
        }
    }
}

// ==========================================
// REPORT GENERATION
// ==========================================

pub fn generate_doctor_report_markdown(report: &DoctorReport) -> String {
    let mut md = String::new();

    md.push_str("# Connectivity Doctor Report\n\n");
    md.push_str(&format!("**Generated:** {}\n\n", report.generated_at));
    md.push_str(&format!("**Project:** {}\n", report.project_id));
    md.push_str(&format!("**Zone:** {}\n", report.zone));
    md.push_str(&format!("**Instance:** {}\n", report.instance_name));

    if let Some(ver) = &report.gcloud_version {
        md.push_str(&format!("**gcloud:** {}\n", ver));
    }
    if let Some(acc) = &report.gcloud_account {
        md.push_str(&format!("**Account:** {}\n", acc));
    }
    md.push_str("\n");

    // Summary
    md.push_str("## Summary\n\n");
    md.push_str(&format!(
        "| Pass | Warning | Fail | Skipped | Total Time |\n|------|---------|------|---------|------------|\n| {} | {} | {} | {} | {}ms |\n\n",
        report.pass_count, report.warning_count, report.fail_count, report.skipped_count, report.total_duration_ms
    ));

    // Checks grouped by category
    for category in DoctorCheckCategory::all() {
        let cat_checks: Vec<&DoctorCheckResult> = report.checks.iter()
            .filter(|c| c.category == category)
            .collect();

        if cat_checks.is_empty() {
            continue;
        }

        md.push_str(&format!("## {}\n\n", category.display_name()));

        for check in cat_checks {
            let icon = match check.status {
                DoctorCheckStatus::Pass => "PASS",
                DoctorCheckStatus::Warning => "WARN",
                DoctorCheckStatus::Fail => "FAIL",
                DoctorCheckStatus::Skipped => "SKIP",
            };

            md.push_str(&format!("### [{}] {}\n\n", icon, check.name));
            md.push_str(&format!("{}\n\n", check.message));

            if let Some(details) = &check.details {
                md.push_str(&format!("**Details:** {}\n\n", details));
            }
            if let Some(suggestion) = &check.suggestion {
                md.push_str(&format!("**Suggestion:** {}\n\n", suggestion));
            }
            if let Some(fix_cmd) = &check.fix_command {
                md.push_str(&format!("**Fix command:**\n```\n{}\n```\n\n", fix_cmd));
            }
        }
    }

    // Redact sensitive data from the final report
    redact_sensitive(&md)
}

// ==========================================
// FIX ACTIONS
// ==========================================

/// Every fix action Doctor can dispatch. The single list the router and its
/// guard both read, so a new action cannot be added past the guard.
const FIX_ACTION_IDS: &[&str] = &["re_authenticate", "start_vm"];

/// How a **Fix** button does its work.
///
/// A Fix button is LCC doing something *itself*, so no route here may need a
/// tool the default install does not ship. `start_vm` used to shell out to
/// `gcloud compute instances start`: on a native install with no gcloud the
/// only Fix button besides re-authentication simply failed, while the README
/// advertised it. The Compute REST call `api::start_instance` already uses
/// works on **both** engines — `get_access_token` resolves the engine
/// underneath it — so the route does not branch on the engine and this
/// enum carries none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FixRoute {
    /// LCC's own sign-in flow.
    Reauthenticate,
    /// `compute.instances.start`, through the same REST client the rest of
    /// the app uses.
    StartVmViaRest,
}

impl FixRoute {
    /// The external binary this route cannot work without, if any.
    ///
    /// The property the guard aims at: a route that answers `Some` cannot run
    /// on a default install, which is the defect this fix removes.
    fn external_binary(self) -> Option<&'static str> {
        match self {
            FixRoute::Reauthenticate => None,
            FixRoute::StartVmViaRest => None,
        }
    }
}

/// Which route a fix action id takes, or `None` if the id is unknown.
fn fix_route(fix_action_id: &str) -> Option<FixRoute> {
    match fix_action_id {
        "re_authenticate" => Some(FixRoute::Reauthenticate),
        "start_vm" => Some(FixRoute::StartVmViaRest),
        _ => None,
    }
}

pub async fn execute_doctor_fix(
    fix_action_id: &str,
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<String> {
    info!("🔧 Executing doctor fix: {}", fix_action_id);

    let route = fix_route(fix_action_id).ok_or_else(|| {
        anyhow!(
            "Unknown fix action: {} (known: {})",
            fix_action_id,
            FIX_ACTION_IDS.join(", ")
        )
    })?;

    // The invariant, enforced where it is dispatched and not only where it is
    // declared: a Fix button that needs a tool outside LCC does nothing on a
    // default install, so it must not run at all rather than fail obscurely.
    if let Some(bin) = route.external_binary() {
        return Err(anyhow!(
            "Fix action '{}' would need '{}', which LCC does not require",
            fix_action_id,
            bin
        ));
    }

    match route {
        FixRoute::Reauthenticate => {
            crate::accounts::reauthenticate().await?;
            Ok("Re-authentication completed. Please run Doctor again.".to_string())
        }
        FixRoute::StartVmViaRest => {
            crate::gcp_rest_client::start_instance_client_lib(project_id, zone, instance_name)
                .await?;
            Ok(format!("VM '{}' start command issued. It may take a few minutes.", instance_name))
        }
    }
}

// ==========================================
// PUBLIC API FUNCTIONS
// ==========================================

pub async fn run_doctor(
    project_id: String,
    zone: String,
    instance_name: String,
) -> Result<DoctorReport> {
    let client = DoctorClient::new();
    Ok(client.run_all_checks(&project_id, &zone, &instance_name).await)
}

pub fn generate_doctor_report(report: DoctorReport) -> String {
    generate_doctor_report_markdown(&report)
}

pub async fn execute_fix(
    fix_action_id: String,
    project_id: String,
    zone: String,
    instance_name: String,
) -> Result<String> {
    execute_doctor_fix(&fix_action_id, &project_id, &zone, &instance_name).await
}

// ==========================================
// TESTS
// ==========================================

#[cfg(test)]
mod tests {
    use super::*;

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

    /// Bajo el motor nativo, no tener gcloud no es un fallo: es irrelevante.
    /// El usuario objetivo tras D5 es precisamente quien no lo tiene.
    #[test]
    fn a_missing_gcloud_is_skipped_under_the_native_engine() {
        let r = gcloud_check_status(crate::oauth::AuthEngine::Native, false);
        assert_eq!(r, DoctorCheckStatus::Skipped);
    }

    /// Bajo el motor gcloud sí importa, y sigue siendo un fallo.
    #[test]
    fn a_missing_gcloud_still_fails_under_the_gcloud_engine() {
        let r = gcloud_check_status(crate::oauth::AuthEngine::Gcloud, false);
        assert_eq!(r, DoctorCheckStatus::Fail);
    }

    #[test]
    fn a_present_gcloud_passes_on_the_engine_that_uses_it() {
        assert_eq!(
            gcloud_check_status(crate::oauth::AuthEngine::Gcloud, true),
            DoctorCheckStatus::Pass
        );
    }

    /// Compute Engine gatea todo lo demás en su categoría: un estado que no
    /// sea ENABLED es un Fail real.
    #[test]
    fn a_required_api_not_enabled_is_a_failure() {
        assert_eq!(severity_when_unhealthy(true), DoctorCheckStatus::Fail);
    }

    /// La API de IAP no gatea nada que LCC llame — el túnel habla directo con
    /// tunnel.cloudproxy.app — así que no confirmar ENABLED es, como mucho,
    /// un aviso, nunca un Fail que mande al usuario a arreglar algo que no
    /// está roto.
    #[test]
    fn a_non_required_api_not_enabled_is_only_a_warning() {
        assert_eq!(severity_when_unhealthy(false), DoctorCheckStatus::Warning);
    }

    /// Hallazgo 4 de la revisión de D5. Bajo el motor nativo, un token que
    /// falla no puede enseñar un comando de gcloud ni un botón que lo ejecute:
    /// el usuario al que sirve ese motor puede no tener gcloud siquiera.
    #[test]
    fn a_token_failure_never_prescribes_gcloud_under_the_native_engine() {
        let (suggestion, fix_command, fix_action_id) =
            token_failure_remedy(crate::oauth::AuthEngine::Native);

        assert!(
            !suggestion.unwrap().contains("gcloud"),
            "la sugerencia bajo nativo no puede nombrar gcloud"
        );
        assert_eq!(fix_command, None, "ni un comando que ejecutar");
        assert_eq!(
            fix_action_id.as_deref(),
            Some("re_authenticate"),
            "el remedio nativo es volver a iniciar sesión en LCC"
        );
    }

    /// Y bajo el motor gcloud sigue diciendo exactamente lo que decía: ese
    /// mensaje es lo que le indica al usuario de la escotilla qué ejecutar.
    #[test]
    fn a_token_failure_still_prescribes_adc_under_the_gcloud_engine() {
        let (suggestion, fix_command, fix_action_id) =
            token_failure_remedy(crate::oauth::AuthEngine::Gcloud);

        assert_eq!(
            suggestion.as_deref(),
            Some("Re-authenticate with 'gcloud auth application-default login'.")
        );
        assert_eq!(
            fix_command.as_deref(),
            Some("gcloud auth application-default login")
        );
        assert_eq!(fix_action_id, None);
    }

    #[test]
    fn test_check_gcloud_installed() {
        let client = DoctorClient::new();
        let result = client.check_gcloud_installed();
        assert_eq!(result.check_id, "auth_gcloud_installed");
        assert_eq!(result.category, DoctorCheckCategory::Authentication);
        // Status depends on environment, but check_id and category should be correct
    }

    #[test]
    fn test_check_local_clients() {
        let client = DoctorClient::new();
        let result = client.check_local_clients();
        assert_eq!(result.check_id, "local_clients");
        assert_eq!(result.category, DoctorCheckCategory::LocalEnvironment);
        // Should have details about available clients
        assert!(result.details.is_some());
    }

    #[test]
    fn test_report_markdown_generation() {
        let report = DoctorReport {
            checks: vec![
                DoctorCheckResult {
                    check_id: "test_check".to_string(),
                    name: "Test Check".to_string(),
                    category: DoctorCheckCategory::Authentication,
                    status: DoctorCheckStatus::Pass,
                    message: "All good".to_string(),
                    details: Some("Detailed info".to_string()),
                    suggestion: None,
                    fix_command: None,
                    fix_action_id: None,
                    duration_ms: 42,
                },
            ],
            project_id: "test-project".to_string(),
            zone: "us-central1-a".to_string(),
            instance_name: "test-vm".to_string(),
            generated_at: "2024-01-01T00:00:00Z".to_string(),
            gcloud_version: Some("Google Cloud SDK 400.0.0".to_string()),
            gcloud_account: Some("test@example.com".to_string()),
            total_duration_ms: 100,
            pass_count: 1,
            warning_count: 0,
            fail_count: 0,
            skipped_count: 0,
        };

        let md = generate_doctor_report_markdown(&report);
        assert!(md.contains("# Connectivity Doctor Report"));
        assert!(md.contains("test-project"));
        assert!(md.contains("test-vm"));
        assert!(md.contains("Test Check"));
        assert!(md.contains("[PASS]"));
        assert!(md.contains("Authentication"));
    }

    #[test]
    fn test_report_redacts_sensitive_data() {
        let report = DoctorReport {
            checks: vec![
                DoctorCheckResult {
                    check_id: "test".to_string(),
                    name: "Test".to_string(),
                    category: DoctorCheckCategory::Authentication,
                    status: DoctorCheckStatus::Fail,
                    message: "Error with token".to_string(),
                    details: Some(r#"access_token: "ya29.secret_value_12345""#.to_string()),
                    suggestion: None,
                    fix_command: None,
                    fix_action_id: None,
                    duration_ms: 10,
                },
            ],
            project_id: "my-project".to_string(),
            zone: "us-central1-a".to_string(),
            instance_name: "my-vm".to_string(),
            generated_at: "2024-01-01T00:00:00Z".to_string(),
            gcloud_version: None,
            gcloud_account: None,
            total_duration_ms: 10,
            pass_count: 0,
            warning_count: 0,
            fail_count: 1,
            skipped_count: 0,
        };

        let md = generate_doctor_report_markdown(&report);
        assert!(!md.contains("ya29.secret_value_12345"));
        assert!(md.contains("[REDACTED]"));
    }

    #[test]
    fn test_category_display_names() {
        assert_eq!(DoctorCheckCategory::Authentication.display_name(), "Authentication");
        assert_eq!(DoctorCheckCategory::ProjectPermissions.display_name(), "Project & Permissions");
        assert_eq!(DoctorCheckCategory::IapNetwork.display_name(), "IAP & Network");
        assert_eq!(DoctorCheckCategory::VmStatus.display_name(), "VM Status");
        assert_eq!(DoctorCheckCategory::LocalEnvironment.display_name(), "Local Environment");
    }

    #[test]
    fn test_category_all() {
        let cats = DoctorCheckCategory::all();
        assert_eq!(cats.len(), 5);
    }

    #[test]
    fn test_skipped_check() {
        let client = DoctorClient::new();
        let result = client.skipped_check(
            "test_id",
            "Test Name",
            DoctorCheckCategory::Authentication,
            "Skipped for testing",
            Instant::now(),
        );
        assert_eq!(result.status, DoctorCheckStatus::Skipped);
        assert_eq!(result.check_id, "test_id");
        assert_eq!(result.name, "Test Name");
    }

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

    /// La prueba negativa del secreto: el mensaje nunca lleva el token. La
    /// forma es la de un cuerpo de error real de Google, que es donde el token
    /// aparecería de verdad.
    #[test]
    fn no_outcome_can_carry_a_token() {
        let leaky = "refresh failed: {\"access_token\": \"ya29.A0ARrdaM-secret\"}";
        for r in [
            token_check_outcome(None),
            token_check_outcome(Some(Ok("someone@example.com".to_string()))),
            token_check_outcome(Some(Err(leaky.to_string()))),
        ] {
            assert!(!r.1.contains("ya29."), "el mensaje llevaba el token: {}", r.1);
            assert!(!r.2.clone().unwrap_or_default().contains("ya29."));
        }
    }


    /// Un token acuñado de verdad es éxito: el único caso `Ok`.
    #[test]
    fn a_minted_token_is_success() {
        let r = refresh_verdict(Ok(crate::oauth::RefreshOutcome::Token(
            crate::oauth::RefreshedToken {
                access_token: "unused".to_string(),
                expires_in_secs: 3600,
            },
        )));
        assert!(r.is_ok());
    }

    /// `NeedsReauth` es Google diciendo que el refresh token guardado está
    /// muerto: es justo el estado que esta fila existe para detectar, así que
    /// nunca puede leerse como éxito.
    #[test]
    fn needs_reauth_is_never_success() {
        let r = refresh_verdict(Ok(crate::oauth::RefreshOutcome::NeedsReauth));
        assert!(r.is_err());
        let msg = r.unwrap_err();
        assert!(msg.contains("invalid_grant"), "el motivo debe seguir siendo reconocible: {}", msg);
    }

    /// Un error de transporte (red, timeout) también es un fallo, distinto de
    /// `NeedsReauth`.
    #[test]
    fn a_transport_error_is_a_failure() {
        let r = refresh_verdict(Err("network is unreachable".to_string()));
        assert!(r.is_err());
        assert_eq!(r.unwrap_err(), "network is unreachable");
    }

    /// Builds a `DoctorCheckResult` with just the `check_id` and `status` that
    /// matter to a test, everything else empty.
    fn row(check_id: &str, status: DoctorCheckStatus) -> DoctorCheckResult {
        DoctorCheckResult {
            check_id: check_id.to_string(),
            name: String::new(),
            category: DoctorCheckCategory::Authentication,
            status,
            message: String::new(),
            details: None,
            suggestion: None,
            fix_command: None,
            fix_action_id: None,
            duration_ms: 0,
        }
    }

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

    // ---- Hallazgo 3: el motivo del salto no puede afirmar lo no comprobado ----

    /// Bajo el motor nativo la sonda de gcloud NO se ejecuta, así que "no está
    /// instalado" es una afirmación que nadie verificó — y va dentro de un
    /// informe que se exporta a tickets. El motivo tiene que ser el motor.
    #[test]
    fn the_native_engine_never_blames_a_gcloud_it_did_not_look_for() {
        let reason = gcloud_account_skip_reason(
            crate::oauth::AuthEngine::Native,
            DoctorCheckStatus::Skipped,
        );
        assert_eq!(reason, Some(NOT_APPLICABLE_NATIVE_ENGINE));
        assert!(
            !reason.unwrap().contains("not installed"),
            "el motivo afirma un hecho que la fila 1 no comprobó: {:?}",
            reason
        );
    }

    /// Bajo el motor gcloud la fila 1 sí miró, así que ahí el motivo puede —y
    /// debe— nombrar el binario ausente. Cambiar esto le quitaría el
    /// diagnóstico bueno a quien eligió ese motor.
    #[test]
    fn the_gcloud_engine_still_names_the_missing_binary() {
        assert_eq!(
            gcloud_account_skip_reason(
                crate::oauth::AuthEngine::Gcloud,
                DoctorCheckStatus::Fail
            ),
            Some(GCLOUD_NOT_INSTALLED)
        );
    }

    /// Y con gcloud presente bajo su motor, la fila no se salta: se ejecuta.
    #[test]
    fn a_present_gcloud_under_its_own_engine_is_not_skipped() {
        assert_eq!(
            gcloud_account_skip_reason(
                crate::oauth::AuthEngine::Gcloud,
                DoctorCheckStatus::Pass
            ),
            None
        );
    }

    // ---- Hallazgo 1: ningún botón Corregir puede exigir gcloud ----

    /// El guardián del hallazgo 1. Un botón **Corregir** es LCC haciendo algo
    /// por sí mismo; si su ruta necesita un binario externo, en la instalación
    /// por defecto no hace nada. Recorre la lista entera para que una acción
    /// nueva no pueda colarse por detrás del guardián.
    #[test]
    fn no_fix_button_needs_a_tool_outside_lcc() {
        for id in FIX_ACTION_IDS {
            let route = fix_route(id).unwrap_or_else(|| panic!("{} sin ruta", id));
            assert_eq!(
                route.external_binary(),
                None,
                "la acción {} se corrige lanzando {:?}, que la instalación por defecto no trae",
                id,
                route.external_binary()
            );
        }
    }

    /// Y la ruta concreta de "VM parada" es la REST que ya usa `api::start_instance`,
    /// no una segunda implementación.
    #[test]
    fn starting_a_vm_goes_through_the_rest_client() {
        assert_eq!(fix_route("start_vm"), Some(FixRoute::StartVmViaRest));
        assert_eq!(fix_route("re_authenticate"), Some(FixRoute::Reauthenticate));
        assert_eq!(fix_route("no_such_action"), None);
    }
}
