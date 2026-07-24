// Proof of Concept: Google Cloud Client Libraries Migration
// Este archivo muestra cómo se vería el código migrado

use anyhow::{Result, anyhow};
use google_cloud_auth::credentials::CredentialsFile;
use google_cloud_auth::token::DefaultTokenSourceProvider;
use google_cloud_compute::client::{Client as ComputeClient, InstancesClient};
use google_cloud_resource_manager::client::Client as ResourceManagerClient;
use std::sync::Arc;
use tokio::time::{sleep, Duration, Instant};

// ==========================================
// PARTE 1: AUTENTICACIÓN
// ==========================================

/// Gestor de autenticación centralizado
pub struct GcpAuthManager {
    token_provider: DefaultTokenSourceProvider,
}

impl GcpAuthManager {
    /// Inicializar con Application Default Credentials
    /// Busca credenciales en este orden:
    /// 1. GOOGLE_APPLICATION_CREDENTIALS env var
    /// 2. gcloud default credentials (~/.config/gcloud/application_default_credentials.json)
    /// 3. Compute Engine metadata server (si corre en GCP)
    pub async fn new() -> Result<Self> {
        tracing::info!("Initializing GCP authentication");

        let config = google_cloud_auth::project::Config {
            audience: None,
            scopes: Some(vec![
                "https://www.googleapis.com/auth/cloud-platform".to_string(),
                "https://www.googleapis.com/auth/compute".to_string(),
            ]),
            // Permite usar credenciales de usuario (gcloud auth login) o service account
            sub: None,
        };

        let token_provider = DefaultTokenSourceProvider::new(config)
            .await
            .map_err(|e| anyhow!("Failed to initialize auth: {}", e))?;

        Ok(Self { token_provider })
    }

    /// Obtener token de acceso válido (refresh automático si expiró)
    pub async fn get_access_token(&self) -> Result<String> {
        let token = self.token_provider
            .token()
            .await
            .map_err(|e| anyhow!("Failed to get token: {}", e))?;

        Ok(token.access_token)
    }

    /// Para flujo OAuth2 interactivo (desktop app)
    /// Este método abre el browser para que el usuario autorice
    pub async fn login_interactive() -> Result<Self> {
        // TODO: Implementar OAuth2 PKCE flow
        // 1. Generate code verifier and challenge
        // 2. Open browser to OAuth consent screen
        // 3. Wait for authorization code on local HTTP server
        // 4. Exchange code for tokens
        // 5. Store refresh token securely (keyring)
        unimplemented!("OAuth2 flow - implementar si queremos login desde la app")
    }
}

// ==========================================
// PARTE 2: CLIENT POOL
// ==========================================

/// Pool centralizado de clients GCP
/// Mantiene conexiones persistentes y reutiliza clientes
pub struct GcpClientPool {
    auth: Arc<GcpAuthManager>,
    compute: Arc<ComputeClient>,
    resource_manager: Arc<ResourceManagerClient>,
}

impl GcpClientPool {
    pub async fn new() -> Result<Self> {
        let auth = Arc::new(GcpAuthManager::new().await?);

        // Configurar compute client
        let compute_config = google_cloud_compute::client::ClientConfig {
            timeout: Some(Duration::from_secs(30)),
            ..Default::default()
        };
        let compute = Arc::new(ComputeClient::new(compute_config).await?);

        // Configurar resource manager client
        let rm_config = google_cloud_resource_manager::client::ClientConfig {
            timeout: Some(Duration::from_secs(10)),
            ..Default::default()
        };
        let resource_manager = Arc::new(ResourceManagerClient::new(rm_config).await?);

        Ok(Self {
            auth,
            compute,
            resource_manager,
        })
    }

    pub fn compute(&self) -> &ComputeClient {
        &self.compute
    }

    pub fn resource_manager(&self) -> &ResourceManagerClient {
        &self.resource_manager
    }
}

// ==========================================
// PARTE 3: PROJECTS API
// ==========================================

#[derive(Debug, Clone)]
pub struct GcpProject {
    pub project_id: String,
    pub name: Option<String>,
    pub project_number: i64,
}

/// Listar todos los proyectos accesibles
///
/// ANTES (gcloud CLI):
/// ```rust
/// let output = Command::new("gcloud")
///     .args(["projects", "list", "--format=json"])
///     .output()?;
/// let projects: Vec<Project> = serde_json::from_slice(&output.stdout)?;
/// ```
///
/// DESPUÉS (Client Library):
pub async fn list_projects(client: &ResourceManagerClient) -> Result<Vec<GcpProject>> {
    use google_cloud_resource_manager::client::google::cloud::resourcemanager::v3::ListProjectsRequest;

    tracing::info!("Listing GCP projects");

    let mut request = ListProjectsRequest {
        page_size: 1000,
        ..Default::default()
    };

    let mut projects = Vec::new();

    loop {
        let response = client.list_projects(request.clone()).await?;

        for project in response.projects {
            projects.push(GcpProject {
                project_id: project.project_id,
                name: Some(project.display_name),
                project_number: project.name.parse().unwrap_or(0),
            });
        }

        // Manejar paginación automáticamente
        if response.next_page_token.is_empty() {
            break;
        }
        request.page_token = response.next_page_token;
    }

    tracing::info!(count = projects.len(), "Projects listed successfully");
    Ok(projects)
}

