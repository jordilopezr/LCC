/// Google Cloud Client Libraries - Proof of Concept
///
/// Este módulo demuestra el uso de Google Cloud Client Libraries
/// en lugar de gcloud CLI para interactuar con GCP.
///
/// Objetivo del PoC:
/// 1. Autenticación con OAuth2
/// 2. Listar proyectos usando Resource Manager API
/// 3. Comparar performance vs gcloud CLI

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::time::Instant;
use std::path::PathBuf;
use std::env;
use std::sync::Arc;
use lazy_static::lazy_static;
use tracing::{info, debug, error};

// Import redact utilities for secure logging
use crate::redact::redact_sensitive;
use crate::validation::validate_gcp_url;

// ==========================================
// AUTENTICACIÓN - Versión Simplificada con Cacheo
// ==========================================

/// Gestor de autenticación para Google Cloud
///
/// Usa gcloud Application Default Credentials existentes
#[derive(Clone)]
pub struct GcpAuthClient {
    credentials_path: PathBuf,
    pub http_client: reqwest::Client,
}

// Global cached auth client (singleton pattern)
// This prevents reinitializing authentication on every API call
// Using lazy_static for FFI compatibility (stable Rust)
lazy_static! {
    static ref CACHED_AUTH_CLIENT: Result<Arc<GcpAuthClient>> = {
        info!("🔐 Initializing GCP authentication client (first time only)");

        // Synchronous initialization - just reads credentials path
        let home = env::var("HOME")
            .or_else(|_| env::var("USERPROFILE"))
            .map_err(|_| anyhow!("Could not determine home directory"))?;

        let creds_path = PathBuf::from(home)
            .join(".config")
            .join("gcloud")
            .join("application_default_credentials.json");

        if !creds_path.exists() {
            return Err(anyhow!(
                "Application Default Credentials not found.\n\n\
                 Please run: gcloud auth application-default login\n\
                 \n\
                 This will create credentials at:\n\
                 {}",
                creds_path.display()
            ));
        }

        debug!("✓ Found credentials at: {}", creds_path.display());

        Ok(Arc::new(GcpAuthClient {
            credentials_path: creds_path,
            http_client: reqwest::Client::new(),
        }))
    };
}

/// Access token cacheado en proceso.
///
/// Evita lanzar un `gcloud auth print-access-token` por cada llamada REST:
/// invocaciones concurrentes de gcloud fallan con el lock sqlite interno de
/// su credential store. El mutex además serializa la obtención cuando el
/// caché está frío. Los tokens de Google duran ~1h; un TTL corto deja margen
/// de sobra y sigue de cerca los cambios de cuenta.
struct CachedToken {
    token: String,
    fetched_at: Instant,
}

impl CachedToken {
    fn is_fresh(&self) -> bool {
        self.fetched_at.elapsed() < TOKEN_CACHE_TTL
    }
}

const TOKEN_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(300);

lazy_static! {
    static ref TOKEN_CACHE: tokio::sync::Mutex<Option<CachedToken>> =
        tokio::sync::Mutex::new(None);
}

/// Invalida el token cacheado (llamar tras cambiar la cuenta activa de gcloud)
pub async fn invalidate_cached_access_token() {
    let mut cache = TOKEN_CACHE.lock().await;
    *cache = None;
}

/// Extrae el access token del stdout de `gcloud auth print-access-token`.
///
/// Devuelve `None` si el output está vacío o contiene algo más que el token
/// (p.ej. warnings mezclados), para no mandar basura como Bearer token.
fn parse_cli_access_token(stdout: &str) -> Option<String> {
    let token = stdout.trim();
    if token.is_empty() || token.contains(char::is_whitespace) {
        return None;
    }
    Some(token.to_string())
}

/// After the gcloud CLI token path failed, decide whether a failed ADC
/// fallback should surface as a re-authentication prompt. True only when the
/// ADC credentials file is missing/unreadable — the user is still listed as
/// active by gcloud but has no usable token, so they must re-login. Other ADC
/// failures (a non-200 token exchange already carries the reauth wording; a
/// network/timeout error is transient) keep their own message.
fn adc_failure_needs_reauth(adc_err: &str) -> bool {
    adc_err.contains("Failed to read credentials")
}

impl GcpAuthClient {
    /// Get or initialize cached auth client (singleton pattern)
    /// This method ensures we only initialize authentication once,
    /// then reuse the same client for all subsequent calls.
    ///
    /// NOTE: This is now synchronous (no async) for FFI compatibility.
    /// The actual async token fetching happens in get_access_token()
    pub fn get_or_init() -> Result<Arc<Self>> {
        // Clone the Arc from the lazy_static cached result
        CACHED_AUTH_CLIENT.as_ref()
            .map(|arc| Arc::clone(arc))
            .map_err(|e| anyhow!("{}", e))
    }

