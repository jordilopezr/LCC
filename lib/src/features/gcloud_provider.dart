import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/db_client.dart';
import '../bridge/api.dart/gcloud.dart';
import '../bridge/api.dart/gcp_rest_client.dart';
import '../bridge/api.dart/rdp_client.dart';
import '../bridge/api.dart/sshfs_mount.dart';
import '../bridge/api.dart/tunnel.dart';
import '../bridge/api.dart/vnc_client.dart';
import '../services/storage_service.dart';
import '../services/notification_service.dart';
import 'settings_provider.dart';
import 'snapshot_provider.dart';

// ==========================================
// MULTI-ACCOUNT MANAGEMENT (Sprint 8 - v2.7.0)
// ==========================================

/// Semantic classification of a sanitized GCP error, so widgets can map
/// it to a localized message via `l10n.*` instead of a hardcoded string.
enum GcpErrorType {
  permissionDenied,
  notFound,
  unauthenticated,
  quotaExceeded,
  network,
  unknown,
}

class AccountState {
  final List<GcloudAccount> accounts;
  final String? activeAccountEmail;
  final bool isLoading;
  final String? error;
  final GcpErrorType? errorType;

  const AccountState({
    this.accounts = const [],
    this.activeAccountEmail,
    this.isLoading = false,
    this.error,
    this.errorType,
  });

  AccountState copyWith({
    List<GcloudAccount>? accounts,
    String? activeAccountEmail,
    bool? isLoading,
    String? error,
    GcpErrorType? errorType,
  }) {
    return AccountState(
      accounts: accounts ?? this.accounts,
      activeAccountEmail: activeAccountEmail ?? this.activeAccountEmail,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      errorType: errorType,
    );
  }

  /// Number of authenticated accounts
  int get accountCount => accounts.length;

  /// Whether multiple accounts are active
  bool get isMultiAccount => accounts.length > 1;
}

/// Classify a raw GCP exception into a semantic [GcpErrorType]. The widget
/// layer maps this to a localized message; this function stays free of
/// user-facing text.
GcpErrorType _classifyGcpError(dynamic e) {
  final msg = e.toString();
  if (msg.contains('PERMISSION_DENIED') || msg.contains('403')) {
    return GcpErrorType.permissionDenied;
  }
  if (msg.contains('NOT_FOUND') || msg.contains('404')) {
    return GcpErrorType.notFound;
  }
  if (msg.contains('UNAUTHENTICATED') || msg.contains('401')) {
    return GcpErrorType.unauthenticated;
  }
  if (msg.contains('quota') || msg.contains('RESOURCE_EXHAUSTED')) {
    return GcpErrorType.quotaExceeded;
  }
  if (msg.contains('network') || msg.contains('timeout') || msg.contains('connect')) {
    return GcpErrorType.network;
  }
  return GcpErrorType.unknown;
}

final accountProvider = NotifierProvider<AccountNotifier, AccountState>(AccountNotifier.new);

class AccountNotifier extends Notifier<AccountState> {
  @override
  AccountState build() {
    // Watch gcloudStatusProvider so we reload when auth status changes (login/logout)
    final statusAsync = ref.watch(gcloudStatusProvider);
    final isAuthenticated = statusAsync.whenOrNull(
      data: (status) => status['authenticated'] == true,
    ) ?? false;

    if (isAuthenticated) {
      _loadAccounts();
    }
    return AccountState(isLoading: isAuthenticated);
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await listGcloudAccounts();
      final active = accounts.where((a) => a.status == 'ACTIVE').firstOrNull;

      state = AccountState(
        accounts: accounts,
        activeAccountEmail: active?.account,
        isLoading: false,
      );

      // Migrate existing projects to account on first load
      if (active != null) {
        await StorageService().migrateProjectsToAccount(active.account);
      }
    } catch (e) {
      state = AccountState(
        isLoading: false,
        error: e.toString(),
        errorType: _classifyGcpError(e),
      );
    }
  }

  /// Refresh the accounts list
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);
    await _loadAccounts();
  }

  /// Switch to a different account - full workspace isolation
  Future<void> switchAccount(String email) async {
    final previousEmail = state.activeAccountEmail;
    state = state.copyWith(isLoading: true, error: null);

    try {
      // 1. Disconnect ALL active tunnels
      final connections = ref.read(activeConnectionsProvider);
      final connectionsNotifier = ref.read(activeConnectionsProvider.notifier);
      for (final entry in connections.entries.toList()) {
        if (entry.value.status == 'connected') {
          final parsed = parseTunnelKey(entry.key);
          if (parsed != null) {
            await connectionsNotifier.disconnect(parsed.$1, parsed.$2);
          }
        }
      }

      // 2. Save current account's project selection
      final multiProjectNotifier = ref.read(multiProjectProvider.notifier);
      if (previousEmail != null) {
        await multiProjectNotifier.saveProjectsForAccount(previousEmail);
      }

      // 3. Clear selected instance
      ref.read(multiProjectSelectedInstanceProvider.notifier).clear();

      // 4. Switch gcloud active account
      await switchGcloudAccount(email: email);

      // 5. Refresh account list to update active status
      await _loadAccounts();

      // 6. Invalidate all data providers - clean slate
      ref.invalidate(gcloudStatusProvider);
      ref.invalidate(projectsProvider);
      ref.invalidate(instancesProvider);
      ref.invalidate(activeConnectionsProvider);

      // 7. Restore project selection for the new account and refresh via CLI
      await multiProjectNotifier.switchToAccount(email);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
        errorType: _classifyGcpError(e),
      );
    }
  }

  /// Add a new account (opens browser)
  Future<void> addAccount() async {
    try {
      await addGcloudAccount();
      await refresh();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Remove an account
  Future<void> removeAccount(String email) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await removeGcloudAccount(email: email);
      await _loadAccounts();

      // If we removed the active account, invalidate everything
      if (email == state.activeAccountEmail || state.accounts.isEmpty) {
        ref.invalidate(projectsProvider);
        ref.invalidate(instancesProvider);
        ref.invalidate(gcloudStatusProvider);
        ref.invalidate(multiProjectProvider);
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}

// ==========================================
// GOOGLE CLOUD CLIENT LIBRARIES PROVIDERS
// ==========================================

// ==========================================
// API METHOD SELECTION (CLI vs Client Libraries)
// ==========================================

enum GcpApiMethod {
  cli,           // Traditional gcloud CLI (spawns processes)
  clientLibrary  // Google Cloud Client Libraries (REST API)
}

/// Provider to toggle between CLI and Client Libraries
final apiMethodProvider = NotifierProvider<ApiMethodNotifier, GcpApiMethod>(ApiMethodNotifier.new);

class ApiMethodNotifier extends Notifier<GcpApiMethod> {
  @override
  GcpApiMethod build() {
    return GcpApiMethod.clientLibrary;
  }

  void setMethod(GcpApiMethod method) {
    state = method;
  }
}

/// Helper function to create composite tunnel key: "instanceName:port"
/// This allows multiple tunnels per instance (e.g., "test-vm:3389", "test-vm:5432")
String makeTunnelKey(String instanceName, int remotePort) {
  return '$instanceName:$remotePort';
}

/// Parse tunnel key back to instance and port
/// Returns (instanceName, remotePort) or null if invalid format
(String, int)? parseTunnelKey(String key) {
  final parts = key.split(':');
  if (parts.length != 2) return null;

  final port = int.tryParse(parts[1]);
  if (port == null) return null;

  return (parts[0], port);
}

// Estado para la instalación/auth
final gcloudStatusProvider = FutureProvider<Map<String, bool>>((ref) async {
  final installed = await checkGcloudInstalled();
  if (!installed) return {'installed': false, 'authenticated': false};
  
  final authenticated = await checkGcloudAuth();
  return {'installed': true, 'authenticated': authenticated};
});

// ==========================================
// SYSTEM DEPENDENCY STATUS
// ==========================================

/// Consolidated status of all system dependencies
class DependencyStatus {
  final bool gcloudInstalled;
  final int rdpClientsCount;
  final int vncClientsCount;
  final int dbClientsCount;
  final bool sshfsAvailable;

  const DependencyStatus({
    required this.gcloudInstalled,
    required this.rdpClientsCount,
    required this.vncClientsCount,
    required this.dbClientsCount,
    required this.sshfsAvailable,
  });
}

/// Provider that checks all system dependencies in parallel
final dependencyStatusProvider = FutureProvider<DependencyStatus>((ref) async {
  final results = await Future.wait([
    checkGcloudInstalled(),
    getAvailableRdpClients(),
    getAvailableVncClients(),
    getAvailableDbClients(),
    getSshfsStatus(),
  ]);

  return DependencyStatus(
    gcloudInstalled: results[0] as bool,
    rdpClientsCount: (results[1] as List<RdpClientType>).length,
    vncClientsCount: (results[2] as List<VncClientType>).length,
    dbClientsCount: (results[3] as List<DbClientType>).length,
    sshfsAvailable: (results[4] as SshfsStatus).installed,
  );
});

// Provider para la lista de proyectos (account-aware, CLI-first after switch)
final projectsProvider = FutureProvider<List<GcpProject>>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), () {
    link.close();
    ref.invalidateSelf();
  });
  ref.onDispose(() => timer.cancel());

  final status = await ref.watch(gcloudStatusProvider.future);
  if (status['authenticated'] != true) return [];

  // Watch accountProvider so we re-fetch projects when account changes
  final accountState = ref.watch(accountProvider);
  final activeEmail = accountState.activeAccountEmail;
  if (activeEmail == null) return [];

  // listProjects() va por el cliente REST de Rust, que obtiene el token via
  // gcloud CLI (sigue a la cuenta activa y gestiona reauth/RAPT) con fallback
  // a ADC. Si falla, propagamos el error: ProjectSelector tiene rama de error
  // (appErrorLoadingProjects) y una lista vacía ocultaría el problema real.
  try {
    return await listProjects();
  } catch (e) {
    debugPrint('Project listing failed for $activeEmail: $e');
    rethrow;
  }
});

