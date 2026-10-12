import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/db_client.dart';
import '../bridge/api.dart/gcloud.dart';
import '../bridge/api.dart/gcp_rest_client.dart';
import '../bridge/api.dart/rdp_client.dart';
import '../bridge/api.dart/sshfs_mount.dart';
import '../bridge/api.dart/vnc_client.dart';
import '../services/storage_service.dart';
import '../services/notification_service.dart';
import 'settings_provider.dart';
import 'package:linux_cloud_connector/src/features/vnc_display.dart';
import 'snapshot_provider.dart';
import 'ssh_consent_dialog.dart';
import 'dashboard_gate.dart';
import 'package:linux_cloud_connector/src/features/app_error.dart';

// ==========================================
// MULTI-ACCOUNT MANAGEMENT (Sprint 8 - v2.7.0)
// ==========================================

class AccountState {
  final List<GcloudAccount> accounts;
  final String? activeAccountEmail;
  final bool isLoading;
  final String? error;

  const AccountState({
    this.accounts = const [],
    this.activeAccountEmail,
    this.isLoading = false,
    this.error,
  });

  AccountState copyWith({
    List<GcloudAccount>? accounts,
    String? activeAccountEmail,
    bool? isLoading,
    String? error,
  }) {
    return AccountState(
      accounts: accounts ?? this.accounts,
      activeAccountEmail: activeAccountEmail ?? this.activeAccountEmail,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  /// Number of authenticated accounts
  int get accountCount => accounts.length;

  /// Whether multiple accounts are active
  bool get isMultiAccount => accounts.length > 1;
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
      );
    }
  }

  /// Add a new account (opens browser)
  Future<void> addAccount() async {
    try {
      final previousEmail = state.activeAccountEmail;
      await addGcloudAccount();
      await refresh();
      // The added account becomes active when none was (Rust's index_upsert):
      // the workspace must then be that account's, not the one still loaded.
      if (state.activeAccountEmail != previousEmail) {
        ref.invalidate(multiProjectProvider);
      }
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

const _sshForwardPrefix = 'sshfwd:';

/// Composite key for SSH port-forward tunnels: "sshfwd:instanceName:port"
String makeSshForwardKey(String instanceName, int remotePort) =>
    '$_sshForwardPrefix$instanceName:$remotePort';

/// Whether a tunnel key belongs to an SSH port forward (vs. an IAP tunnel).
/// An SSH-forward key is `sshfwd:<instance>:<port>` (3 colon parts); requiring
/// 3 parts avoids misclassifying an IAP tunnel for an instance literally named
/// `sshfwd` (whose key is `sshfwd:<port>`, 2 parts).
bool isSshForwardKey(String key) =>
    key.startsWith(_sshForwardPrefix) && key.split(':').length == 3;

/// Parse tunnel key back to instance and port
/// Returns (instanceName, remotePort) or null if invalid format
(String, int)? parseTunnelKey(String key) {
  final bare = isSshForwardKey(key)
      ? key.substring(_sshForwardPrefix.length)
      : key;
  final parts = bare.split(':');
  if (parts.length != 2) return null;

  final port = int.tryParse(parts[1]);
  if (port == null) return null;

  return (parts[0], port);
}

// Estado para la instalación/auth
/// Whether gcloud is installed and whether there is a usable session.
///
/// Both come from one Rust call, because under the native auth engine having a
/// session must not depend on gcloud being installed — this used to
/// short-circuit on `installed`, so on a machine without gcloud the account
/// dialog never asked for the list at all. The map's shape is unchanged for
/// its consumers.
/// `gcloudRequired` is what the dashboard's "install the SDK" screen gates on:
/// `installed` alone would still blank the whole body under the native engine
/// on a machine without gcloud, session or no session.
/// The keyring keys say why a native session with an active account is not
/// usable; see `dashboardGateFor`.
final gcloudStatusProvider = FutureProvider<Map<String, bool>>((ref) async {
  return statusMapFor(await checkAuthStatus());
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
  // A session Google rejected is rejected again on every retry; see
  // retryUnlessSignedOut. Other failures keep Riverpod's backoff.
}, retry: retryUnlessSignedOut);

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

// Provider para la lista de instancias (account-aware, vía REST del cliente Rust).
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

  // listInstances() va por el cliente REST de Rust (sigue la cuenta activa). En
  // fallo propagamos: una lista vacía ocultaría el problema real.
  try {
    return await listInstances(projectId: projectId);
  } catch (e) {
    debugPrint('Instance listing failed for $projectId: $e');
    rethrow;
  }
}, retry: retryUnlessSignedOut);

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
/// How many tunnels are carrying something right now.
///
/// Asked when the user closes the window, to decide whether closing would
/// interrupt anything. Only `connected` counts: a tunnel in error carries
/// nothing, and one still connecting or retrying has nothing to interrupt yet.
int activeTunnelCount(Map<String, TunnelState> tunnels) =>
    tunnels.values.where((t) => t.status == 'connected').length;