// ==========================================
// PARTE 4: COMPUTE INSTANCES API
// ==========================================

#[derive(Debug, Clone)]
pub struct GcpInstance {
    pub name: String,
    pub status: String,
    pub zone: String,
    pub machine_type: String,
    pub cpu_count: Option<u32>,
    pub memory_mb: Option<u32>,
    pub disk_gb: Option<u32>,
    pub internal_ip: Option<String>,
    pub external_ip: Option<String>,
}

/// Listar todas las instancias de un proyecto
///
/// ANTES (gcloud CLI):
/// ```rust
/// let output = Command::new("gcloud")
///     .args(["compute", "instances", "list", "--project", project_id])
///     .output()?;
/// // ... parsing manual de JSON ...
/// ```
///
/// DESPUÉS (Client Library):
pub async fn list_instances(
    client: &ComputeClient,
    project_id: &str,
) -> Result<Vec<GcpInstance>> {
    use google_cloud_compute::client::google::cloud::compute::v1::AggregatedListInstancesRequest;

    tracing::info!(project_id, "Listing instances");

    let request = AggregatedListInstancesRequest {
        project: project_id.to_string(),
        max_results: Some(500),
        ..Default::default()
    };

    let response = client.instances().aggregated_list(request).await?;

    let mut instances = Vec::new();

    for (_zone, scope) in response.items {
        if let Some(instance_list) = scope.instances {
            for inst in instance_list {
                // Extract zone name from URL
                let zone = inst.zone
                    .as_ref()
                    .and_then(|url| url.split('/').last())
                    .unwrap_or("unknown")
                    .to_string();

                // Extract machine type
                let machine_type = inst.machine_type
                    .as_ref()
                    .and_then(|url| url.split('/').last())
                    .unwrap_or("unknown")
                    .to_string();

                // Get IPs
                let (internal_ip, external_ip) = inst.network_interfaces
                    .as_ref()
                    .and_then(|interfaces| interfaces.first())
                    .map(|iface| {
                        let internal = iface.network_ip.clone();
                        let external = iface.access_configs
                            .as_ref()
                            .and_then(|configs| configs.first())
                            .and_then(|config| config.nat_ip.clone());
                        (internal, external)
                    })
                    .unwrap_or((None, None));

                instances.push(GcpInstance {
                    name: inst.name.unwrap_or_default(),
                    status: inst.status.unwrap_or_default(),
                    zone,
                    machine_type,
                    // TODO: Parse specs from machine type or metadata
                    cpu_count: None,
                    memory_mb: None,
                    disk_gb: inst.disks.as_ref()
                        .and_then(|disks| disks.first())
                        .and_then(|disk| disk.disk_size_gb)
                        .map(|size| size as u32),
                    internal_ip,
                    external_ip,
                });
            }
        }
    }

    tracing::info!(count = instances.len(), "Instances listed successfully");
    Ok(instances)
}

// ==========================================
// PARTE 5: INSTANCE LIFECYCLE
// ==========================================

/// Iniciar una instancia detenida
///
/// ANTES (gcloud CLI):
/// ```rust
/// let status = Command::new("gcloud")
///     .args(&["compute", "instances", "start", instance])
///     .status()?;
/// ```
///
/// DESPUÉS (Client Library):
pub async fn start_instance(
    client: &ComputeClient,
    project: &str,
    zone: &str,
    instance: &str,
) -> Result<()> {
    use google_cloud_compute::client::google::cloud::compute::v1::StartInstanceRequest;

    tracing::info!(project, zone, instance, "Starting instance");

    let request = StartInstanceRequest {
        project: project.to_string(),
        zone: zone.to_string(),
        instance: instance.to_string(),
        ..Default::default()
    };

    let operation = client.instances().start(request).await?;

    // Wait for operation to complete
    wait_for_zone_operation(client, project, zone, &operation.name.unwrap()).await?;

    tracing::info!(instance, "Instance started successfully");
    Ok(())
}

/// Detener una instancia en ejecución
pub async fn stop_instance(
    client: &ComputeClient,
    project: &str,
    zone: &str,
    instance: &str,
) -> Result<()> {
    use google_cloud_compute::client::google::cloud::compute::v1::StopInstanceRequest;

    tracing::info!(project, zone, instance, "Stopping instance");

    let request = StopInstanceRequest {
        project: project.to_string(),
        zone: zone.to_string(),
        instance: instance.to_string(),
        ..Default::default()
    };

    let operation = client.instances().stop(request).await?;
    wait_for_zone_operation(client, project, zone, &operation.name.unwrap()).await?;

    tracing::info!(instance, "Instance stopped successfully");
    Ok(())
}