    /// Obtener access token para las APIs de GCP
    ///
    /// Preferimos `gcloud auth print-access-token` porque sigue a la cuenta
    /// activa (selector de cuentas de la app) y gestiona el reauth de
    /// Workspace (RAPT); el intercambio directo del refresh token de ADC
    /// falla con `invalid_rapt` en cuentas corporativas y queda solo como
    /// fallback cuando gcloud CLI no está disponible.
    pub async fn get_access_token(&self) -> Result<String> {
        // El lock se mantiene durante toda la obtención: sirve de caché y a la
        // vez serializa los procesos gcloud (fallan si corren en paralelo).
        let mut cache = TOKEN_CACHE.lock().await;
        if let Some(cached) = cache.as_ref() {
            if cached.is_fresh() {
                return Ok(cached.token.clone());
            }
        }

        let token = match self.token_from_gcloud_cli().await {
            Ok(token) => token,
            Err(cli_err) => {
                debug!("gcloud CLI token unavailable, falling back to ADC: {}", cli_err);
                match self.token_from_adc_refresh().await {
                    Ok(token) => token,
                    Err(adc_err) => {
                        debug!("ADC fallback also failed: {}", adc_err);
                        if adc_failure_needs_reauth(&adc_err.to_string()) {
                            return Err(anyhow!(
                                "Authentication failed: your Google Cloud session has expired or requires reauthentication. \
                                 Run: gcloud auth login (and if it persists: gcloud auth application-default login)"
                            ));
                        }
                        return Err(adc_err);
                    }
                }
            }
        };

        *cache = Some(CachedToken {
            token: token.clone(),
            fetched_at: Instant::now(),
        });
        Ok(token)
    }

    /// Token vía `gcloud auth print-access-token` (cuenta activa + RAPT)
    async fn token_from_gcloud_cli(&self) -> Result<String> {
        let output = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            tokio::process::Command::new("gcloud")
                .args(["auth", "print-access-token"])
                .output(),
        )
        .await
        .map_err(|_| anyhow!("Timeout: gcloud auth print-access-token took longer than 15 seconds"))?
        .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow!("gcloud error: {}", redact_sensitive(&stderr)));
        }

        parse_cli_access_token(&String::from_utf8_lossy(&output.stdout))
            .ok_or_else(|| anyhow!("Unexpected output from gcloud auth print-access-token"))
    }

    /// Fallback: intercambio directo del refresh token de ADC
    async fn token_from_adc_refresh(&self) -> Result<String> {
        debug!("Getting access token from gcloud credentials");

        // Leer el archivo de credenciales
        let creds_json = std::fs::read_to_string(&self.credentials_path)
            .map_err(|e| anyhow!("Failed to read credentials: {}", e))?;

        // Parse credentials
        let creds: serde_json::Value = serde_json::from_str(&creds_json)?;

        // Para este PoC, vamos a usar el refresh token para obtener un access token
        // usando la API de OAuth2 directamente
        let client_id = creds["client_id"].as_str()
            .ok_or_else(|| anyhow!("No client_id in credentials"))?;
        let client_secret = creds["client_secret"].as_str()
            .ok_or_else(|| anyhow!("No client_secret in credentials"))?;
        let refresh_token = creds["refresh_token"].as_str()
            .ok_or_else(|| anyhow!("No refresh_token in credentials"))?;

        debug!("Using OAuth2 credentials to get access token");

        // Usar el HTTP client cacheado para hacer el token exchange
        let client = &self.http_client;
        let params = [
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token"),
        ];

        let token_url = "https://oauth2.googleapis.com/token";
        validate_gcp_url(token_url)?;

        let response = client
            .post(token_url)
            .form(&params)
            .send()
            .await
            .map_err(|e| anyhow!("Token request failed: {}", e))?;

        if !response.status().is_success() {
            let error_text = response.text().await.unwrap_or_default();
            // SECURITY: Redact any sensitive data before logging
            debug!("Token exchange failed with error: {}", redact_sensitive(&error_text));
            return Err(anyhow!(
                "Authentication failed: your Google Cloud session has expired or requires reauthentication. \
                 Run: gcloud auth login (and if it persists: gcloud auth application-default login)"
            ));
        }

        let token_response: serde_json::Value = response.json().await?;
        let access_token = token_response["access_token"].as_str()
            .ok_or_else(|| anyhow!("No access_token in response"))?
            .to_string();

        debug!("✓ Got valid access token");
        Ok(access_token)
    }
}