// Provider para el proyecto seleccionado
final selectedProjectProvider = NotifierProvider<SelectedProjectNotifier, String?>(SelectedProjectNotifier.new);

class SelectedProjectNotifier extends Notifier<String?> {
  @override
  String? build() {
    // Attempt to load last selected project from storage
    return StorageService().getLastProject();
  }

  void select(String? projectId) {
    state = projectId;
    if (projectId != null) {
      StorageService().saveLastProject(projectId);
    }
  }
}

// Provider para la lista de instancias (account-aware, CLI for active account)
final instancesProvider = FutureProvider<List<GcpInstance>>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), () {
    link.close();
    ref.invalidateSelf();
  });
  ref.onDispose(() => timer.cancel());

  // Watch account so we re-fetch when account changes
  ref.watch(accountProvider);

  final projectId = ref.watch(selectedProjectProvider);
  if (projectId == null) return [];

  try {
    // Use CLI which respects the active gcloud account
    return await listInstances(projectId: projectId);
  } catch (cliError) {
    debugPrint('CLI instances failed for $projectId: $cliError');
    try {
      // Fallback to REST
      final clientLibInstances = await listInstancesClientLib(projectId: projectId);
      return clientLibInstances.map((inst) => GcpInstance(
        name: inst.name,
        status: inst.status,
        zone: inst.zone,
        machineType: inst.machineType,
        cpuCount: inst.cpuCount,
        memoryMb: inst.memoryMb,
        diskGb: inst.diskGb,
        labels: inst.labels,
        osLoginEnabled: inst.osLoginEnabled,
        isWindows: inst.isWindows,
      )).toList();
    } catch (restError) {
      debugPrint('REST fallback also failed for $projectId: $restError');
      rethrow;
    }
  }
});

// UI Selection State
final selectedInstanceProvider = NotifierProvider<SelectedInstanceNotifier, GcpInstance?>(SelectedInstanceNotifier.new);

class SelectedInstanceNotifier extends Notifier<GcpInstance?> {
  @override
  GcpInstance? build() => null;

  void select(GcpInstance? instance) {
    state = instance;
  }
}

// Gestión de Conexiones (Tunneling) - Soporte Múltiple
class TunnelState {
  final String status; // 'disconnected', 'connecting', 'connected', 'error', 'reconnecting'
  final int? port; // Local port where tunnel listens (e.g., 40759)
  final int? remotePort; // Remote port being forwarded (e.g., 3389 for RDP, 22 for SSH)
  final String? error;
  final DateTime? createdAt; // When the tunnel was established
  final DateTime? lastHealthCheck; // Last health verification timestamp

  // Sprint 9: Reconnection & latency fields
  final int reconnectAttempts; // Current number of reconnection attempts
  final int maxReconnectAttempts; // Maximum reconnection attempts (default 5)
  final DateTime? nextReconnectAt; // When to attempt next reconnection
  final bool autoReconnectEnabled; // Whether auto-reconnect is enabled for this tunnel
  final int? latencyMs; // Last measured latency in milliseconds
  final String? projectId; // Needed for reconnection
  final String? zone; // Needed for reconnection

  const TunnelState({
    this.status = 'disconnected',
    this.port,
    this.remotePort,
    this.error,
    this.createdAt,
    this.lastHealthCheck,
    this.reconnectAttempts = 0,
    this.maxReconnectAttempts = 5,
    this.nextReconnectAt,
    this.autoReconnectEnabled = true,
    this.latencyMs,
    this.projectId,
    this.zone,
  });

  /// Calculate the next backoff delay: 2s, 4s, 8s, 16s, 32s (capped)
  Duration get nextBackoffDelay {
    final seconds = min(pow(2, reconnectAttempts + 1).toInt(), 32);
    return Duration(seconds: seconds);
  }

  /// Calculate tunnel uptime in a human-readable format.
  /// The numeric duration (h/m/s) is locale-invariant shorthand, matching
  /// the convention used for latency ("150ms") elsewhere in the dashboard;
  /// only the "not available" fallback is localized.
  String uptime(AppLocalizations l10n) {
    if (createdAt == null) return l10n.diagValueNa;
    final duration = DateTime.now().difference(createdAt!);

    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    } else {
      return '${duration.inSeconds}s';
    }
  }

  /// Get last health check as a localized relative time.
  String lastCheckRelative(AppLocalizations l10n) {
    if (lastHealthCheck == null) return l10n.commonNever;
    final duration = DateTime.now().difference(lastHealthCheck!);

    if (duration.inMinutes < 1) {
      return l10n.appJustNow;
    } else if (duration.inHours < 1) {
      return l10n.appMinutesAgo(duration.inMinutes);
    } else {
      return l10n.appHoursAgo(duration.inHours);
    }
  }
}

// Mapa: InstanceName -> TunnelState
final activeConnectionsProvider = NotifierProvider<ConnectionsNotifier, Map<String, TunnelState>>(ConnectionsNotifier.new);

class ConnectionsNotifier extends Notifier<Map<String, TunnelState>> {
  Timer? _healthCheckTimer;

  @override
  Map<String, TunnelState> build() {
    // Start health check timer: check every 30 seconds
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      _checkAllTunnels,
    );

    // Cancel timer when notifier is disposed
    ref.onDispose(() {
      _healthCheckTimer?.cancel();
    });