/// Reiniciar una instancia (reset)
pub async fn reset_instance(
    client: &ComputeClient,
    project: &str,
    zone: &str,
    instance: &str,
) -> Result<()> {
    use google_cloud_compute::client::google::cloud::compute::v1::ResetInstanceRequest;

    tracing::info!(project, zone, instance, "Resetting instance");

    let request = ResetInstanceRequest {
        project: project.to_string(),
        zone: zone.to_string(),
        instance: instance.to_string(),
        ..Default::default()
    };

    let operation = client.instances().reset(request).await?;
    wait_for_zone_operation(client, project, zone, &operation.name.unwrap()).await?;

    tracing::info!(instance, "Instance reset successfully");
    Ok(())
}

// ==========================================
// PARTE 6: OPERATION POLLING
// ==========================================

/// Esperar a que una operación de zona se complete
///
/// Compute Engine operations son asíncronas. Después de iniciar una operación
/// (start, stop, reset), debemos polling hasta que complete.
///
/// VENTAJAS vs gcloud CLI:
/// - Control fino sobre timeouts
/// - Progress callbacks posibles
/// - Exponential backoff automático
async fn wait_for_zone_operation(
    client: &ComputeClient,
    project: &str,
    zone: &str,
    operation_name: &str,
) -> Result<()> {
    use google_cloud_compute::client::google::cloud::compute::v1::GetZoneOperationRequest;

    let max_wait = Duration::from_secs(300); // 5 minutes
    let start = Instant::now();
    let mut backoff = Duration::from_secs(1);

    loop {
        if start.elapsed() > max_wait {
            return Err(anyhow!("Operation timeout after {:?}", max_wait));
        }

        let request = GetZoneOperationRequest {
            project: project.to_string(),
            zone: zone.to_string(),
            operation: operation_name.to_string(),
            ..Default::default()
        };

        let operation = client.zone_operations().get(request).await?;

        match operation.status.as_deref() {
            Some("DONE") => {
                if let Some(error) = operation.error {
                    return Err(anyhow!("Operation failed: {:?}", error));
                }
                return Ok(());
            }
            Some("RUNNING") | Some("PENDING") => {
                // Continue waiting
                tracing::debug!(
                    operation = operation_name,
                    progress = ?operation.progress,
                    "Operation in progress"
                );
            }
            other => {
                return Err(anyhow!("Unexpected operation status: {:?}", other));
            }
        }

        sleep(backoff).await;

        // Exponential backoff hasta max 30 segundos
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

// ==========================================
// PARTE 7: EJEMPLO DE USO
// ==========================================

#[tokio::main]
async fn main() -> Result<()> {
    // Inicializar logging
    tracing_subscriber::fmt::init();

    // Crear client pool
    let pool = GcpClientPool::new().await?;

    // Listar proyectos
    println!("\n📁 Listando proyectos...");
    let projects = list_projects(pool.resource_manager()).await?;
    for project in &projects {
        println!("  - {} ({})", project.name.as_ref().unwrap_or(&project.project_id), project.project_id);
    }

    // Seleccionar primer proyecto
    let project_id = &projects[0].project_id;
    println!("\n🔧 Usando proyecto: {}", project_id);

    // Listar instancias
    println!("\n💻 Listando instancias...");
    let instances = list_instances(pool.compute(), project_id).await?;
    for instance in &instances {
        println!("  - {} ({}) - Zone: {} - Status: {}",
            instance.name,
            instance.machine_type,
            instance.zone,
            instance.status
        );
    }

    // Lifecycle example (comentado para no modificar instancias reales)
    /*
    if let Some(instance) = instances.first() {
        println!("\n🚀 Testing lifecycle operations on {}...", instance.name);

        // Stop instance
        stop_instance(pool.compute(), project_id, &instance.zone, &instance.name).await?;
        println!("  ✓ Instance stopped");

        // Start instance
        start_instance(pool.compute(), project_id, &instance.zone, &instance.name).await?;
        println!("  ✓ Instance started");
    }
    */

    println!("\n✅ Done!");
    Ok(())
}

// ==========================================
// COMPARACIÓN DE MÉTRICAS
// ==========================================

#[cfg(test)]
mod benchmarks {
    use super::*;
    use std::time::Instant;

    /// Benchmark: Listar proyectos
    /// CLI: ~150-300ms
    /// Client Library: ~10-30ms
    #[tokio::test]
    async fn bench_list_projects() {
        let pool = GcpClientPool::new().await.unwrap();

        let start = Instant::now();
        let projects = list_projects(pool.resource_manager()).await.unwrap();
        let elapsed = start.elapsed();

        println!("✓ Listed {} projects in {:?}", projects.len(), elapsed);
        assert!(elapsed < Duration::from_millis(100), "Should be faster than 100ms");
    }

    /// Benchmark: Listar instancias
    /// CLI: ~200-500ms
    /// Client Library: ~20-50ms
    #[tokio::test]
    async fn bench_list_instances() {
        let pool = GcpClientPool::new().await.unwrap();
        let projects = list_projects(pool.resource_manager()).await.unwrap();

        let start = Instant::now();
        let instances = list_instances(pool.compute(), &projects[0].project_id).await.unwrap();
        let elapsed = start.elapsed();

        println!("✓ Listed {} instances in {:?}", instances.len(), elapsed);
        assert!(elapsed < Duration::from_millis(200), "Should be faster than 200ms");
    }
}