// ==========================================
// RESOURCE MANAGER API - PROYECTOS
// ==========================================

/// Google Cloud Project (Client Library version)
/// This struct is used by the Client Libraries implementation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GcpProjectClientLib {
    pub project_id: String,
    pub name: Option<String>,
    pub project_number: String,
    pub state: String,
}

// Keep internal version for backwards compatibility
type GcpProject = GcpProjectClientLib;

/// Google Cloud Compute Instance (Client Library version)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GcpInstanceClientLib {
    pub name: String,
    pub status: String,
    pub zone: String,
    pub machine_type: String,
    pub cpu_count: Option<u32>,
    pub memory_mb: Option<u32>,
    pub disk_gb: Option<u32>,
    pub labels: Vec<(String, String)>,
    pub os_login_enabled: bool,
    pub is_windows: bool,
}

/// Cliente para interactuar con Resource Manager API
pub struct ResourceManagerClient {
    auth: Arc<GcpAuthClient>,
    http_client: reqwest::Client,
    base_url: String,
}

impl ResourceManagerClient {
    pub async fn new() -> Result<Self> {
        // Use cached auth client instead of creating a new one
        let auth = GcpAuthClient::get_or_init()?;

        let base_url = "https://cloudresourcemanager.googleapis.com/v1".to_string();
        validate_gcp_url(&base_url)?;

        let http_client = auth.http_client.clone();

        Ok(Self { auth, http_client, base_url })
    }