/// Which warning the close dialog should carry, if any.
enum CloseWarning {
  /// Nothing in progress — close without asking.
  none,
  sessionsOnly,
  tunnelsOnly,
  both,
}

/// Decide what the user is about to lose by closing.
///
/// Kept apart from the counts themselves because the distinction is the point:
/// a single combined number would let the dialog say "3 things" and leave the
/// user guessing whether that includes the RDP session they are looking at.
///
/// Tunnels began to matter here only recently. They used to survive the app's
/// exit — a leak, since fixed — so closing the window left a live forward
/// behind and the silence cost nothing. Now the child dies with the parent by
/// construction, and closing really does cut the session.
CloseWarning closeWarning({required int sessions, required int tunnels}) {
  if (sessions > 0 && tunnels > 0) return CloseWarning.both;
  if (sessions > 0) return CloseWarning.sessionsOnly;
  if (tunnels > 0) return CloseWarning.tunnelsOnly;
  return CloseWarning.none;
}

/// Mark the tunnels Rust reaped as dead, leaving every other entry untouched.
///
/// Rust's `cleanup_dead_connections` is the only signal that reaches an SSH
/// forward. The periodic health check addresses a tunnel by (instance, remote
/// port), and that pair cannot name a forward — which is why forwards are
/// skipped there. The reap list is keyed, so it names both kinds, and by the
/// time a key appears in it Rust has already stopped the tunnel and dropped it
/// from its registry.
///
/// Pure on purpose: the timer does the talking to Rust, this does the thinking,
/// and the thinking is what the tests can reach.
Map<String, TunnelState> markDeadTunnels(
  Map<String, TunnelState> state,
  List<String> deadKeys,
  DateTime now,
) {
  if (deadKeys.isEmpty) return state;

  final marked = {...state};
  for (final key in deadKeys) {
    final previous = marked[key];
    // Rust reaps by key and knows nothing of what the UI is showing, so a key
    // the UI never had must not conjure an entry.
    if (previous == null) continue;
    // A tunnel mid-reconnect is owned by the reconnect flow, which stopped the
    // old one in Rust itself. Marking it dead here would clobber that.
    if (previous.status == 'reconnecting') continue;

    marked[key] = TunnelState(
      status: 'error',
      port: previous.port,
      remotePort: previous.remotePort,
      errorCode: 'session_lost',
      createdAt: previous.createdAt,
      lastHealthCheck: now,
      projectId: previous.projectId,
      zone: previous.zone,
      autoReconnectEnabled: previous.autoReconnectEnabled,
      engine: previous.engine,
    );
  }
  return marked;
}

class TunnelState {
  final String status; // 'disconnected', 'connecting', 'connected', 'error', 'reconnecting'
  final int? port; // Local port where tunnel listens (e.g., 40759)
  final int? remotePort; // Remote port being forwarded (e.g., 3389 for RDP, 22 for SSH)
  final String? error;
  final String? errorCode; // Stable machine-readable code from TunnelFailure (Task 8 localizes it)
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

  /// The engine used for this entry ('native' or 'gcloud'): the one holding
  /// it, as the start call reported, or — on a row whose start failed — the
  /// one that tried, as the TunnelFailure reported. Null when no engine ran:
  /// still connecting, or a failure before an engine was chosen.
  ///
  /// `required` although nullable, on purpose — do not "tidy" it into an
  /// optional parameter. There is no copyWith: eleven places rebuild a
  /// TunnelState from the previous one (health check, reconnect, dead
  /// marking, RDP/VNC reuse), and with an optional parameter forgetting to
  /// pass `engine: previous.engine` in any of them compiles cleanly and
  /// silently blanks the tag on the next health check, thirty seconds later —
  /// on the very row someone is diagnosing. Required, every construction has
  /// to say what it knows about the engine, and the compiler checks it.
  ///
  /// What `required` does NOT check is that the answer is right, and no test
  /// covers the places that get it from the bridge — those flows call Rust:
  /// - the three constructions right after a successful start (`_connect`,
  ///   `_connectSshForward`, `_attemptReconnection`) must pass
  ///   `started.engine`;
  /// - the two `on TunnelFailure` handlers (`_connect`, `_connectSshForward`)
  ///   must pass `e.engine`, and `_attemptReconnection`'s catch its
  ///   `failedEngine`.
  /// Passing `null` in any of them compiles and keeps every test green, and
  /// the tag never appears. Whoever edits those has to read them.
  final String? engine;