    return {};
  }

  int _healthCheckCycleCount = 0;

  /// Periodic health check for all active tunnels with reconnection logic
  Future<void> _checkAllTunnels(Timer timer) async {
    _healthCheckCycleCount++;
    final currentConnections = {...state};
    final now = DateTime.now();

    for (var entry in currentConnections.entries) {
      final tunnelKey = entry.key;
      final tunnelState = entry.value;

      // Handle 'reconnecting' tunnels: check if it's time to retry
      if (tunnelState.status == 'reconnecting' && tunnelState.remotePort != null) {
        if (tunnelState.nextReconnectAt != null && now.isAfter(tunnelState.nextReconnectAt!)) {
          await _attemptReconnection(tunnelKey, tunnelState);
        }
        continue;
      }

      // Only check tunnels marked as 'connected'
      if (tunnelState.status == 'connected' && tunnelState.remotePort != null) {
        // The Rust side keys tunnels by (instanceName, remotePort) and rebuilds
        // the composite key itself, so it must receive the RAW instance name —
        // passing the already-composite `tunnelKey` here makes every health
        // check miss the map, throw, and spuriously reconnect the tunnel.
        final parsedKey = parseTunnelKey(tunnelKey);
        final healthInstance = parsedKey?.$1 ?? tunnelKey;
        try {
          final isHealthy = await checkConnectionHealth(
            instanceName: healthInstance,
            remotePort: tunnelState.remotePort!,
          );

          if (!isHealthy) {
            debugPrint('HEALTH CHECK FAILED: Tunnel for $tunnelKey is unhealthy');

            if (tunnelState.autoReconnectEnabled && tunnelState.projectId != null && tunnelState.zone != null) {
              // Enter reconnecting state
              _enterReconnectingState(tunnelKey, tunnelState);
            } else {
              // No auto-reconnect: mark as error
              final parsed = parseTunnelKey(tunnelKey);
              if (parsed != null) {
                NotificationService().notifyTunnelFailed(
                  instanceName: parsed.$1,
                  remotePort: parsed.$2,
                  project: tunnelState.projectId ?? 'unknown',
                  zone: tunnelState.zone ?? 'unknown',
                );
              }

              state = {
                ...state,
                tunnelKey: TunnelState(
                  status: 'error',
                  port: tunnelState.port,
                  remotePort: tunnelState.remotePort,
                  error: 'Tunnel became unhealthy (process died or port stopped listening)',
                  createdAt: tunnelState.createdAt,
                  lastHealthCheck: now,
                  projectId: tunnelState.projectId,
                  zone: tunnelState.zone,
                  autoReconnectEnabled: tunnelState.autoReconnectEnabled,
                ),
              };
            }
          } else {
            // Tunnel is healthy - measure latency and update state
            int? latency;
            try {
              final latencyBigInt = await measureConnectionLatency(
                instanceName: healthInstance,
                remotePort: tunnelState.remotePort!,
              );
              latency = latencyBigInt.toInt();
            } catch (_) {
              // Latency measurement failed, not critical
            }

            state = {
              ...state,
              tunnelKey: TunnelState(
                status: 'connected',
                port: tunnelState.port,
                remotePort: tunnelState.remotePort,
                createdAt: tunnelState.createdAt,
                lastHealthCheck: now,
                projectId: tunnelState.projectId,
                zone: tunnelState.zone,
                autoReconnectEnabled: tunnelState.autoReconnectEnabled,
                latencyMs: latency,
              ),
            };
          }
        } catch (e) {
          debugPrint('Health check error for $tunnelKey: $e');

          if (tunnelState.autoReconnectEnabled && tunnelState.projectId != null && tunnelState.zone != null) {
            _enterReconnectingState(tunnelKey, tunnelState);
          } else {
            state = {
              ...state,
              tunnelKey: TunnelState(
                status: 'error',
                port: tunnelState.port,
                remotePort: tunnelState.remotePort,
                error: 'Health check failed',
                createdAt: tunnelState.createdAt,
                lastHealthCheck: now,
                projectId: tunnelState.projectId,
                zone: tunnelState.zone,
                autoReconnectEnabled: tunnelState.autoReconnectEnabled,
              ),
            };
          }
        }
      }
    }

    // Every 5 cycles (~2.5 min): cleanup zombie tunnels in Rust
    if (_healthCheckCycleCount % 5 == 0) {
      try {
        final cleaned = await cleanupDeadConnections();
        if (cleaned.isNotEmpty) {
          debugPrint('Cleaned up ${cleaned.length} zombie tunnel(s): $cleaned');
        }
      } catch (e) {
        debugPrint('Zombie cleanup failed: $e');
      }
    }
  }

  /// Enter the reconnecting state for a tunnel
  void _enterReconnectingState(String tunnelKey, TunnelState tunnelState) {
    final now = DateTime.now();
    final backoff = const TunnelState().nextBackoffDelay; // 2s for first attempt

    // Stop the dead tunnel in Rust
    final parsed = parseTunnelKey(tunnelKey);
    if (parsed != null) {
      stopConnection(instanceName: parsed.$1, remotePort: parsed.$2).catchError((_) {});

      NotificationService().notifyTunnelReconnecting(
        instanceName: parsed.$1,
        remotePort: parsed.$2,
        attempt: 1,
        maxAttempts: tunnelState.maxReconnectAttempts,
        project: tunnelState.projectId ?? 'unknown',
      );
    }

    state = {
      ...state,
      tunnelKey: TunnelState(
        status: 'reconnecting',
        port: tunnelState.port,
        remotePort: tunnelState.remotePort,
        error: 'Reconnecting... (attempt 1/${tunnelState.maxReconnectAttempts})',
        createdAt: tunnelState.createdAt,
        lastHealthCheck: now,
        reconnectAttempts: 0,
        maxReconnectAttempts: tunnelState.maxReconnectAttempts,
        nextReconnectAt: now.add(backoff),
        autoReconnectEnabled: tunnelState.autoReconnectEnabled,
        projectId: tunnelState.projectId,
        zone: tunnelState.zone,
      ),
    };
  }

  /// Attempt to reconnect a tunnel
  Future<void> _attemptReconnection(String tunnelKey, TunnelState tunnelState) async {
    final parsed = parseTunnelKey(tunnelKey);
    if (parsed == null || tunnelState.projectId == null || tunnelState.zone == null) return;

    final instanceName = parsed.$1;
    final remotePort = parsed.$2;
    final attempt = tunnelState.reconnectAttempts + 1;
    final now = DateTime.now();

    debugPrint('Reconnection attempt $attempt/${tunnelState.maxReconnectAttempts} for $tunnelKey');

    try {
      final port = await startConnection(
        projectId: tunnelState.projectId!,
        zone: tunnelState.zone!,
        instanceName: instanceName,
        remotePort: remotePort,
      );

      // Reconnection successful!
      debugPrint('Reconnection successful for $tunnelKey on port $port');

      NotificationService().notifyTunnelReconnected(
        instanceName: instanceName,
        remotePort: remotePort,
        project: tunnelState.projectId!,
      );

      state = {
        ...state,
        tunnelKey: TunnelState(
          status: 'connected',
          port: port,
          remotePort: remotePort,
          createdAt: now,
          lastHealthCheck: now,
          reconnectAttempts: 0,
          autoReconnectEnabled: tunnelState.autoReconnectEnabled,
          projectId: tunnelState.projectId,
          zone: tunnelState.zone,
        ),
      };
    } catch (e) {
      debugPrint('Reconnection attempt $attempt failed for $tunnelKey: $e');

      if (attempt >= tunnelState.maxReconnectAttempts) {
        // Give up
        NotificationService().notifyTunnelGaveUp(
          instanceName: instanceName,
          remotePort: remotePort,
          maxAttempts: tunnelState.maxReconnectAttempts,
          project: tunnelState.projectId!,
        );

        state = {
          ...state,
          tunnelKey: TunnelState(
            status: 'error',
            port: tunnelState.port,
            remotePort: remotePort,
            error: 'Reconnection failed after ${tunnelState.maxReconnectAttempts} attempts',
            createdAt: tunnelState.createdAt,
            lastHealthCheck: now,
            reconnectAttempts: attempt,
            maxReconnectAttempts: tunnelState.maxReconnectAttempts,
            autoReconnectEnabled: tunnelState.autoReconnectEnabled,
            projectId: tunnelState.projectId,
            zone: tunnelState.zone,
          ),
        };
      } else {
        // Schedule next attempt with exponential backoff
        final backoffSeconds = min(pow(2, attempt + 1).toInt(), 32);
        final nextAttempt = now.add(Duration(seconds: backoffSeconds));

        NotificationService().notifyTunnelReconnecting(
          instanceName: instanceName,
          remotePort: remotePort,
          attempt: attempt + 1,
          maxAttempts: tunnelState.maxReconnectAttempts,
          project: tunnelState.projectId!,
        );

        state = {
          ...state,
          tunnelKey: TunnelState(
            status: 'reconnecting',
            port: tunnelState.port,
            remotePort: remotePort,
            error: 'Reconnecting... (attempt ${attempt + 1}/${tunnelState.maxReconnectAttempts}) - next in ${backoffSeconds}s',
            createdAt: tunnelState.createdAt,
            lastHealthCheck: now,
            reconnectAttempts: attempt,
            maxReconnectAttempts: tunnelState.maxReconnectAttempts,
            nextReconnectAt: nextAttempt,
            autoReconnectEnabled: tunnelState.autoReconnectEnabled,
            projectId: tunnelState.projectId,
            zone: tunnelState.zone,
          ),
        };
      }
    }
  }

  /// Toggle auto-reconnect for a specific tunnel
  void setAutoReconnect(String tunnelKey, bool enabled) {
    final tunnel = state[tunnelKey];
    if (tunnel == null) return;

    state = {
      ...state,
      tunnelKey: TunnelState(
        status: tunnel.status,
        port: tunnel.port,
        remotePort: tunnel.remotePort,
        error: tunnel.error,
        createdAt: tunnel.createdAt,
        lastHealthCheck: tunnel.lastHealthCheck,
        reconnectAttempts: tunnel.reconnectAttempts,
        maxReconnectAttempts: tunnel.maxReconnectAttempts,
        nextReconnectAt: tunnel.nextReconnectAt,
        autoReconnectEnabled: enabled,
        latencyMs: tunnel.latencyMs,
        projectId: tunnel.projectId,
        zone: tunnel.zone,
      ),
    };
  }

  /// Retry a failed tunnel (manual reconnection)
  Future<void> retryConnection(String tunnelKey) async {
    final tunnel = state[tunnelKey];
    if (tunnel == null || tunnel.projectId == null || tunnel.zone == null || tunnel.remotePort == null) return;

    final parsed = parseTunnelKey(tunnelKey);
    if (parsed == null) return;

    // Reset to reconnecting with fresh attempt count
    state = {
      ...state,
      tunnelKey: TunnelState(
        status: 'reconnecting',
        port: tunnel.port,
        remotePort: tunnel.remotePort,
        error: 'Retrying connection...',
        createdAt: tunnel.createdAt,
        lastHealthCheck: DateTime.now(),
        reconnectAttempts: 0,
        maxReconnectAttempts: tunnel.maxReconnectAttempts,
        nextReconnectAt: DateTime.now(), // Retry immediately
        autoReconnectEnabled: tunnel.autoReconnectEnabled,
        projectId: tunnel.projectId,
        zone: tunnel.zone,
      ),
    };

    // Attempt immediately
    await _attemptReconnection(tunnelKey, state[tunnelKey]!);
  }

  /// Disconnect ALL tunnels
  Future<void> disconnectAll() async {
    final tunnelsToDisconnect = state.entries.toList();
    for (final entry in tunnelsToDisconnect) {
      final parsed = parseTunnelKey(entry.key);
      if (parsed != null) {
        await disconnect(parsed.$1, parsed.$2);
      }
    }
  }

  Future<int?> connect(
    String projectId,
    String zone,
    String instanceName, {
    int remotePort = 3389, // Default to RDP port, configurable via Custom Tunnel dialog
  }) async {
    // No tier limits apply

    // Use composite key to support multiple tunnels per instance
    final tunnelKey = makeTunnelKey(instanceName, remotePort);

    // Actualizar estado de ESTE túnel específico a 'connecting'
    state = {
      ...state,
      tunnelKey: const TunnelState(status: 'connecting')
    };

    try {
      final port = await startConnection(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        remotePort: remotePort,
      );

      // Actualizar a 'connected'
      final now = DateTime.now();
      state = {
        ...state,
        tunnelKey: TunnelState(
          status: 'connected',
          port: port,
          remotePort: remotePort,
          createdAt: now,
          lastHealthCheck: now,
          projectId: projectId,
          zone: zone,
        )
      };
      return port;
    } catch (e) {
      // Error solo en este túnel específico
      state = {
        ...state,
        tunnelKey: TunnelState(
          status: 'error',
          remotePort: remotePort,
          error: e.toString(),
          projectId: projectId,
          zone: zone,
        )
      };
      // No hacemos rethrow para no romper la UI general, el estado refleja el error
      return null;
    }
  }

  Future<void> disconnect(String instanceName, int remotePort) async {
    final tunnelKey = makeTunnelKey(instanceName, remotePort);

    try {
      await stopConnection(
        instanceName: instanceName,
        remotePort: remotePort,
      );
    } catch (e) {
      debugPrint("Error stopping tunnel $tunnelKey: $e");
    }

    // Remove from map - keeps the map clean
    final newState = Map<String, TunnelState>.from(state);
    newState.remove(tunnelKey);
    state = newState;
  }

  /// Disconnect ALL tunnels for a given instance (all ports)
  Future<void> disconnectAllForInstance(String instanceName) async {
    final tunnelsToRemove = state.entries
        .where((entry) => entry.key.startsWith('$instanceName:'))
        .toList();

    for (final entry in tunnelsToRemove) {
      final parsed = parseTunnelKey(entry.key);
      if (parsed != null) {
        await disconnect(parsed.$1, parsed.$2);
      }
    }
  }

  Future<void> launchRDP(String projectId, String zone, String instanceName, {RdpSettings? settings}) async {
    const rdpPort = 3389;
    final tunnelKey = makeTunnelKey(instanceName, rdpPort);
    final currentTunnel = state[tunnelKey];
    bool alreadyConnected = currentTunnel?.status == 'connected' && currentTunnel?.port != null;

    try {
      if (!alreadyConnected) {
        // Auto-connect RDP tunnel (port 3389)
        await connect(projectId, zone, instanceName, remotePort: rdpPort);
        // Check if connection succeeded
        final newTunnel = state[tunnelKey];
        if (newTunnel?.status != 'connected') {
           return; // Failed to connect, stop here.
        }
      }

      // Launch RDP
      final activeTunnel = state[tunnelKey];
      if (activeTunnel?.port != null) {
        try {
          // Get user's preferred RDP client
          final preferredClient = ref.read(rdpClientProvider);

          // Create settings with client type
          final rdpSettings = RdpSettings(
            username: settings?.username,
            password: settings?.password,
            domain: settings?.domain,
            width: settings?.width,
            height: settings?.height,
            fullscreen: settings?.fullscreen ?? false,
            ignoreCertificate: settings?.ignoreCertificate ?? false,
            clientType: preferredClient, // Pass selected client
          );

          // Launch RDP - Rust will handle client selection and fallback
          final result = await launchRdp(
            port: activeTunnel!.port!,
            instanceName: instanceName,
            settings: rdpSettings,
          );

          // Show notification if fallback occurred
          if (result.fallbackOccurred) {
            final clientName = ref.read(rdpClientProvider.notifier).displayName(result.clientUsed);
            NotificationService().notifyGeneral(
              title: 'RDP Client Fallback',
              body: 'Your preferred client was unavailable. Using $clientName instead.',
            );
          }
        } catch (e) {
           // Connection is still good, just launch failed
           state = {
             ...state,
             tunnelKey: TunnelState(
               status: 'connected',
               port: activeTunnel?.port,
               remotePort: rdpPort,
               error: "Launch Failed: $e", // Show transient error
               createdAt: activeTunnel?.createdAt, // Preserve creation time
               lastHealthCheck: activeTunnel?.lastHealthCheck, // Preserve last check
             )
           };
        }
      }
    } catch (e) {
       state = {
         ...state,
         tunnelKey: TunnelState(status: 'error', remotePort: rdpPort, error: "Auto-connect failed: $e")
       };
    }
  }

  Future<void> launchVNC(String projectId, String zone, String instanceName, {VncSettings? settings}) async {
    const vncPort = 5900;
    final tunnelKey = makeTunnelKey(instanceName, vncPort);
    final currentTunnel = state[tunnelKey];
    bool alreadyConnected = currentTunnel?.status == 'connected' && currentTunnel?.port != null;

    try {
      if (!alreadyConnected) {
        // Auto-connect VNC tunnel (port 5900)
        await connect(projectId, zone, instanceName, remotePort: vncPort);
        // Check if connection succeeded
        final newTunnel = state[tunnelKey];
        if (newTunnel?.status != 'connected') {
           return; // Failed to connect, stop here.
        }
      }

      // Launch VNC
      final activeTunnel = state[tunnelKey];
      if (activeTunnel?.port != null) {
        try {
          // Get user's preferred VNC client
          final preferredClient = ref.read(vncClientProvider);

          // Create settings with client type
          final vncSettings = VncSettings(
            password: settings?.password,
            width: settings?.width,
            height: settings?.height,
            fullscreen: settings?.fullscreen ?? false,
            viewOnly: settings?.viewOnly ?? false,
            quality: settings?.quality ?? VncQuality.auto,
            clientType: preferredClient, // Pass selected client
          );

          // Launch VNC - Rust will handle client selection and fallback
          final result = await launchVnc(
            port: activeTunnel!.port!,
            instanceName: instanceName,
            settings: vncSettings,
          );

          // Show notification if fallback occurred
          if (result.fallbackOccurred) {
            final clientName = ref.read(vncClientProvider.notifier).displayName(result.clientUsed);
            NotificationService().notifyGeneral(
              title: 'VNC Client Fallback',
              body: 'Your preferred client was unavailable. Using $clientName instead.',
            );
          }
        } catch (e) {
           // Connection is still good, just launch failed
           state = {
             ...state,
             tunnelKey: TunnelState(
               status: 'connected',
               port: activeTunnel?.port,
               remotePort: vncPort,
               error: "Launch Failed: $e", // Show transient error
               createdAt: activeTunnel?.createdAt, // Preserve creation time
               lastHealthCheck: activeTunnel?.lastHealthCheck, // Preserve last check
             )
           };
        }
      }
    } catch (e) {
       state = {
         ...state,
         tunnelKey: TunnelState(status: 'error', remotePort: vncPort, error: "Auto-connect failed: $e")
       };
    }
  }

  /// Refresh instances list after lifecycle operations
  Future<void> refreshInstances(String projectId) async {
    // Invalidate the instances provider to force a refresh
    ref.invalidate(instancesProvider);
  }

  /// Start instance (REST-first, CLI fallback)
  Future<void> startInstanceWithMethod(String projectId, String zone, String instanceName) async {
    try {
      try {
        await startInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
      } catch (e) {
        debugPrint('REST start failed, falling back to CLI: $e');
        await startInstance(projectId: projectId, zone: zone, instanceName: instanceName);
      }
      await refreshInstances(projectId);

      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Start',
        success: true,
        project: projectId,
        zone: zone,
      );
    } catch (e) {
      debugPrint('Error starting instance: $e');
      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Start',
        success: false,
        project: projectId,
        zone: zone,
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }

  /// Stop instance (REST-first, CLI fallback)
  Future<void> stopInstanceWithMethod(String projectId, String zone, String instanceName) async {
    try {
      try {
        await stopInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
      } catch (e) {
        debugPrint('REST stop failed, falling back to CLI: $e');
        await stopInstance(projectId: projectId, zone: zone, instanceName: instanceName);
      }
      await refreshInstances(projectId);

      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Stop',
        success: true,
        project: projectId,
        zone: zone,
      );
    } catch (e) {
      debugPrint('Error stopping instance: $e');
      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Stop',
        success: false,
        project: projectId,
        zone: zone,
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }

  /// Suspend instance (REST-first, CLI fallback)
  Future<void> suspendInstanceWithMethod(String projectId, String zone, String instanceName) async {
    try {
      // Disconnect all tunnels first
      await disconnectAllForInstance(instanceName);

      try {
        await suspendInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
      } catch (e) {
        debugPrint('REST suspend failed, falling back to CLI: $e');
        await suspendInstance(projectId: projectId, zone: zone, instanceName: instanceName);
      }
      await refreshInstances(projectId);

      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Suspend',
        success: true,
        project: projectId,
        zone: zone,
      );
    } catch (e) {
      debugPrint('Error suspending instance: $e');
      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Suspend',
        success: false,
        project: projectId,
        zone: zone,
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }

  /// Resume instance (REST-first, CLI fallback)
  Future<void> resumeInstanceWithMethod(String projectId, String zone, String instanceName) async {
    try {
      try {
        await resumeInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
      } catch (e) {
        debugPrint('REST resume failed, falling back to CLI: $e');
        await resumeInstance(projectId: projectId, zone: zone, instanceName: instanceName);
      }
      await refreshInstances(projectId);

      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Resume',
        success: true,
        project: projectId,
        zone: zone,
      );
    } catch (e) {
      debugPrint('Error resuming instance: $e');
      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Resume',
        success: false,
        project: projectId,
        zone: zone,
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }

  /// Reset instance (REST-first, CLI fallback)
  Future<void> resetInstanceWithMethod(String projectId, String zone, String instanceName) async {
    try {
      try {
        await resetInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
      } catch (e) {
        debugPrint('REST reset failed, falling back to CLI: $e');
        await resetInstance(projectId: projectId, zone: zone, instanceName: instanceName);
      }
      await refreshInstances(projectId);

      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Reset',
        success: true,
        project: projectId,
        zone: zone,
      );
    } catch (e) {
      debugPrint('Error resetting instance: $e');
      NotificationService().notifyLifecycleOperation(
        instanceName: instanceName,
        operation: 'Reset',
        success: false,
        project: projectId,
        zone: zone,
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }
}