    /// Listar todos los proyectos accesibles
    ///
    /// ANTES (gcloud CLI):
    /// ```text
    /// gcloud projects list --format=json
    /// ```
    ///
    /// AHORA (Client Library):
    /// Hace request directo a Resource Manager API
    pub async fn list_projects(&self) -> Result<Vec<GcpProject>> {
        info!("📁 Listing GCP projects via REST API");
        let start = Instant::now();

        // Obtener access token
        let token = self.auth.get_access_token().await?;

        // Usar el HTTP client cacheado
        let client = &self.http_client;

        // Request a la API
        let url = format!("{}/projects", self.base_url);

        debug!("Making request to: {}", url);

        let response = client
            .get(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            // SECURITY: Redact sensitive data from error logs
            error!("API request failed: {} - {}", status, redact_sensitive(&error_text));
            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        // Parse response
        let response_text = response.text().await?;
        debug!("Response received: {} bytes", response_text.len());

        let response_json: serde_json::Value = serde_json::from_str(&response_text)
            .map_err(|e| anyhow!("Failed to parse JSON: {}", e))?;

        // Extraer proyectos del response (API v1 format)
        let projects_array = response_json["projects"]
            .as_array()
            .ok_or_else(|| anyhow!("No projects array in response"))?;

        let mut projects = Vec::new();

        for project_obj in projects_array {
            projects.push(GcpProject {
                project_id: project_obj["projectId"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string(),
                name: project_obj["name"]
                    .as_str()
                    .map(|s| s.to_string()),
                project_number: project_obj["projectNumber"]
                    .as_u64()
                    .map(|n| n.to_string())
                    .or_else(|| project_obj["projectNumber"].as_str().map(|s| s.to_string()))
                    .unwrap_or_default(),
                state: project_obj["lifecycleState"]
                    .as_str()
                    .unwrap_or("UNKNOWN")
                    .to_string(),
            });
        }

        let elapsed = start.elapsed();
        info!(
            "✓ Listed {} projects in {:?} (Client Library)",
            projects.len(),
            elapsed
        );

        Ok(projects)
    }
}

// ==========================================
// FUNCIONES PÚBLICAS PARA FFI BRIDGE
// ==========================================

/// Comparar performance: Client Library vs gcloud CLI (async version)
pub async fn benchmark_list_projects_async() -> Result<String> {
    info!("🏁 Starting benchmark: Client Library vs gcloud CLI");

    // Benchmark 1: Client Library
    info!("\n=== Test 1: Google Cloud Client Library ===");
    let start_client = Instant::now();

    let client = ResourceManagerClient::new().await?;
    let projects_client = client.list_projects().await?;

    let time_client = start_client.elapsed();
    info!("✓ Client Library: {} projects in {:?}", projects_client.len(), time_client);

    // Benchmark 2: gcloud CLI (para comparación)
    info!("\n=== Test 2: gcloud CLI (existing implementation) ===");
    let start_cli = Instant::now();

    let projects_cli = crate::gcloud::get_projects_async().await?;

    let time_cli = start_cli.elapsed();
    info!("✓ gcloud CLI: {} projects in {:?}", projects_cli.len(), time_cli);

    // Calcular mejora
    let speedup = time_cli.as_secs_f64() / time_client.as_secs_f64();

    let result = format!(
        "📊 BENCHMARK RESULTS\n\
         ==================\n\
         \n\
         Client Library: {:?}\n\
         gcloud CLI:     {:?}\n\
         \n\
         Speed improvement: {:.2}x faster 🚀\n\
         \n\
         Projects found:\n\
         - Client Library: {} projects\n\
         - gcloud CLI:     {} projects\n\
         \n\
         {} Match: {}",
        time_client,
        time_cli,
        speedup,
        projects_client.len(),
        projects_cli.len(),
        if projects_client.len() == projects_cli.len() { "✅" } else { "⚠️" },
        if projects_client.len() == projects_cli.len() {
            "Results are consistent!"
        } else {
            "Warning: Different number of projects"
        }
    );

    info!("\n{}", result);
    Ok(result)
}

/// Test simple de autenticación (async version)
pub async fn test_authentication_async() -> Result<String> {
    info!("🔐 Testing GCP authentication");

    // Use cached auth client
    let auth = GcpAuthClient::get_or_init()?;
    let token = auth.get_access_token().await?;

    // Verificar que el token no está vacío
    if token.is_empty() {
        return Err(anyhow!("Received empty access token"));
    }

    let message = "✅ Authentication successful!\n\
         \n\
         You are now authenticated with Google Cloud!".to_string();

    info!("{}", message);
    debug!("Token received, length: {} characters", token.len());
    Ok(message)
}

/// Listar proyectos (interfaz simplificada para FFI)
pub async fn list_projects_simple_async() -> Result<Vec<GcpProject>> {
    let client = ResourceManagerClient::new().await?;
    client.list_projects().await
}

// ==========================================
// COMPUTE ENGINE API - INSTANCIAS
// ==========================================

/// Extract CPU and memory specs from machine type name
/// Supports standard machine types by parsing their pattern (e.g., "e2-standard-4" → 4 CPUs)
/// Returns (cpu_count, memory_mb) if the machine type can be determined
fn get_machine_specs(machine_type: &str) -> Option<(u32, u32)> {
    // Special cases (micro, small, medium)
    match machine_type {
        "e2-micro" => return Some((2, 1024)),
        "e2-small" => return Some((2, 2048)),
        "e2-medium" => return Some((2, 4096)),
        "f1-micro" => return Some((1, 614)),
        "g1-small" => return Some((1, 1740)),
        _ => {}
    }

    // Parse standard machine types: {series}-{type}-{cpus}
    // Examples: e2-standard-4, n1-standard-8, n2-highmem-16, c2-standard-30
    let parts: Vec<&str> = machine_type.split('-').collect();

    if parts.len() >= 3 {
        let series = parts[0];      // e2, n1, n2, n2d, c2, c3, t2d, etc.
        let type_name = parts[1];   // standard, highmem, highcpu, custom

        // Try to parse CPU count from the last part
        if let Ok(cpu_count) = parts[2].parse::<u32>() {
            // Calculate memory based on type and series
            let memory_mb = match (series, type_name) {
                // E2 series (cost-optimized): 4GB per vCPU for standard
                ("e2", "standard") => cpu_count * 4096,
                ("e2", "highmem") => cpu_count * 8192,
                ("e2", "highcpu") => cpu_count * 1024,

                // N1 series: 3.75GB per vCPU for standard
                ("n1", "standard") => cpu_count * 3840,
                ("n1", "highmem") => cpu_count * 6656,
                ("n1", "highcpu") => cpu_count * 922,

                // N2/N2D series: 4GB per vCPU for standard
                ("n2" | "n2d", "standard") => cpu_count * 4096,
                ("n2" | "n2d", "highmem") => cpu_count * 8192,
                ("n2" | "n2d", "highcpu") => cpu_count * 1024,

                // C2 series (compute-optimized): 4GB per vCPU
                ("c2", "standard") => cpu_count * 4096,

                // C3 series (newer compute): 4GB per vCPU
                ("c3", "standard") => cpu_count * 4096,
                ("c3", "highmem") => cpu_count * 8192,
                ("c3", "highcpu") => cpu_count * 2048,

                // T2D series (AMD): 4GB per vCPU
                ("t2d", "standard") => cpu_count * 4096,

                // M1/M2/M3 series (memory-optimized): Much higher memory
                ("m1", "megamem") => cpu_count * 14336,  // 14GB per vCPU
                ("m1", "ultramem") => cpu_count * 24576, // 24GB per vCPU
                ("m2", "megamem") => cpu_count * 14336,
                ("m2", "ultramem") => cpu_count * 24576,
                ("m3", "megamem") => cpu_count * 14336,
                ("m3", "ultramem") => cpu_count * 24576,

                // A2 series (GPU): 12GB per vCPU
                ("a2", _) => cpu_count * 12288,

                // Default fallback: assume 4GB per vCPU (most common)
                _ => cpu_count * 4096,
            };

            return Some((cpu_count, memory_mb));
        }
    }

    // If we can't parse it, return None
    None
}

/// Cliente para interactuar con Compute Engine API
pub struct ComputeEngineClient {
    auth: Arc<GcpAuthClient>,
    http_client: reqwest::Client,
    base_url: String,
}

impl ComputeEngineClient {
    pub async fn new() -> Result<Self> {
        // Use cached auth client instead of creating a new one
        let auth = GcpAuthClient::get_or_init()?;

        let base_url = "https://compute.googleapis.com/compute/v1".to_string();
        validate_gcp_url(&base_url)?;

        let http_client = auth.http_client.clone();

        Ok(Self { auth, http_client, base_url })
    }

    /// Listar todas las instancias en un proyecto
    ///
    /// ANTES (gcloud CLI):
    /// ```text
    /// gcloud compute instances list --project=PROJECT_ID --format=json
    /// ```
    ///
    /// AHORA (Client Library):
    /// GET https://compute.googleapis.com/compute/v1/projects/{project}/aggregatedList/instances
    pub async fn list_instances(&self, project: &str) -> Result<Vec<GcpInstanceClientLib>> {
        info!("🖥️  Listing instances for project: {}", project);
        let start = Instant::now();

        // Obtener access token
        let token = self.auth.get_access_token().await?;

        // Usar el HTTP client cacheado
        let client = &self.http_client;

        // Request a la API (aggregatedList para obtener de todas las zonas)
        let url = format!("{}/projects/{}/aggregated/instances", self.base_url, project);

        debug!("Making request to: {}", url);

        let response = client
            .get(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            // SECURITY: Redact sensitive data from error logs
            error!("API request failed: {} - {}", status, redact_sensitive(&error_text));

            // Detect permission errors (403 Forbidden)
            if status.as_u16() == 403 {
                // Parse error to extract permission details
                if error_text.contains("compute.instances.list") {
                    return Err(anyhow!(
                        "PERMISSION_DENIED: You don't have permission to list instances in project '{}'. \
                        Required permission: 'compute.instances.list'. \
                        Please contact your GCP administrator to grant the necessary permissions.",
                        project
                    ));
                }
                return Err(anyhow!(
                    "PERMISSION_DENIED: Access denied to project '{}'. \
                    Please verify your permissions with your GCP administrator.",
                    project
                ));
            }

            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        // Parse response
        let response_text = response.text().await?;
        debug!("Response received: {} bytes", response_text.len());

        let response_json: serde_json::Value = serde_json::from_str(&response_text)
            .map_err(|e| anyhow!("Failed to parse JSON: {}", e))?;

        // Extraer instancias del response (aggregatedList format)
        let mut instances = Vec::new();

        if let Some(items) = response_json["items"].as_object() {
            for (_zone_name, zone_data) in items {
                if let Some(zone_instances) = zone_data["instances"].as_array() {
                    for instance_obj in zone_instances {
                        let name = instance_obj["name"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string();

                        let status = instance_obj["status"]
                            .as_str()
                            .unwrap_or("UNKNOWN")
                            .to_string();

                        // Extract zone from URL (e.g., "zones/us-central1-a" -> "us-central1-a")
                        let zone = instance_obj["zone"]
                            .as_str()
                            .and_then(|z| z.split('/').last())
                            .unwrap_or_default()
                            .to_string();

                        // Extract machine type from URL
                        let machine_type = instance_obj["machineType"]
                            .as_str()
                            .and_then(|mt| mt.split('/').last())
                            .unwrap_or_default()
                            .to_string();

                        // Extract disk size from boot disk
                        let disk_gb = instance_obj["disks"]
                            .as_array()
                            .and_then(|disks| {
                                disks.iter()
                                    .find(|d| d["boot"].as_bool().unwrap_or(false))
                                    .or_else(|| disks.first())
                            })
                            .and_then(|disk| disk["diskSizeGb"].as_str())
                            .and_then(|size| size.parse::<u32>().ok());

                        // Extract CPU and memory from machine type name
                        let (cpu_count, memory_mb) = get_machine_specs(&machine_type)
                            .map(|(cpu, mem)| (Some(cpu), Some(mem)))
                            .unwrap_or((None, None));

                        // Extract labels
                        let labels: Vec<(String, String)> = instance_obj["labels"]
                            .as_object()
                            .map(|obj| obj.iter().map(|(k, v)| {
                                (k.clone(), v.as_str().unwrap_or_default().to_string())
                            }).collect())
                            .unwrap_or_default();

                        // Detect OS Login from metadata items
                        let os_login_enabled = instance_obj["metadata"]["items"]
                            .as_array()
                            .map(|items| {
                                items.iter().any(|item| {
                                    let key = item["key"].as_str().unwrap_or_default();
                                    let value = item["value"].as_str().unwrap_or_default();
                                    (key == "enable-oslogin" || key == "enable-os-login")
                                        && value.eq_ignore_ascii_case("true")
                                })
                            })
                            .unwrap_or(false);

                        // Detect Windows from disk licenses
                        let is_windows = instance_obj["disks"]
                            .as_array()
                            .map(|disks| {
                                disks.iter().any(|disk| {
                                    disk["licenses"].as_array().map(|licenses| {
                                        licenses.iter().any(|l| {
                                            l.as_str().unwrap_or_default().to_lowercase().contains("windows")
                                        })
                                    }).unwrap_or(false)
                                })
                            })
                            .unwrap_or(false);

                        instances.push(GcpInstanceClientLib {
                            name,
                            status,
                            zone,
                            machine_type,
                            cpu_count,
                            memory_mb,
                            disk_gb,
                            labels,
                            os_login_enabled,
                            is_windows,
                        });
                    }
                }
            }
        }

        let elapsed = start.elapsed();
        info!(
            "✓ Listed {} instances in {:?} (Client Library)",
            instances.len(),
            elapsed
        );

        Ok(instances)
    }

    /// Obtener una instancia específica por proyecto, zona y nombre
    ///
    /// Usa `compute.instances.get` en lugar de `compute.instances.list`
    /// Útil cuando el usuario tiene permisos para ver instancias específicas
    /// pero no para listar todas las instancias del proyecto.
    ///
    /// GET https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{instance}
    pub async fn get_instance(&self, project: &str, zone: &str, instance_name: &str) -> Result<GcpInstanceClientLib> {
        info!("🔍 Getting instance: {}/{}/{}", project, zone, instance_name);
        let start = Instant::now();

        let token = self.auth.get_access_token().await?;
        let client = &self.http_client;

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}",
            self.base_url, project, zone, instance_name
        );

        debug!("Making request to: {}", url);

        let response = client
            .get(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            error!("API request failed: {} - {}", status, redact_sensitive(&error_text));

            if status.as_u16() == 403 {
                return Err(anyhow!(
                    "PERMISSION_DENIED: You don't have permission to view instance '{}' in project '{}'. \
                    Required permission: 'compute.instances.get'.",
                    instance_name, project
                ));
            }
            if status.as_u16() == 404 {
                return Err(anyhow!(
                    "NOT_FOUND: Instance '{}' not found in zone '{}' of project '{}'.",
                    instance_name, zone, project
                ));
            }

            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        let response_text = response.text().await?;
        let instance_obj: serde_json::Value = serde_json::from_str(&response_text)
            .map_err(|e| anyhow!("Failed to parse JSON: {}", e))?;

        // Parse instance data
        let name = instance_obj["name"]
            .as_str()
            .unwrap_or_default()
            .to_string();

        let status = instance_obj["status"]
            .as_str()
            .unwrap_or("UNKNOWN")
            .to_string();

        let machine_type = instance_obj["machineType"]
            .as_str()
            .and_then(|mt| mt.split('/').last())
            .unwrap_or_default()
            .to_string();

        let disk_gb = instance_obj["disks"]
            .as_array()
            .and_then(|disks| {
                disks.iter()
                    .find(|d| d["boot"].as_bool().unwrap_or(false))
                    .or_else(|| disks.first())
            })
            .and_then(|disk| disk["diskSizeGb"].as_str())
            .and_then(|size| size.parse::<u32>().ok());

        let (cpu_count, memory_mb) = get_machine_specs(&machine_type)
            .map(|(cpu, mem)| (Some(cpu), Some(mem)))
            .unwrap_or((None, None));

        let elapsed = start.elapsed();
        info!(
            "✓ Got instance {} ({}) in {:?}",
            name, status, elapsed
        );

        // Extract labels
        let labels: Vec<(String, String)> = instance_obj["labels"]
            .as_object()
            .map(|obj| obj.iter().map(|(k, v)| {
                (k.clone(), v.as_str().unwrap_or_default().to_string())
            }).collect())
            .unwrap_or_default();

        // Detect OS Login from metadata items
        let os_login_enabled = instance_obj["metadata"]["items"]
            .as_array()
            .map(|items| {
                items.iter().any(|item| {
                    let key = item["key"].as_str().unwrap_or_default();
                    let value = item["value"].as_str().unwrap_or_default();
                    (key == "enable-oslogin" || key == "enable-os-login")
                        && value.eq_ignore_ascii_case("true")
                })
            })
            .unwrap_or(false);

        // Detect Windows from disk licenses
        let is_windows = instance_obj["disks"]
            .as_array()
            .map(|disks| {
                disks.iter().any(|disk| {
                    disk["licenses"].as_array().map(|licenses| {
                        licenses.iter().any(|l| {
                            l.as_str().unwrap_or_default().to_lowercase().contains("windows")
                        })
                    }).unwrap_or(false)
                })
            })
            .unwrap_or(false);

        Ok(GcpInstanceClientLib {
            name,
            status,
            zone: zone.to_string(),
            machine_type,
            cpu_count,
            memory_mb,
            disk_gb,
            labels,
            os_login_enabled,
            is_windows,
        })
    }

    /// Iniciar una instancia detenida
    ///
    /// ANTES (gcloud CLI):
    /// ```text
    /// gcloud compute instances start INSTANCE --zone=ZONE --project=PROJECT
    /// ```
    ///
    /// AHORA (Client Library):
    /// POST https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{instance}/start
    pub async fn start_instance(&self, project: &str, zone: &str, instance: &str) -> Result<()> {
        info!("▶️  Starting instance: {} in {}/{}", instance, project, zone);

        let token = self.auth.get_access_token().await?;
        let client = &self.http_client;

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/start",
            self.base_url, project, zone, instance
        );

        let response = client
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        info!("✓ Instance start operation initiated");
        Ok(())
    }

    /// Detener una instancia en ejecución
    ///
    /// POST https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{instance}/stop
    pub async fn stop_instance(&self, project: &str, zone: &str, instance: &str) -> Result<()> {
        info!("⏹️  Stopping instance: {} in {}/{}", instance, project, zone);

        let token = self.auth.get_access_token().await?;
        let client = &self.http_client;

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/stop",
            self.base_url, project, zone, instance
        );

        let response = client
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        info!("✓ Instance stop operation initiated");
        Ok(())
    }

    /// Reiniciar una instancia
    ///
    /// POST https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{instance}/reset
    pub async fn reset_instance(&self, project: &str, zone: &str, instance: &str) -> Result<()> {
        info!("🔄 Resetting instance: {} in {}/{}", instance, project, zone);

        let token = self.auth.get_access_token().await?;
        let client = &self.http_client;

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/reset",
            self.base_url, project, zone, instance
        );

        let response = client
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        info!("✓ Instance reset operation initiated");
        Ok(())
    }