  const TunnelState({
    required this.engine,
    this.status = 'disconnected',
    this.port,
    this.remotePort,
    this.error,
    this.errorCode,
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

  /// Connect calls in progress, keyed by tunnel key. Used to single-flight
  /// concurrent [connect] calls for the same tunnel so they do not each spawn
  /// a backend (see [connect]).
  final Map<String, Future<int?>> _inFlightConnects = {};

  /// Local port the user explicitly requested per tunnel (keyed by the stable
  /// tunnelKey). Absent = auto-assigned. Read on auto-reconnect so a chosen
  /// port survives the idle-reaper; removed on explicit disconnect.
  final Map<String, int?> _requestedLocalPorts = {};

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

  /// Periodic health check for all active tunnels with reconnection logic
  Future<void> _checkAllTunnels(Timer timer) async {
    final currentConnections = {...state};
    final now = DateTime.now();

    for (var entry in currentConnections.entries) {
      final tunnelKey = entry.key;
      final tunnelState = entry.value;

      // Forwards are not health-checked here, and cannot be: the check below
      // addresses a tunnel by (instance, remote port), and that pair names an
      // IAP tunnel — never a forward, whose key carries the `sshfwd:` prefix.
      // They are covered by the reap sweep at the end of this method instead,
      // which is keyed and so reaches both kinds.
      if (isSshForwardKey(tunnelKey)) continue;

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
                  engine: tunnelState.engine,
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
                engine: tunnelState.engine,
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
                engine: tunnelState.engine,
              ),
            };
          }
        }
      }
    }

    // Every cycle: let Rust reap whatever died, and show it.
    //
    // This used to run every 5 cycles and only `debugPrint` the result, which
    // meant a dead SSH forward — the one kind of tunnel the health check above
    // cannot reach — stayed green in the manager forever. The sweep is cheap
    // (a lock and a liveness check per tunnel) and it is the only signal a
    // forward has, so it runs as often as the check it stands in for.
    try {
      final reaped = await cleanupDeadConnections();
      if (reaped.isNotEmpty) {
        debugPrint('Rust reaped ${reaped.length} dead tunnel(s): $reaped');
        final before = state;
        state = markDeadTunnels(before, reaped, now);
        for (final key in reaped) {
          final died = before[key];
          // Only announce what the user was actually being shown as working,
          // and leave a reconnection in progress to speak for itself.
          if (died == null || died.status != 'connected') continue;
          final parsed = parseTunnelKey(key);
          if (parsed == null) continue;
          await NotificationService().notifyTunnelFailed(
            instanceName: parsed.$1,
            remotePort: parsed.$2,
            project: died.projectId ?? 'unknown',
            zone: died.zone ?? 'unknown',
          );
        }
      }
    } catch (e) {
      debugPrint('Reap sweep failed: $e');
    }
  }

  /// Enter the reconnecting state for a tunnel
  void _enterReconnectingState(String tunnelKey, TunnelState tunnelState) {
    final now = DateTime.now();
    final backoff = const TunnelState(engine: null).nextBackoffDelay; // 2s for first attempt

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
        engine: tunnelState.engine,
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
      final started = await startConnection(
        projectId: tunnelState.projectId!,
        zone: tunnelState.zone!,
        instanceName: instanceName,
        remotePort: remotePort,
        localPort: _requestedLocalPorts[tunnelKey],
      );
      final port = started.localPort;

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
          engine: started.engine,
        ),
      };
    } catch (e) {
      debugPrint('Reconnection attempt $attempt failed for $tunnelKey: $e');
      // The row now shows the engine that just failed. A failure from before
      // any engine ran carries none, and then the row keeps the one it had.
      final failedEngine = (e is TunnelFailure ? e.engine : null) ?? tunnelState.engine;

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
            engine: failedEngine,
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
            engine: failedEngine,
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
        engine: tunnel.engine,
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
        engine: tunnel.engine,
      ),
    };

    // Attempt immediately
    await _attemptReconnection(tunnelKey, state[tunnelKey]!);
  }

  /// Disconnect ALL tunnels
  Future<void> disconnectAll() async {
    final tunnelsToDisconnect = state.entries.toList();
    for (final entry in tunnelsToDisconnect) {
      await disconnectByKey(entry.key);
    }
  }

  Future<int?> connect(
    String projectId,
    String zone,
    String instanceName, {
    int remotePort = 3389, // Default to RDP port, configurable via Custom Tunnel dialog
    int? localPort,
  }) {
    // Use composite key to support multiple tunnels per instance
    final tunnelKey = makeTunnelKey(instanceName, remotePort);

    // Single-flight: if a connect for this exact tunnel key is already in
    // progress, join it instead of starting a second backend. Without this,
    // two callers racing inside start_tunnel's ~1s spawn window — e.g. an SSH
    // tab and an SFTP tab opening the same VM:port within a second — would each
    // spawn a tunnel, and the second insert would overwrite the first in the
    // Rust TUNNELS map, orphaning (leaking) the first backend.
    final existing = _inFlightConnects[tunnelKey];
    if (existing != null) {
      return existing;
    }

    final future = _connect(projectId, zone, instanceName, remotePort, tunnelKey, localPort);
    _inFlightConnects[tunnelKey] = future;
    // Clear the in-flight entry once it settles (success or failure), but only
    // if it is still ours (defensive against a re-entrant replacement).
    future.whenComplete(() {
      if (identical(_inFlightConnects[tunnelKey], future)) {
        _inFlightConnects.remove(tunnelKey);
      }
    });
    return future;
  }

  Future<int?> _connect(
    String projectId,
    String zone,
    String instanceName,
    int remotePort,
    String tunnelKey,
    int? localPort,
  ) async {
    // No tier limits apply

    // Actualizar estado de ESTE túnel específico a 'connecting'
    state = {
      ...state,
      tunnelKey: const TunnelState(status: 'connecting', engine: null)
    };

    try {
      final started = await startConnection(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        remotePort: remotePort,
        localPort: localPort,
      );
      final port = started.localPort;

      // Actualizar a 'connected'
      final now = DateTime.now();
      if (localPort != null) {
        _requestedLocalPorts[tunnelKey] = localPort;
      } else {
        _requestedLocalPorts.remove(tunnelKey);
      }
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
          engine: started.engine,
        )
      };
      return port;
    } on TunnelFailure catch (e) {
      // Error solo en este túnel específico
      state = {
        ...state,
        tunnelKey: TunnelState(
          status: 'error',
          remotePort: remotePort,
          error: e.detail ?? e.code,
          errorCode: e.code,
          projectId: projectId,
          zone: zone,
          engine: e.engine,
        )
      };
      // No hacemos rethrow para no romper la UI general, el estado refleja el error
      return null;
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
          engine: null,
        )
      };
      // No hacemos rethrow para no romper la UI general, el estado refleja el error
      return null;
    }
  }

  /// Single-flight connect for an SSH port forward (mirrors [connect]).
  ///
  /// [context] must be a live [BuildContext] from the widget that triggers the
  /// connection: the first forward into a project may need to show the SSH
  /// consent dialog, and this notifier has no context of its own.
  Future<int?> connectSshForward(
    BuildContext context,
    String projectId,
    String zone,
    String instanceName, {
    required int remotePort,
    int? localPort,
  }) {
    final tunnelKey = makeSshForwardKey(instanceName, remotePort);
    final existing = _inFlightConnects[tunnelKey];
    if (existing != null) return existing;
    final future = _connectSshForward(
        context, projectId, zone, instanceName, remotePort, tunnelKey, localPort);
    _inFlightConnects[tunnelKey] = future;
    future.whenComplete(() {
      if (identical(_inFlightConnects[tunnelKey], future)) {
        _inFlightConnects.remove(tunnelKey);
      }
    });
    return future;
  }

  Future<int?> _connectSshForward(BuildContext context, String projectId, String zone,
      String instanceName, int remotePort, String tunnelKey, int? localPort) async {
    state = {...state, tunnelKey: const TunnelState(status: 'connecting', engine: null)};
    try {
      final outcome = await ensureSshAccess(
        context,
        projectId: projectId,
        zone: zone,
        instance: instanceName,
      );
      if (outcome is SshAccessAbandoned) {
        // The widget that triggered this vanished mid-probe/consent. Not a
        // failure the user caused — leave no error, just undo 'connecting'.
        state = {...state, tunnelKey: const TunnelState(status: 'disconnected', engine: null)};
        return null;
      }
      if (outcome is SshAccessRefused) {
        // A refusal with a dead context used to leave `error: null` on an
        // 'error' state — an error chip with no text, which tells the user
        // nothing at all. The refusal is a fact independent of any widget
        // being alive, so it gets a message either way; only the localised
        // wording depends on the context.
        final deniedMessage = context.mounted
            ? AppLocalizations.of(context).sshConsentDenied
            : 'LCC is not authorised to add an SSH key to this project.';
        state = {
          ...state,
          tunnelKey: TunnelState(
            status: 'error',
            remotePort: remotePort,
            error: deniedMessage,
            projectId: projectId,
            zone: zone,
            engine: null,
          ),
        };
        return null;
      }
      final granted = outcome as SshAccessGranted;
      // The key travels with the user name. Without it the native forward
      // re-walks libssh2's candidate ladder, which offers LCC's own key LAST:
      // a user with a couple of agent identities plus the usual `~/.ssh`
      // files exhausts `sshd`'s default `MaxAuthTries` of 6 before it is
      // reached, and the forward fails moments after provisioning reported
      // success.
      final started = await startSshForward(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        remotePort: remotePort,
        localPort: localPort,
        username: granted.username,
        identityFile: granted.keyPath,
      );
      final port = started.localPort;
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
          autoReconnectEnabled: false,
          engine: started.engine,
        ),
      };
      return port;
    } on TunnelFailure catch (e) {
      state = {
        ...state,
        tunnelKey: TunnelState(
          status: 'error',
          remotePort: remotePort,
          error: e.detail ?? e.code,
          errorCode: e.code,
          projectId: projectId,
          zone: zone,
          engine: e.engine,
        ),
      };
      return null;
    } catch (e) {
      state = {
        ...state,
        tunnelKey: TunnelState(
          status: 'error',
          remotePort: remotePort,
          error: e.toString(),
          projectId: projectId,
          zone: zone,
          engine: null,
        ),
      };
      return null;
    }
  }

  Future<void> disconnectByKey(String tunnelKey) async {
    final parsed = parseTunnelKey(tunnelKey);
    if (parsed != null) {
      try {
        if (isSshForwardKey(tunnelKey)) {
          await stopSshForward(instanceName: parsed.$1, remotePort: parsed.$2);
        } else {
          await stopConnection(instanceName: parsed.$1, remotePort: parsed.$2);
        }
      } catch (e) {
        debugPrint('Error stopping tunnel $tunnelKey: $e');
      }
    }
    final newState = Map<String, TunnelState>.from(state);
    newState.remove(tunnelKey);
    _requestedLocalPorts.remove(tunnelKey);
    state = newState;
  }

  Future<void> disconnect(String instanceName, int remotePort) async {
    return disconnectByKey(makeTunnelKey(instanceName, remotePort));
  }

  /// Disconnect ALL tunnels for a given instance (all ports)
  Future<void> disconnectAllForInstance(String instanceName) async {
    final tunnelsToRemove = state.entries
        .where((entry) => parseTunnelKey(entry.key)?.$1 == instanceName)
        .toList();

    for (final entry in tunnelsToRemove) {
      await disconnectByKey(entry.key);
    }
  }

  /// Returns whether an RDP client was actually launched. It used to return
  /// nothing — the same defect a43b816 fixed in [launchVNC] — so a tunnel that
  /// could not be built ended the press in silence. Callers that get `false`
  /// read `state[makeTunnelKey(instanceName, 3389)]` for why: `status ==
  /// 'error'` is the tunnel, anything else is the client.
  Future<bool> launchRDP(String projectId, String zone, String instanceName, {RdpSettings? settings}) async {
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
           return false; // Failed to connect, stop here.
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
            NotificationService().notifyClientFallback(
                protocol: 'RDP', clientName: clientName);
          }
          return true;
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
               lastHealthCheck: activeTunnel?.lastHealthCheck, // Preserve last check,
               engine: activeTunnel?.engine,
             )
           };
           return false;
        }
      }
      // Connected, but with no local port there is nothing to point a client
      // at. The tunnel entry already holds whatever is known about it.
      return false;
    } catch (e) {
       state = {
         ...state,
         tunnelKey: TunnelState(status: 'error', remotePort: rdpPort, error: "Auto-connect failed: $e", engine: null)
       };
       return false;
    }
  }

  /// Launch VNC on the display remembered for this VM, for callers with no
  /// dialog to ask for one — the right-click menu.
  ///
  /// The menu used to call [launchVNC] with no display at all: it tunnelled
  /// 5900 whatever the VM served on, and since [launchVNC] saves the display
  /// it is given, it also wrote 0 over the one the user had set. Returns the
  /// launch result and the port used, so the caller reads the tunnel entry
  /// that was actually built rather than assuming 5900.
  Future<(bool, int)> launchVncRemembered(
      String projectId, String zone, String instanceName) async {
    final display = await ref
        .read(vncDisplayProvider.notifier)
        .displayFor(vncVmKey(projectId, zone, instanceName));
    final launched =
        await launchVNC(projectId, zone, instanceName, display: display);
    return (launched, vncPortForDisplay(display));
  }

  /// `display` is the VNC display the VM serves on: `:0` is port 5900, `:1` is
  /// 5901. It used to be the constant 5900, which left a VM on any other
  /// display unreachable from here with no way to say so.
  ///
  /// Returns whether a viewer was actually launched. It used to return
  /// nothing, so a tunnel that could not be built — a port IAP cannot reach,
  /// for instance — ended the press in silence and the reason was only
  /// visible to someone who thought to open the tunnel manager. Callers that
  /// get `false` read `state[makeTunnelKey(instanceName, port)]` for why:
  /// `status == 'error'` is the tunnel, anything else is the viewer.
  Future<bool> launchVNC(String projectId, String zone, String instanceName,
      {VncSettings? settings, int display = 0}) async {
    final vncPort = vncPortForDisplay(display);
    // Remembered now rather than on a successful connection: a wrong number
    // stays in the field where the user can see and fix it, instead of being
    // quietly forgotten and retyped.
    await ref
        .read(vncDisplayProvider.notifier)
        .setDisplay(vncVmKey(projectId, zone, instanceName), display);
    final tunnelKey = makeTunnelKey(instanceName, vncPort);
    final currentTunnel = state[tunnelKey];
    bool alreadyConnected = currentTunnel?.status == 'connected' && currentTunnel?.port != null;

    try {
      if (!alreadyConnected) {
        await connect(projectId, zone, instanceName, remotePort: vncPort);
        // Check if connection succeeded
        final newTunnel = state[tunnelKey];
        if (newTunnel?.status != 'connected') {
           return false; // Failed to connect, stop here.
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
            NotificationService().notifyClientFallback(
                protocol: 'VNC', clientName: clientName);
          }
          return true;
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
               lastHealthCheck: activeTunnel?.lastHealthCheck, // Preserve last check,
               engine: activeTunnel?.engine,
             )
           };
           return false;
        }
      }
      // Connected, but with no local port there is nothing to point a viewer
      // at. The tunnel entry already holds whatever is known about it.
      return false;
    } catch (e) {
       state = {
         ...state,
         tunnelKey: TunnelState(status: 'error', remotePort: vncPort, error: "Auto-connect failed: $e", engine: null)
       };
       return false;
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
      await startInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
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
      await stopInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
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

      await suspendInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
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
      await resumeInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
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
      await resetInstanceClientLib(projectId: projectId, zone: zone, instanceName: instanceName);
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
  String? get internalIp => instance.internalIp;
  String? get externalIp => instance.externalIp;

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

    // The selection belongs to the active account. The global list is the
    // last account's: after signing out of it and into another, loading that
    // list asked Google for its projects with the new account's token (403/404
    // on every one) and never showed the new account's own. Asked of Rust, not
    // of accountProvider, which may still be loading or hold the old account.
    String? activeEmail;
    try {
      final accounts = await listGcloudAccounts();
      activeEmail =
          accounts.where((a) => a.status == 'ACTIVE').firstOrNull?.account;
    } catch (e) {
      debugPrint('Could not resolve the active account: $e');
    }
    if (activeEmail != null) {
      await StorageService().migrateProjectsToAccount(activeEmail);
    }
    final savedProjects =
        StorageService().getSelectedProjectsForAccount(activeEmail);
    await StorageService().saveSelectedProjects(savedProjects);

    if (savedProjects.isNotEmpty) {
      state = state.copyWith(
        selectedProjectIds: savedProjects.toSet(),
      );

      // Check if user is authenticated before trying to load instances.
      // Engine-aware: `checkGcloudAuth` always shells out to gcloud, so under
      // the native engine on a gcloud-free machine it is permanently false and
      // the saved projects would load with their instances never refreshed.
      try {
        final isAuthenticated = (await checkAuthStatus()).authenticated;
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