// ==========================================
// TUNNEL STATS PROVIDER (Sprint 9 - v2.8.0)
// ==========================================

/// Aggregated tunnel statistics for the global panel
class TunnelStats {
  final int totalTunnels;
  final int healthyCount;
  final int errorCount;
  final int reconnectingCount;
  final List<MapEntry<String, TunnelState>> allTunnels;

  const TunnelStats({
    this.totalTunnels = 0,
    this.healthyCount = 0,
    this.errorCount = 0,
    this.reconnectingCount = 0,
    this.allTunnels = const [],
  });

  bool get hasErrors => errorCount > 0;
  bool get hasReconnecting => reconnectingCount > 0;
}

/// Provider that derives global tunnel statistics from activeConnectionsProvider
final tunnelStatsProvider = Provider<TunnelStats>((ref) {
  final connections = ref.watch(activeConnectionsProvider);
  if (connections.isEmpty) return const TunnelStats();

  int healthy = 0;
  int error = 0;
  int reconnecting = 0;

  final sorted = connections.entries.toList()
    ..sort((a, b) {
      final aTime = a.value.createdAt ?? DateTime(2000);
      final bTime = b.value.createdAt ?? DateTime(2000);
      return aTime.compareTo(bTime);
    });

  for (final entry in sorted) {
    switch (entry.value.status) {
      case 'connected':
        healthy++;
      case 'error':
        error++;
      case 'reconnecting':
        reconnecting++;
    }
  }

  return TunnelStats(
    totalTunnels: connections.length,
    healthyCount: healthy,
    errorCount: error,
    reconnectingCount: reconnecting,
    allTunnels: sorted,
  );
});