    /// Suspend a running instance
    ///
    /// POST https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{instance}/suspend
    pub async fn suspend_instance(&self, project: &str, zone: &str, instance: &str) -> Result<()> {
        info!("⏸️  Suspending instance: {} in {}/{}", instance, project, zone);

        let token = self.auth.get_access_token().await?;
        let client = &self.http_client;

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/suspend",
            self.base_url, project, zone, instance
        );

        let response = client
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            return Err(anyhow!("API error {}: {}", status, crate::redact::redact_sensitive(&error_text)));
        }

        info!("✓ Instance suspend operation initiated");
        Ok(())
    }

    /// Resume a suspended instance
    ///
    /// POST https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{instance}/resume
    pub async fn resume_instance(&self, project: &str, zone: &str, instance: &str) -> Result<()> {
        info!("▶️  Resuming instance: {} in {}/{}", instance, project, zone);

        let token = self.auth.get_access_token().await?;
        let client = &self.http_client;

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/resume",
            self.base_url, project, zone, instance
        );

        let response = client
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            return Err(anyhow!("API error {}: {}", status, crate::redact::redact_sensitive(&error_text)));
        }

        info!("✓ Instance resume operation initiated");
        Ok(())
    }
}

/// List instances using Client Libraries (public API for FFI)
pub async fn list_instances_client_lib(project: &str) -> Result<Vec<GcpInstanceClientLib>> {
    let client = ComputeEngineClient::new().await?;
    client.list_instances(project).await
}