// ==========================================
// AUTO-REFRESH - SMART INSTANCE MONITORING
// ==========================================

/// Auto-refresh state
class AutoRefreshState {
  final bool enabled;
  final Duration interval;
  final Map<String, String> lastKnownStates; // instanceName -> status

  const AutoRefreshState({
    this.enabled = false,
    this.interval = const Duration(seconds: 30),
    this.lastKnownStates = const {},
  });

  AutoRefreshState copyWith({
    bool? enabled,
    Duration? interval,
    Map<String, String>? lastKnownStates,
  }) {
    return AutoRefreshState(
      enabled: enabled ?? this.enabled,
      interval: interval ?? this.interval,
      lastKnownStates: lastKnownStates ?? this.lastKnownStates,
    );
  }
}

/// Provider for auto-refresh functionality
final autoRefreshProvider = NotifierProvider<AutoRefreshNotifier, AutoRefreshState>(AutoRefreshNotifier.new);

class AutoRefreshNotifier extends Notifier<AutoRefreshState> {
  Timer? _refreshTimer;

  @override
  AutoRefreshState build() {
    // Cancel timer when notifier is disposed
    ref.onDispose(() {
      _refreshTimer?.cancel();
    });

    return const AutoRefreshState();
  }

  void toggle() {
    if (state.enabled) {
      disable();
    } else {
      enable();
    }
  }