/// Start instance using Client Libraries (public API for FFI)
pub async fn start_instance_client_lib(project: &str, zone: &str, instance: &str) -> Result<()> {
    let client = ComputeEngineClient::new().await?;
    client.start_instance(project, zone, instance).await
}

/// Stop instance using Client Libraries (public API for FFI)
pub async fn stop_instance_client_lib(project: &str, zone: &str, instance: &str) -> Result<()> {
    let client = ComputeEngineClient::new().await?;
    client.stop_instance(project, zone, instance).await
}

/// Reset instance using Client Libraries (public API for FFI)
pub async fn reset_instance_client_lib(project: &str, zone: &str, instance: &str) -> Result<()> {
    let client = ComputeEngineClient::new().await?;
    client.reset_instance(project, zone, instance).await
}

/// Suspend instance using Client Libraries (public API for FFI)
pub async fn suspend_instance_client_lib(project: &str, zone: &str, instance: &str) -> Result<()> {
    let client = ComputeEngineClient::new().await?;
    client.suspend_instance(project, zone, instance).await
}

/// Resume instance using Client Libraries (public API for FFI)
pub async fn resume_instance_client_lib(project: &str, zone: &str, instance: &str) -> Result<()> {
    let client = ComputeEngineClient::new().await?;
    client.resume_instance(project, zone, instance).await
}