  void enable() {
    state = state.copyWith(enabled: true);
    _startRefreshTimer();
    debugPrint('🔄 Auto-refresh enabled (${state.interval.inSeconds}s interval)');
  }

  void disable() {
    state = state.copyWith(enabled: false);
    _stopRefreshTimer();
    debugPrint('⏸️  Auto-refresh disabled');
  }

  void setInterval(Duration interval) {
    state = state.copyWith(interval: interval);
    if (state.enabled) {
      // Restart timer with new interval
      _stopRefreshTimer();
      _startRefreshTimer();
    }
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(state.interval, (_) {
      _refreshInstances();
    });
  }

  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> _refreshInstances() async {
    final selectedProject = ref.read(selectedProjectProvider);
    if (selectedProject == null) return;

    debugPrint('🔄 Auto-refresh: Refreshing instances for project $selectedProject');

    // Capture current states before refresh
    final previousStates = Map<String, String>.from(state.lastKnownStates);

    // Invalidate to trigger refresh
    ref.invalidate(instancesProvider);

    // Wait a bit for the provider to update
    await Future.delayed(const Duration(milliseconds: 500));

    // Get new states
    final instances = await ref.read(instancesProvider.future).catchError((e) {
      final errorMessage = e.toString();
      // If it's a permission error, disable auto-refresh to prevent spam
      if (errorMessage.contains('PERMISSION_DENIED') || errorMessage.contains('403')) {
        debugPrint('⚠️ Permission denied during auto-refresh. Disabling auto-refresh to prevent API spam.');
        // Disable auto-refresh on permission errors
        disable();
      } else {
        debugPrint('Error refreshing instances: $e');
      }
      return <GcpInstance>[];
    });

    // Build new states map
    final newStates = <String, String>{};
    for (final instance in instances) {
      newStates[instance.name] = instance.status;
    }

    // Detect changes and send notifications
    for (final instance in instances) {
      final previousStatus = previousStates[instance.name];
      final currentStatus = instance.status;

      if (previousStatus != null && previousStatus != currentStatus) {
        debugPrint('🔔 State change detected: ${instance.name} $previousStatus → $currentStatus');

        // Send notification
        NotificationService().notifyVmStateChange(
          instanceName: instance.name,
          oldState: previousStatus,
          newState: currentStatus,
          project: selectedProject,
          zone: instance.zone,
        );
      }
    }

    // Update last known states
    state = state.copyWith(lastKnownStates: newStates);
  }

  /// Get state changes since last refresh
  Map<String, StateChange> getStateChanges(List<GcpInstance> currentInstances) {
    final changes = <String, StateChange>{};

    for (final instance in currentInstances) {
      final previousStatus = state.lastKnownStates[instance.name];
      if (previousStatus != null && previousStatus != instance.status) {
        changes[instance.name] = StateChange(
          instanceName: instance.name,
          from: previousStatus,
          to: instance.status,
        );
      }
    }

    return changes;
  }
}

/// Represents a state change for an instance
class StateChange {
  final String instanceName;
  final String from;
  final String to;

  const StateChange({
    required this.instanceName,
    required this.from,
    required this.to,
  });

  @override
  String toString() => '$instanceName: $from → $to';
}

// ==========================================
// GOOGLE CLOUD CLIENT LIBRARIES - NEW APPROACH
// ==========================================

/// Provider for testing Client Libraries authentication
/// This uses Application Default Credentials (ADC) from gcloud
final clientLibAuthTestProvider = FutureProvider<String>((ref) async {
  return await testGcpAuthentication();
});

/// Provider for listing projects using Client Libraries (REST API)
/// This is significantly faster than gcloud CLI (5-20ms vs 60-250ms)
final projectsClientLibProvider = FutureProvider<List<GcpProjectClientLib>>((ref) async {
  final status = await ref.watch(gcloudStatusProvider.future);
  if (status['authenticated'] != true) return [];

  return await listProjectsClientLib();
});

/// Sentinel returned by [benchmarkProvider] when the user isn't authenticated.
/// Widgets compare against this and substitute a localized message; it never
/// collides with the Rust-formatted benchmark output.
const String kBenchmarkUnauthenticatedSentinel = '__benchmark_unauthenticated__';

/// Provider for benchmark comparison: Client Libraries vs gcloud CLI
/// Returns formatted string with performance comparison
final benchmarkProvider = FutureProvider<String>((ref) async {
  final status = await ref.watch(gcloudStatusProvider.future);
  if (status['authenticated'] != true) {
    return kBenchmarkUnauthenticatedSentinel;
  }

  return await benchmarkProjectsListing();
});

// ==========================================
// COMPUTE ENGINE CLIENT LIBRARIES PROVIDERS
// ==========================================

/// Provider for listing instances using Client Libraries (REST API)
/// This is significantly faster than gcloud CLI for listing instances
final instancesClientLibProvider = FutureProvider.family<List<GcpInstanceClientLib>, String>((ref, projectId) async {
  if (projectId.isEmpty) return [];

  return await listInstancesClientLib(projectId: projectId);
});

// ==========================================
// MULTI-PROJECT SUPPORT (v2.0.0)
// ==========================================

/// Represents an instance with its associated project ID
/// This allows tracking which project each instance belongs to
class ProjectAwareInstance {
  final String projectId;
  final GcpInstance instance;

  const ProjectAwareInstance({
    required this.projectId,
    required this.instance,
  });

  /// Unique key to identify this instance across all projects
  String get uniqueKey => '$projectId:${instance.zone}:${instance.name}';

  /// Shorthand accessors for common properties
  String get name => instance.name;
  String get status => instance.status;
  String get zone => instance.zone;
  String get machineType => instance.machineType;
  int? get cpuCount => instance.cpuCount;
  int? get memoryMb => instance.memoryMb;
  int? get diskGb => instance.diskGb;
  List<(String, String)> get labels => instance.labels;
  bool get osLoginEnabled => instance.osLoginEnabled;
  bool get isWindows => instance.isWindows;

  /// Check if instance has a label with given key (and optionally value)
  bool hasLabel(String key, [String? value]) {
    for (final label in labels) {
      if (label.$1 == key) {
        if (value == null) return true;
        return label.$2 == value;
      }
    }
    return false;
  }

  /// Get the value of a label by key
  String? labelValue(String key) {
    for (final label in labels) {
      if (label.$1 == key) return label.$2;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectAwareInstance &&
          runtimeType == other.runtimeType &&
          uniqueKey == other.uniqueKey;

  @override
  int get hashCode => uniqueKey.hashCode;
}

/// State of instance loading for a single project
class ProjectLoadState {
  final String projectId;
  final bool isLoading;
  final String? error;
  final DateTime? lastUpdated;
  final List<GcpInstance> instances;

  const ProjectLoadState({
    required this.projectId,
    this.isLoading = false,
    this.error,
    this.lastUpdated,
    this.instances = const [],
  });

  ProjectLoadState copyWith({
    bool? isLoading,
    String? error,
    DateTime? lastUpdated,
    List<GcpInstance>? instances,
  }) {
    return ProjectLoadState(
      projectId: projectId,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      instances: instances ?? this.instances,
    );
  }

  /// Count of instances in this project
  int get instanceCount => instances.length;

  /// Check if this project has a permission error
  bool get hasPermissionError =>
      error != null &&
      (error!.contains('PERMISSION_DENIED') || error!.contains('403'));
}

/// Aggregated state for all selected projects
class MultiProjectState {
  final Set<String> selectedProjectIds;
  final Map<String, ProjectLoadState> projectStates;
  final bool isRefreshing;

  const MultiProjectState({
    this.selectedProjectIds = const {},
    this.projectStates = const {},
    this.isRefreshing = false,
  });

  /// All instances from all selected projects (combined)
  List<ProjectAwareInstance> get allInstances {
    final List<ProjectAwareInstance> combined = [];
    for (final projectId in selectedProjectIds) {
      final state = projectStates[projectId];
      if (state != null && state.error == null) {
        for (final instance in state.instances) {
          combined.add(ProjectAwareInstance(
            projectId: projectId,
            instance: instance,
          ));
        }
      }
    }
    return combined;
  }

  /// Projects with errors
  List<String> get projectsWithError {
    return projectStates.entries
        .where((e) => e.value.error != null)
        .map((e) => e.key)
        .toList();
  }

  /// Projects that are currently loading
  List<String> get loadingProjects {
    return projectStates.entries
        .where((e) => e.value.isLoading)
        .map((e) => e.key)
        .toList();
  }

  /// Total instance count across all projects
  int get totalInstances => allInstances.length;

  /// Check if any project is loading
  bool get hasLoadingProjects => loadingProjects.isNotEmpty;

  MultiProjectState copyWith({
    Set<String>? selectedProjectIds,
    Map<String, ProjectLoadState>? projectStates,
    bool? isRefreshing,
  }) {
    return MultiProjectState(
      selectedProjectIds: selectedProjectIds ?? this.selectedProjectIds,
      projectStates: projectStates ?? this.projectStates,
      isRefreshing: isRefreshing ?? this.isRefreshing,
    );
  }
}

/// Main provider for multi-project support
final multiProjectProvider =
    NotifierProvider<MultiProjectNotifier, MultiProjectState>(
        MultiProjectNotifier.new);

class MultiProjectNotifier extends Notifier<MultiProjectState> {
  @override
  MultiProjectState build() {
    // Load selected projects from storage on init
    _loadSelectedProjects();
    return const MultiProjectState();
  }

  /// Load selected projects from persistent storage
  Future<void> _loadSelectedProjects() async {
    // First, try to migrate from legacy single-project storage
    await StorageService().migrateToMultiProject();

    final savedProjects = StorageService().getSelectedProjects();
    if (savedProjects.isNotEmpty) {
      state = state.copyWith(
        selectedProjectIds: savedProjects.toSet(),
      );

      // Check if user is authenticated before trying to load instances
      try {
        final isAuthenticated = await checkGcloudAuth();
        if (isAuthenticated) {
          // Load instances for all saved projects only if authenticated
          await refreshAllProjects();
        } else {
          debugPrint('User not authenticated - skipping instance refresh. Projects loaded: ${savedProjects.length}');
        }
      } catch (e) {
        debugPrint('Error checking authentication during project load: $e');
        // Don't throw - just skip the refresh
      }
    }
  }

  /// Add a project to selection
  Future<void> addProject(String projectId) async {
    // Validate project ID
    if (!StorageService.isValidProjectId(projectId)) {
      debugPrint('Invalid project ID: $projectId');
      return;
    }

    // Check if already selected
    if (state.selectedProjectIds.contains(projectId)) return;

    // Check limit
    final maxProjects = StorageService.maxSelectedProjects;
    if (state.selectedProjectIds.length >= maxProjects) {
      debugPrint('Project limit reached ($maxProjects max)');
      return;
    }

    final newSelected = {...state.selectedProjectIds, projectId};
    state = state.copyWith(selectedProjectIds: newSelected);

    // Persist and load instances
    await StorageService().saveSelectedProjects(newSelected.toList());
    await _syncProjectsToActiveAccount(newSelected);
    await _loadInstancesForProject(projectId);
  }

  /// Remove a project from selection
  Future<void> removeProject(String projectId) async {
    final newSelected = {...state.selectedProjectIds}..remove(projectId);
    final newStates = {...state.projectStates}..remove(projectId);

    state = state.copyWith(
      selectedProjectIds: newSelected,
      projectStates: newStates,
    );

    await StorageService().saveSelectedProjects(newSelected.toList());
    await _syncProjectsToActiveAccount(newSelected);
  }

  /// Keep account→projects map in sync with current selection
  Future<void> _syncProjectsToActiveAccount(Set<String> projects) async {
    try {
      final accountState = ref.read(accountProvider);
      final activeEmail = accountState.activeAccountEmail;
      if (activeEmail == null) return;

      final accountProjects = StorageService().getAccountProjects();
      accountProjects[activeEmail] = projects.toList();
      await StorageService().saveAccountProjects(accountProjects);
    } catch (_) {
      // Non-critical - don't block the operation
    }
  }

  /// Toggle project selection
  Future<void> toggleProject(String projectId) async {
    if (state.selectedProjectIds.contains(projectId)) {
      await removeProject(projectId);
    } else {
      await addProject(projectId);
    }
  }

  /// Load instances for a specific project (CLI-based, respects active account)
  Future<void> _loadInstancesForProject(String projectId) async {
    // Mark as loading
    final currentStates = {...state.projectStates};
    currentStates[projectId] = ProjectLoadState(
      projectId: projectId,
      isLoading: true,
    );
    state = state.copyWith(projectStates: currentStates);

    try {
      List<GcpInstance> instances;

      // Always use CLI - it respects the active gcloud account
      // REST API uses cached ADC credentials that don't update with account switch
      instances = await listInstances(projectId: projectId);

      // Update state with success
      final updatedStates = {...state.projectStates};
      updatedStates[projectId] = ProjectLoadState(
        projectId: projectId,
        isLoading: false,
        instances: instances,
        lastUpdated: DateTime.now(),
      );
      state = state.copyWith(projectStates: updatedStates);

      debugPrint(
          'Loaded ${instances.length} instances for project $projectId');
    } catch (e) {
      final errorMessage = e.toString();
      debugPrint('Error loading instances for $projectId: $errorMessage');

      // Mark error but do NOT affect other projects
      final updatedStates = {...state.projectStates};
      updatedStates[projectId] = ProjectLoadState(
        projectId: projectId,
        isLoading: false,
        error: errorMessage,
        lastUpdated: DateTime.now(),
      );
      state = state.copyWith(projectStates: updatedStates);
    }
  }

  /// Refresh all selected projects in parallel
  Future<void> refreshAllProjects() async {
    if (state.selectedProjectIds.isEmpty) return;

    state = state.copyWith(isRefreshing: true);

    debugPrint(
        '🔄 Refreshing ${state.selectedProjectIds.length} projects in parallel...');

    // Execute queries in parallel using Future.wait
    await Future.wait(
      state.selectedProjectIds
          .map((projectId) => _loadInstancesForProject(projectId)),
    );

    state = state.copyWith(isRefreshing: false);
    debugPrint('✓ All projects refreshed');
  }

  /// Save current project selection for a specific account
  Future<void> saveProjectsForAccount(String accountEmail) async {
    final currentProjects = state.selectedProjectIds.toList();
    if (currentProjects.isEmpty) return;

    final accountProjects = StorageService().getAccountProjects();
    accountProjects[accountEmail] = currentProjects;
    await StorageService().saveAccountProjects(accountProjects);
    debugPrint('💾 Saved ${currentProjects.length} projects for $accountEmail');
  }

  /// Switch to a different account: clear workspace, restore saved projects, reload via CLI
  Future<void> switchToAccount(String accountEmail) async {
    debugPrint('🔄 Switching workspace to account: $accountEmail');

    // Load saved projects for this account
    final accountProjects = StorageService().getAccountProjects();
    final savedProjects = accountProjects[accountEmail] ?? [];

    // Clear everything - clean slate for new account
    state = MultiProjectState(
      selectedProjectIds: savedProjects.toSet(),
      projectStates: {},
      isRefreshing: true,
    );

    // Persist the new selection as the active one
    await StorageService().saveSelectedProjects(savedProjects);

    if (savedProjects.isNotEmpty) {
      // Load instances for the new account's projects
      await Future.wait(
        savedProjects.map((projectId) => _loadInstancesForProject(projectId)),
      );
    }

    state = state.copyWith(isRefreshing: false);
    debugPrint('✓ Workspace switched to $accountEmail (${savedProjects.length} projects)');
  }

  /// Refresh a specific project
  Future<void> refreshProject(String projectId) async {
    if (!state.selectedProjectIds.contains(projectId)) return;
    await _loadInstancesForProject(projectId);
  }

  /// Clear all selected projects
  Future<void> clearAll() async {
    state = const MultiProjectState();
    await StorageService().clearSelectedProjects();
  }

  /// Get instances for a specific project
  List<GcpInstance> getInstancesForProject(String projectId) {
    return state.projectStates[projectId]?.instances ?? [];
  }

  /// Check if a project has an error
  bool projectHasError(String projectId) {
    return state.projectStates[projectId]?.error != null;
  }

  /// Get error message for a project
  String? getProjectError(String projectId) {
    return state.projectStates[projectId]?.error;
  }
}

// ==========================================
// MULTI-PROJECT INSTANCE SELECTION
// ==========================================

/// Updated provider for selected instance that includes project context
final multiProjectSelectedInstanceProvider =
    NotifierProvider<MultiProjectSelectedInstanceNotifier, ProjectAwareInstance?>(
        MultiProjectSelectedInstanceNotifier.new);

class MultiProjectSelectedInstanceNotifier
    extends Notifier<ProjectAwareInstance?> {
  @override
  ProjectAwareInstance? build() => null;

  void select(ProjectAwareInstance? instance) {
    state = instance;
  }

  void clear() {
    state = null;
  }
}

// ==========================================
// MANUAL INSTANCES PROVIDER
// ==========================================

/// Stores manually added instances (when user has get but not list permission)
class ManualInstance {
  final String projectId;
  final GcpInstanceClientLib instance;

  ManualInstance({required this.projectId, required this.instance});

  Map<String, dynamic> toJson() => {
    'projectId': projectId,
    'name': instance.name,
    'status': instance.status,
    'zone': instance.zone,
    'machineType': instance.machineType,
    'cpuCount': instance.cpuCount,
    'memoryMb': instance.memoryMb,
    'diskGb': instance.diskGb,
  };

  factory ManualInstance.fromJson(Map<String, dynamic> json) {
    return ManualInstance(
      projectId: json['projectId'] as String,
      instance: GcpInstanceClientLib(
        name: json['name'] as String,
        status: json['status'] as String,
        zone: json['zone'] as String,
        machineType: json['machineType'] as String,
        cpuCount: json['cpuCount'] as int?,
        memoryMb: json['memoryMb'] as int?,
        diskGb: json['diskGb'] as int?,
        labels: const [],
        osLoginEnabled: false,
        isWindows: false,
      ),
    );
  }
}

final manualInstancesProvider =
    NotifierProvider<ManualInstancesNotifier, List<ManualInstance>>(
        ManualInstancesNotifier.new);

class ManualInstancesNotifier extends Notifier<List<ManualInstance>> {
  static const _storageKey = 'manual_instances';

  @override
  List<ManualInstance> build() {
    // Load from storage on init
    _loadFromStorage();
    return [];
  }

  Future<void> _loadFromStorage() async {
    try {
      final stored = await StorageService().getManualInstances();
      if (stored.isNotEmpty) {
        state = stored.map((json) => ManualInstance.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('Error loading manual instances: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      await StorageService().saveManualInstances(
        state.map((m) => m.toJson()).toList(),
      );
    } catch (e) {
      debugPrint('Error saving manual instances: $e');
    }
  }

  void addInstance(String projectId, GcpInstanceClientLib instance) {
    // Check if already exists
    final exists = state.any((m) =>
        m.projectId == projectId &&
        m.instance.name == instance.name &&
        m.instance.zone == instance.zone);

    if (!exists) {
      state = [...state, ManualInstance(projectId: projectId, instance: instance)];
      _saveToStorage();
    }
  }

  void removeInstance(String projectId, String instanceName, String zone) {
    state = state.where((m) =>
        !(m.projectId == projectId &&
          m.instance.name == instanceName &&
          m.instance.zone == zone)).toList();
    _saveToStorage();
  }

  void updateInstanceStatus(String projectId, String instanceName, String zone, String newStatus) {
    state = state.map((m) {
      if (m.projectId == projectId &&
          m.instance.name == instanceName &&
          m.instance.zone == zone) {
        return ManualInstance(
          projectId: m.projectId,
          instance: GcpInstanceClientLib(
            name: m.instance.name,
            status: newStatus,
            zone: m.instance.zone,
            machineType: m.instance.machineType,
            cpuCount: m.instance.cpuCount,
            memoryMb: m.instance.memoryMb,
            diskGb: m.instance.diskGb,
            labels: m.instance.labels,
            osLoginEnabled: m.instance.osLoginEnabled,
            isWindows: m.instance.isWindows,
          ),
        );
      }
      return m;
    }).toList();
    _saveToStorage();
  }

  void clear() {
    state = [];
    _saveToStorage();
  }
}