/// Get a single instance by project, zone, and name using Client Libraries (public API for FFI)
///
/// Uses `compute.instances.get` permission instead of `compute.instances.list`.
/// Useful when the user has permission to view specific instances but not to list all.
pub async fn get_instance_client_lib(project: &str, zone: &str, instance_name: &str) -> Result<GcpInstanceClientLib> {
    let client = ComputeEngineClient::new().await?;
    client.get_instance(project, zone, instance_name).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_cli_access_token_trims_newline() {
        let token = parse_cli_access_token("ya29.a0AfB_byDummyToken123\n").unwrap();
        assert_eq!(token, "ya29.a0AfB_byDummyToken123");
    }

    #[test]
    fn test_parse_cli_access_token_rejects_empty_output() {
        assert!(parse_cli_access_token("").is_none());
        assert!(parse_cli_access_token("\n").is_none());
    }

    #[test]
    fn test_parse_cli_access_token_rejects_multiline_garbage() {
        // e.g. warnings o texto de error mezclado en stdout
        assert!(parse_cli_access_token("WARNING: foo\nya29.token").is_none());
    }

    #[test]
    fn adc_missing_file_surfaces_reauth() {
        assert!(adc_failure_needs_reauth("Failed to read credentials: No such file or directory (os error 2)"));
        assert!(!adc_failure_needs_reauth("Token request failed: connection refused"));
        assert!(!adc_failure_needs_reauth("Authentication failed: your Google Cloud session has expired or requires reauthentication."));
    }

    #[test]
    fn test_cached_token_freshness() {
        let fresh = CachedToken {
            token: "t".to_string(),
            fetched_at: Instant::now(),
        };
        assert!(fresh.is_fresh());

        let expired = CachedToken {
            token: "t".to_string(),
            fetched_at: Instant::now() - TOKEN_CACHE_TTL,
        };
        assert!(!expired.is_fresh());
    }

    #[tokio::test]
    async fn test_auth_initialization() {
        let result = GcpAuthClient::get_or_init();
        assert!(result.is_ok(), "Authentication should succeed");
    }

    #[tokio::test]
    async fn test_get_access_token() {
        let auth = GcpAuthClient::get_or_init().unwrap();
        let token = auth.get_access_token().await.unwrap();
        assert!(!token.is_empty(), "Token should not be empty");
        assert!(token.len() > 50, "Token should be substantial");
    }

    #[tokio::test]
    async fn test_list_projects() {
        let projects = list_projects_simple_async().await.unwrap();

        assert!(!projects.is_empty(), "Should have at least one project");

        for project in &projects {
            assert!(!project.project_id.is_empty(), "Project ID should not be empty");
            println!("✓ Found project: {} ({})",
                project.name.as_ref().unwrap_or(&project.project_id),
                project.project_id
            );
        }
    }

    #[tokio::test]
    #[ignore]
    async fn test_benchmark() {
        let result = benchmark_list_projects_async().await;
        match &result {
            Ok(_) => {},
            Err(e) => println!("Benchmark failed with error: {:?}", e),
        }
        assert!(result.is_ok(), "Benchmark should complete successfully");
        println!("{}", result.unwrap());
    }
}
