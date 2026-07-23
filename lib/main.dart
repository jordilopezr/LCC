import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'src/bridge/api.dart/api.dart';
import 'src/bridge/api.dart/gcloud.dart';
import 'src/bridge/api.dart/frb_generated.dart';
import 'src/features/gcloud_provider.dart';
import 'src/features/settings_dialog.dart';
import 'src/features/settings_provider.dart';
import 'src/features/diagnostics_panel.dart';
import 'src/features/connectivity_doctor.dart';
import 'src/features/windows_credentials_dialog.dart';
import 'src/features/sshfs_mount_provider.dart';
import 'src/features/manual_instance_dialog.dart';
import 'src/features/account_management_dialog.dart';
import 'src/features/tunnel_manager_dialog.dart';
import 'src/features/snapshot_manager_dialog.dart';
import 'src/services/storage_service.dart';
import 'src/services/notification_service.dart';
import 'src/features/workspace/overview_tab.dart';

/// Helper: Check if instance has any active tunnel
bool hasAnyActiveTunnel(
  Map<String, TunnelState> connections,
  String instanceName,
) {
  return connections.keys.any(
    (key) =>
        key.startsWith('$instanceName:') &&
        connections[key]?.status == 'connected',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageService().init();
  await RustLib.init();

  // Initialize structured logging system
  try {
    await initLoggingSystem();
    debugPrint('✓ Logging system initialized');
  } catch (e) {
    debugPrint('⚠️  Failed to initialize logging: $e');
    // Continue anyway - logging is not critical for app functionality
  }

  // Initialize notification service
  try {
    await NotificationService().initialize();
    debugPrint('✓ Notification service initialized');
  } catch (e) {
    debugPrint('⚠️  Failed to initialize notifications: $e');
    // Continue anyway - notifications are not critical for app functionality
  }

  // Security: Clean up old RDP configuration files that may contain sensitive data
  // Files older than 1 hour are automatically removed
  try {
    final cleanedCount = await cleanupRdpConfigFiles();
    if (cleanedCount > 0) {
      debugPrint(
        '✓ Security cleanup: removed $cleanedCount old RDP config file(s)',
      );
    }
  } catch (e) {
    debugPrint('⚠️  Config cleanup failed: $e');
    // Continue anyway - cleanup is not critical for app functionality
  }

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appThemeMode = ref.watch(themeModeProvider);
    final appLocale = ref.watch(localeProvider);

    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: appLocale, // null → system
      themeMode: _toThemeMode(appThemeMode),
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      home: const DashboardScreen(),
    );
  }

  /// Convert AppThemeMode to Flutter's ThemeMode
  ThemeMode _toThemeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  /// Light theme configuration
  ThemeData _buildLightTheme() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blueAccent,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(centerTitle: false, elevation: 1),
      cardTheme: CardThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  /// Dark theme configuration
  ThemeData _buildDarkTheme() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blueAccent,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 1,
        backgroundColor: Colors.grey.shade900,
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
    );
  }
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(gcloudStatusProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/app_icon_transparent.png', height: 40),
            const SizedBox(width: 10),
            Text(l10n.appTitle),
          ],
        ),
        actions: [
          // Account indicator chip (Sprint 8)
          statusAsync.when(
            data: (status) {
              if (status['authenticated'] != true)
                return const SizedBox.shrink();
              return Consumer(
                builder: (context, ref, _) {
                  final accountState = ref.watch(accountProvider);
                  final email = accountState.activeAccountEmail;
                  final accountCount = accountState.accountCount;

                  // Show chip even while loading (with icon-only fallback)
                  if (email == null) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: IconButton(
                        icon: const Icon(Icons.account_circle),
                        tooltip: accountState.isLoading
                            ? l10n.dashboardLoadingAccountsTooltip
                            : l10n.accountManageTitle,
                        onPressed: () => showAccountManagementDialog(context),
                      ),
                    );
                  }

                  final displayEmail = email.length > 25
                      ? '${email.substring(0, 23)}...'
                      : email;

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      avatar: Icon(
                        Icons.account_circle,
                        size: 18,
                        color: accountCount > 1 ? Colors.blue : null,
                      ),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayEmail,
                            style: const TextStyle(fontSize: 12),
                          ),
                          if (accountCount > 1) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '+${accountCount - 1}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.blue.shade800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      onPressed: () => showAccountManagementDialog(context),
                    ),
                  );
                },
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          // Logout button with multi-account support
          statusAsync.when(
            data: (status) => status['authenticated'] == true
                ? IconButton(
                    icon: const Icon(Icons.logout),
                    tooltip: l10n.appLogoutButton,
                    onPressed: () => _showLogoutDialog(context, ref),
                  )
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          // Tunnel Manager button (Sprint 9)
          Consumer(
            builder: (context, ref, _) {
              final stats = ref.watch(tunnelStatsProvider);
              return IconButton(
                icon: Badge(
                  isLabelVisible: stats.totalTunnels > 0,
                  label: Text('${stats.totalTunnels}'),
                  backgroundColor: stats.hasErrors ? Colors.red : Colors.blue,
                  child: const Icon(Icons.lan),
                ),
                tooltip: l10n.tunnelManagerTitle,
                onPressed: () => showTunnelManagerDialog(context),
              );
            },
          ),

          _buildAutoRefreshToggle(ref),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.appConnectionHistoryTitle,
            onPressed: () => _showHistoryDialog(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: l10n.appExportLogsTooltip,
            onPressed: () => _exportLogs(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l10n.settingsTitle,
            onPressed: () => showSettingsDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: l10n.manualInstanceTitle,
            onPressed: () => _showManualInstanceDialog(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: l10n.appAboutTooltip,
            onPressed: () => _showAboutDialog(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: statusAsync.when(
        data: (status) {
          if (status['installed'] != true) {
            return Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_off,
                          size: 72,
                          color: Colors.blueGrey.shade300,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.dashboardGcloudRequiredTitle,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.dashboardGcloudRequiredDescription,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.dashboardInstallInstructionsTitle,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  l10n.dashboardInstallInstructionsBody,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 16),
                                SelectableText(
                                  'https://docs.cloud.google.com/sdk/docs/install-sdk',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () {
                                Process.run('xdg-open', [
                                  'https://docs.cloud.google.com/sdk/docs/install-sdk',
                                ]);
                              },
                              icon: const Icon(Icons.open_in_new),
                              label: Text(l10n.dashboardOpenInstructionsButton),
                            ),
                            const SizedBox(width: 16),
                            FilledButton.icon(
                              onPressed: () {
                                ref.invalidate(gcloudStatusProvider);
                              },
                              icon: const Icon(Icons.refresh),
                              label: Text(l10n.dashboardCheckAgainButton),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
          if (status['authenticated'] != true) {
            return Center(
              child: ElevatedButton.icon(
                onPressed: () async {
                  try {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.dashboardLaunchingBrowserLogin),
                      ),
                    );
                    await gcloudLogin();
                    ref.invalidate(gcloudStatusProvider);
                    // Invalidate multi-project provider to reload instances after login
                    ref.invalidate(multiProjectProvider);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.dashboardLoginFailed('$e'))),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.login),
                label: Text(l10n.dashboardLoginButton),
              ),
            );
          }

          return const Row(
            children: [
              SizedBox(width: 300, child: ResourceTree()),
              VerticalDivider(width: 1),
              Expanded(child: InstanceDetailPane()),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text(l10n.commonErrorPrefix('$err'))),
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      // Show loading indicator
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 16),
                Text(l10n.appExportingLogs),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // Call Rust export function
      final exportPath = await exportLogsToFile();

      // Show success dialog with path
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                Text(l10n.appLogsExportedTitle),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.appLogsExportedBody,
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    exportPath,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.appLogsExportedHint,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.commonClose),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      // Show error
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.appExportLogsFailed('$e')),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Logout dialog with multi-account support (Sprint 8)
  void _showLogoutDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final accountState = ref.read(accountProvider);
    final isMultiAccount = accountState.isMultiAccount;
    final activeEmail = accountState.activeAccountEmail ?? 'current account';

    if (isMultiAccount) {
      // Multi-account: offer logout this account vs logout all
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.appLogoutButton),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.appLogoutMultiAccountCount(accountState.accountCount),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.appLogoutActiveAccount(activeEmail),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'this'),
              child: Text(
                l10n.appLogoutThisAccount(activeEmail),
                style: TextStyle(color: Colors.orange.shade700),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: Text(
                l10n.appLogoutAllAccounts,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );

      if (result == 'this' && context.mounted) {
        try {
          await ref.read(accountProvider.notifier).removeAccount(activeEmail);
          await StorageService().clearSessionData();
          ref.invalidate(gcloudStatusProvider);
          ref.invalidate(projectsProvider);
          ref.invalidate(selectedProjectProvider);
          ref.invalidate(instancesProvider);
          ref.invalidate(multiProjectProvider);
          ref.invalidate(sshfsMountProvider);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.appLoggedOutAccount(activeEmail))),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.appLogoutError('$e'))));
          }
        }
      } else if (result == 'all' && context.mounted) {
        await _performFullLogout(context, ref);
      }
    } else {
      // Single account: standard behavior
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.appLogoutButton),
          content: Text(l10n.appLogoutConfirmSingle),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                l10n.appLogoutButton,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );

      if (confirm == true && context.mounted) {
        await _performFullLogout(context, ref);
      }
    }
  }

  Future<void> _performFullLogout(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    try {
      await gcloudLogout();
      await StorageService().clearSessionData();
      ref.invalidate(gcloudStatusProvider);
      ref.invalidate(activeConnectionsProvider);
      ref.invalidate(projectsProvider);
      ref.invalidate(selectedProjectProvider);
      ref.invalidate(instancesProvider);
      ref.invalidate(multiProjectProvider);
      ref.invalidate(sshfsMountProvider);
      ref.invalidate(accountProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.appLoggedOutFullMessage)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.appLogoutError('$e'))));
      }
    }
  }

  Widget _buildAutoRefreshToggle(WidgetRef ref) {
    final autoRefreshState = ref.watch(autoRefreshProvider);
    final l10n = AppLocalizations.of(ref.context);

    return IconButton(
      icon: Icon(
        autoRefreshState.enabled ? Icons.refresh : Icons.refresh_outlined,
        color: autoRefreshState.enabled ? Colors.green : null,
      ),
      tooltip: autoRefreshState.enabled
          ? l10n.dashboardAutoRefreshEnabledTooltip(
              autoRefreshState.interval.inSeconds,
            )
          : l10n.dashboardEnableAutoRefreshTooltip,
      onPressed: () {
        ref.read(autoRefreshProvider.notifier).toggle();

        ScaffoldMessenger.of(ref.context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  autoRefreshState.enabled
                      ? Icons.pause_circle
                      : Icons.play_circle,
                  color: Colors.white,
                ),
                const SizedBox(width: 12),
                Text(
                  autoRefreshState.enabled
                      ? l10n.dashboardAutoRefreshDisabledSnackbar
                      : l10n.dashboardAutoRefreshEnabledSnackbar(
                          autoRefreshState.interval.inSeconds,
                        ),
                ),
              ],
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: autoRefreshState.enabled
                ? Colors.orange[700]
                : Colors.green[700],
          ),
        );
      },
    );
  }

  void _showHistoryDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => const ConnectionHistoryDialog(),
    );
  }

  Future<void> _showManualInstanceDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final result = await showManualInstanceDialog(context);
    if (result != null && context.mounted) {
      final l10n = AppLocalizations.of(context);
      // Add the manual instance to the provider
      ref
          .read(manualInstancesProvider.notifier)
          .addInstance(result.projectId, result.instance);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.appAddedInstanceSnackbar(result.instance.name)),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showAboutDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──────────────────────────────────────────────
                Row(
                  children: [
                    Image.asset(
                      'assets/app_icon_transparent.png',
                      height: 52,
                      width: 52,
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.appTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _editionChip(l10n.commonEditionLabel('26H2')),
                            const SizedBox(width: 8),
                            Text(
                              l10n.commonBuildLabel('20260715.1'),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.appCopyright,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 16),
                Text(l10n.appTagline, style: const TextStyle(fontSize: 13)),

                // ── Versioning model ────────────────────────────────────
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.calendar_month,
                            size: 14,
                            color: Colors.blue.shade700,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.appEditionsCalverTitle,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.appEditionsCalverBody,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue.shade800,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── What's new ──────────────────────────────────────────
                const SizedBox(height: 16),
                Text(
                  l10n.appWhatsNewTitle('26H2'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),

                Text(l10n.appWhatsNewItem1, style: const TextStyle(fontSize: 12)),
                Text(l10n.appWhatsNewItem2, style: const TextStyle(fontSize: 12)),
                Text(l10n.appWhatsNewItem3, style: const TextStyle(fontSize: 12)),
                Text(l10n.appWhatsNewItem4, style: const TextStyle(fontSize: 12)),
                Text(l10n.appWhatsNewItem5, style: const TextStyle(fontSize: 12)),
                Text(l10n.appWhatsNewItem6, style: const TextStyle(fontSize: 12)),
                Text(l10n.appWhatsNewItem7, style: const TextStyle(fontSize: 12)),

                const Divider(height: 28),

                // ── Links ───────────────────────────────────────────────
                Text(
                  l10n.appDeveloperLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                const SelectableText(
                  "Jordi Lopez Reyes  ·  aim@jordilopezr.com",
                  style: TextStyle(fontSize: 12, color: Colors.blue),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.appSourceCodeLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => Process.run('xdg-open', ['https://github.com/jordilopezr/LCC']),
                    child: const Text(
                      "https://github.com/jordilopezr/LCC",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.settingsSupportDevelopmentTitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => Process.run('xdg-open', ['https://buymeacoffee.com/jordimlopezr']),
                    child: const Text(
                      "https://buymeacoffee.com/jordimlopezr",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.appTechStackLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.appTechStackValue,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  Widget _editionChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.blueAccent,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class ResourceTree extends ConsumerStatefulWidget {
  const ResourceTree({super.key});

  @override
  ConsumerState<ResourceTree> createState() => _ResourceTreeState();
}

class _ResourceTreeState extends ConsumerState<ResourceTree> {
  final TextEditingController _searchController = TextEditingController();
  String _filterStatus = 'All'; // 'All', 'RUNNING', 'STOPPED'
  String? _filterProject; // Filter by specific project (null = all)

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Get a consistent color for a project based on its ID
  Color _getProjectColor(String projectId) {
    final hash = projectId.hashCode;
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.amber,
      Colors.cyan,
      Colors.deepOrange,
    ];
    return colors[hash.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final multiProjectState = ref.watch(multiProjectProvider);
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        // Multi-project selector button
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: MultiProjectSelectorButton(),
        ),
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.dashboardSearchInstancesHint,
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 0,
              ),
              isDense: true,
            ),
            onChanged: (value) => setState(() {}),
          ),
        ),
        const SizedBox(height: 8),
        // Filters row
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: [
              _buildFilterChip('All', l10n.dashboardFilterAll),
              const SizedBox(width: 8),
              _buildFilterChip('RUNNING', 'RUNNING'),
              const SizedBox(width: 8),
              _buildFilterChip('STOPPED', 'STOPPED'),
              const SizedBox(width: 8),
              _buildFilterChip('SUSPENDED', 'SUSPENDED'),
              // Project filter dropdown (only if multiple projects)
              if (multiProjectState.selectedProjectIds.length > 1) ...[
                const SizedBox(width: 12),
                const VerticalDivider(width: 1),
                const SizedBox(width: 8),
                _buildProjectFilterDropdown(multiProjectState, l10n),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildMultiProjectInstanceList(context, ref)),
      ],
    );
  }

  Widget _buildProjectFilterDropdown(
    MultiProjectState multiProjectState,
    AppLocalizations l10n,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(16),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _filterProject,
          hint: Text(
            l10n.dashboardAllProjectsHint,
            style: const TextStyle(fontSize: 12),
          ),
          isDense: true,
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                l10n.dashboardAllProjectsHint,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            ...multiProjectState.selectedProjectIds.map((projectId) {
              final color = _getProjectColor(projectId);
              return DropdownMenuItem<String?>(
                value: projectId,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      projectId.length > 20
                          ? '${projectId.substring(0, 18)}...'
                          : projectId,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              );
            }),
          ],
          onChanged: (value) => setState(() => _filterProject = value),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String displayLabel) {
    final isSelected = _filterStatus == label;
    return FilterChip(
      label: Text(
        displayLabel,
        style: TextStyle(
          fontSize: 12,
          color: isSelected ? Colors.white : Colors.black87,
        ),
      ),
      selected: isSelected,
      onSelected: (bool selected) {
        setState(() {
          _filterStatus = label;
        });
      },
      checkmarkColor: Colors.white,
      selectedColor: Colors.blueAccent,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  /// Get a consistent color for an account based on its email
  Color _getAccountColor(String email) {
    final hash = email.hashCode;
    final colors = [
      Colors.deepPurple,
      Colors.teal,
      Colors.indigo,
      Colors.brown,
      Colors.blueGrey,
    ];
    return colors[hash.abs() % colors.length];
  }

  /// Multi-project instance list with hierarchical grouping: Account → Project → Zone → VM
  Widget _buildMultiProjectInstanceList(BuildContext context, WidgetRef ref) {
    final multiProjectState = ref.watch(multiProjectProvider);
    final selectedInstance = ref.watch(multiProjectSelectedInstanceProvider);
    final connections = ref.watch(activeConnectionsProvider);
    final favorites = ref.watch(favoritesProvider);
    final accountState = ref.watch(accountProvider);
    final l10n = AppLocalizations.of(context);

    // No projects selected
    if (multiProjectState.selectedProjectIds.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              l10n.dashboardNoProjectsSelected,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.dashboardSelectProjectsHint,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    // Check if any project is still loading
    final anyLoading = multiProjectState.projectStates.values.any(
      (p) => p.isLoading,
    );
    final allInstances = multiProjectState.allInstances;

    // Apply filters
    final query = _searchController.text.toLowerCase();
    final filteredInstances = allInstances.where((pai) {
      // Project filter
      if (_filterProject != null && pai.projectId != _filterProject) {
        return false;
      }
      // Name search (also search labels)
      final matchesName =
          pai.name.toLowerCase().contains(query) ||
          pai.instance.labels.any(
            (l) =>
                l.$1.toLowerCase().contains(query) ||
                l.$2.toLowerCase().contains(query),
          );
      // Status filter
      final matchesStatus =
          _filterStatus == 'All' ||
          (_filterStatus == 'RUNNING' && pai.status == 'RUNNING') ||
          (_filterStatus == 'STOPPED' && pai.status == 'STOPPED') ||
          (_filterStatus == 'SUSPENDED' && pai.status == 'SUSPENDED');
      return matchesName && matchesStatus;
    }).toList();

    // Build list content
    Widget listContent;

    if (allInstances.isEmpty && anyLoading) {
      // Initial loading
      listContent = const Center(child: CircularProgressIndicator());
    } else if (filteredInstances.isEmpty && allInstances.isEmpty) {
      // Check for errors
      final errorProjects = multiProjectState.projectStates.entries
          .where((e) => e.value.error != null)
          .toList();

      if (errorProjects.isNotEmpty) {
        // Show error summary
        listContent = Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 48,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.dashboardProjectsErrorsTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...errorProjects
                    .take(3)
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _getProjectColor(e.key),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              e.key,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              e.value.error?.contains('403') == true
                                  ? l10n.dashboardPermissionDeniedParen
                                  : l10n.dashboardErrorParen,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        );
      } else {
        // No instances found
        listContent = Center(
          child: Text(l10n.dashboardNoInstancesFoundProjects),
        );
      }
    } else if (filteredInstances.isEmpty) {
      listContent = Center(child: Text(l10n.dashboardNoMatchingInstances));
    } else {
      // Separate favorites from regular instances
      final favoriteInstances = filteredInstances
          .where((pai) => favorites.contains(pai.uniqueKey))
          .toList();
      final regularInstances = filteredInstances
          .where((pai) => !favorites.contains(pai.uniqueKey))
          .toList();

      // Group regular by Project → Zone → Instance
      final Map<String, Map<String, List<ProjectAwareInstance>>> byProjectZone =
          {};

      for (var pai in regularInstances) {
        byProjectZone.putIfAbsent(pai.projectId, () => {});
        byProjectZone[pai.projectId]!.putIfAbsent(pai.zone, () => []).add(pai);
      }

      // Sort projects alphabetically
      final sortedProjects = byProjectZone.keys.toList()..sort();

      // Account grouping: group projects by account if >1 account has projects
      final accountProjectMap = StorageService().getAccountProjects();
      final accountsWithProjects = <String, List<String>>{};
      for (final projectId in sortedProjects) {
        String? ownerAccount;
        for (final entry in accountProjectMap.entries) {
          if (entry.value.contains(projectId)) {
            ownerAccount = entry.key;
            break;
          }
        }
        ownerAccount ??= accountState.activeAccountEmail ?? 'default';
        accountsWithProjects.putIfAbsent(ownerAccount, () => []).add(projectId);
      }
      final showAccountLevel = accountsWithProjects.keys.length > 1;

      listContent = ListView(
        children: [
          // Favorites section (if any)
          if (favoriteInstances.isNotEmpty) ...[
            ExpansionTile(
              initiallyExpanded: true,
              leading: const Icon(Icons.star, color: Colors.amber, size: 20),
              title: Text(
                l10n.dashboardFavoritesCount(favoriteInstances.length),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.amber,
                ),
              ),
              children: favoriteInstances.map((pai) {
                final isSelected = selectedInstance?.uniqueKey == pai.uniqueKey;
                final isConnected = hasAnyActiveTunnel(connections, pai.name);
                final projectColor = _getProjectColor(pai.projectId);

                return ListTile(
                  dense: true,
                  selected: isSelected,
                  selectedTileColor: Colors.blue.withValues(alpha: 0.1),
                  contentPadding: const EdgeInsets.only(left: 24, right: 16),
                  leading: Stack(
                    children: [
                      Icon(
                        Icons.computer,
                        size: 16,
                        color: isConnected
                            ? Colors.green
                            : (pai.status == 'RUNNING'
                                  ? Colors.blueGrey
                                  : Colors.grey),
                      ),
                      if (isConnected)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.green.shade700,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 1),
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: projectColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          pai.name,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    '${pai.projectId} • ${pai.zone}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.star, size: 18, color: Colors.amber),
                    tooltip: l10n.dashboardRemoveFavoriteTooltip,
                    onPressed: () {
                      ref
                          .read(favoritesProvider.notifier)
                          .toggle(pai.uniqueKey);
                    },
                  ),
                  onTap: () {
                    ref
                        .read(multiProjectSelectedInstanceProvider.notifier)
                        .select(pai);
                  },
                );
              }).toList(),
            ),
            const Divider(height: 1),
          ],
          // Regular projects (with optional account-level grouping)
          if (showAccountLevel)
            ...accountsWithProjects.entries.map((accountEntry) {
              final accountEmail = accountEntry.key;
              final accountProjects = accountEntry.value;
              final accountColor = _getAccountColor(accountEmail);
              final isActive = accountEmail == accountState.activeAccountEmail;

              return ExpansionTile(
                initiallyExpanded: true,
                leading: Icon(
                  Icons.account_circle,
                  size: 20,
                  color: accountColor,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        accountEmail,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isActive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          l10n.accountActiveBadge,
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.green.shade800,
                          ),
                        ),
                      ),
                  ],
                ),
                children: accountProjects
                    .map(
                      (projectId) => _buildProjectExpansionTile(
                        projectId,
                        byProjectZone,
                        multiProjectState,
                        selectedInstance,
                        connections,
                        favorites,
                        ref,
                        l10n,
                        tilePadding: const EdgeInsets.only(left: 24, right: 16),
                      ),
                    )
                    .toList(),
              );
            })
          else
            ...sortedProjects.map(
              (projectId) => _buildProjectExpansionTile(
                projectId,
                byProjectZone,
                multiProjectState,
                selectedInstance,
                connections,
                favorites,
                ref,
                l10n,
              ),
            ),
        ],
      );
    }

    // Wrap with loading indicator if refreshing
    if (anyLoading && filteredInstances.isNotEmpty) {
      return Stack(
        children: [
          listContent,
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ],
      );
    }

    return listContent;
  }

  /// Build a project expansion tile with zones and instances
  Widget _buildProjectExpansionTile(
    String projectId,
    Map<String, Map<String, List<ProjectAwareInstance>>> byProjectZone,
    MultiProjectState multiProjectState,
    ProjectAwareInstance? selectedInstance,
    Map<String, TunnelState> connections,
    Set<String> favorites,
    WidgetRef ref,
    AppLocalizations l10n, {
    EdgeInsetsGeometry? tilePadding,
  }) {
    final zonesMap = byProjectZone[projectId]!;
    final sortedZones = zonesMap.keys.toList()..sort();
    final projectState = multiProjectState.projectStates[projectId];
    final projectColor = _getProjectColor(projectId);
    final isProjectLoading = projectState?.isLoading ?? false;
    final projectError = projectState?.error;

    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: tilePadding,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: projectColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          if (isProjectLoading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (projectError != null)
            Icon(
              Icons.warning_amber_rounded,
              size: 14,
              color: Colors.orange.shade700,
            )
          else
            const Icon(Icons.folder, size: 14),
        ],
      ),
      title: Text(
        projectId,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
      ),
      subtitle: projectError != null
          ? Text(
              projectError.contains('403')
                  ? l10n.dashboardPermissionDenied
                  : l10n.dashboardErrorLoadingShort,
              style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
            )
          : null,
      children: sortedZones.map((zone) {
        final zoneInstances = zonesMap[zone]!;
        final zonePadding = tilePadding != null
            ? const EdgeInsets.only(left: 48, right: 16)
            : const EdgeInsets.only(left: 32, right: 16);
        final instancePadding = tilePadding != null
            ? const EdgeInsets.only(left: 72, right: 16)
            : const EdgeInsets.only(left: 56, right: 16);

        return ExpansionTile(
          initiallyExpanded: true,
          leading: const Icon(Icons.location_on_outlined, size: 16),
          title: Text(
            zone,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          tilePadding: zonePadding,
          children: zoneInstances.map((pai) {
            final isSelected = selectedInstance?.uniqueKey == pai.uniqueKey;
            final isConnected = hasAnyActiveTunnel(connections, pai.name);

            return GestureDetector(
              onSecondaryTapUp: (details) {
                _showInstanceContextMenu(
                  context,
                  details.globalPosition,
                  pai,
                  ref,
                );
              },
              child: ListTile(
                dense: true,
                selected: isSelected,
                selectedTileColor: Colors.blue.withValues(alpha: 0.1),
                contentPadding: instancePadding,
                leading: Stack(
                  children: [
                    Icon(
                      Icons.computer,
                      size: 16,
                      color: isConnected
                          ? Colors.green
                          : (pai.status == 'RUNNING'
                                ? Colors.blueGrey
                                : Colors.grey),
                    ),
                    if (isConnected)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.green.shade700,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                        ),
                      ),
                  ],
                ),
                title: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: projectColor.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        pai.name,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                subtitle: Text(
                  isConnected
                      ? l10n.dashboardRunningTunnelActive(pai.machineType)
                      : '${pai.status} • ${pai.machineType}',
                  style: TextStyle(
                    fontSize: 10,
                    color: isConnected ? Colors.green.shade700 : null,
                    fontWeight: isConnected ? FontWeight.bold : null,
                  ),
                ),
                trailing: IconButton(
                  icon: Icon(
                    favorites.contains(pai.uniqueKey)
                        ? Icons.star
                        : Icons.star_border,
                    size: 18,
                    color: favorites.contains(pai.uniqueKey)
                        ? Colors.amber
                        : Colors.grey,
                  ),
                  tooltip: favorites.contains(pai.uniqueKey)
                      ? l10n.dashboardRemoveFavoriteTooltip
                      : l10n.dashboardAddFavoriteTooltip,
                  onPressed: () {
                    ref.read(favoritesProvider.notifier).toggle(pai.uniqueKey);
                  },
                ),
                onTap: () {
                  ref
                      .read(multiProjectSelectedInstanceProvider.notifier)
                      .select(pai);
                },
              ),
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  /// Show context menu on right-click for quick actions
  void _showInstanceContextMenu(
    BuildContext context,
    Offset position,
    ProjectAwareInstance pai,
    WidgetRef ref,
  ) {
    final l10n = AppLocalizations.of(context);
    final isRunning = pai.status == 'RUNNING';
    final isStopped = pai.status == 'STOPPED';
    final isSuspended = pai.status == 'SUSPENDED';
    final isWindows = pai.isWindows;

    final items = <PopupMenuEntry<String>>[];
    PopupMenuItem<String> proItem(
      String value,
      IconData iconData,
      String title, {
      Color? iconColor,
    }) {
      return PopupMenuItem(
        value: value,
        child: ListTile(
          leading: Icon(iconData, size: 18, color: iconColor),
          title: Text(title, style: const TextStyle(fontSize: 13)),
          dense: true,
        ),
      );
    }

    if (isRunning) {
      if (!isWindows) {
        items.add(
          const PopupMenuItem(
            value: 'ssh',
            child: ListTile(
              leading: Icon(Icons.terminal, size: 18),
              title: Text('SSH', style: TextStyle(fontSize: 13)),
              dense: true,
            ),
          ),
        );
        items.add(proItem('vnc', Icons.remove_red_eye, 'VNC'));
        items.add(
          const PopupMenuItem(
            value: 'sftp',
            child: ListTile(
              leading: Icon(Icons.folder_open, size: 18),
              title: Text('SFTP', style: TextStyle(fontSize: 13)),
              dense: true,
            ),
          ),
        );
        items.add(
          proItem('sshfs', Icons.folder_shared, l10n.dashboardMenuMountSshfs),
        );
      } else {
        items.add(proItem('rdp', Icons.desktop_windows, 'RDP'));
        items.add(proItem('winpass', Icons.vpn_key, l10n.winCredTitle));
      }
      items.add(const PopupMenuDivider());
      items.add(
        PopupMenuItem(
          value: 'stop',
          child: ListTile(
            leading: const Icon(Icons.stop, size: 18, color: Colors.orange),
            title: Text(
              l10n.dashboardMenuStop,
              style: const TextStyle(fontSize: 13),
            ),
            dense: true,
          ),
        ),
      );

      // Suspend only if machine type supports it
      items.add(
        PopupMenuItem(
          value: 'suspend',
          child: ListTile(
            leading: Icon(
              Icons.pause_circle_outline,
              size: 18,
              color: Colors.amber.shade700,
            ),
            title: Text(
              l10n.dashboardMenuSuspend,
              style: const TextStyle(fontSize: 13),
            ),
            dense: true,
          ),
        ),
      );

      items.add(
        PopupMenuItem(
          value: 'reset',
          child: ListTile(
            leading: const Icon(Icons.restart_alt, size: 18, color: Colors.red),
            title: Text(
              l10n.dashboardMenuReset,
              style: const TextStyle(fontSize: 13),
            ),
            dense: true,
          ),
        ),
      );
    } else if (isStopped) {
      items.add(
        PopupMenuItem(
          value: 'start',
          child: ListTile(
            leading: const Icon(Icons.play_arrow, size: 18, color: Colors.green),
            title: Text(
              l10n.dashboardMenuStart,
              style: const TextStyle(fontSize: 13),
            ),
            dense: true,
          ),
        ),
      );
    } else if (isSuspended) {
      items.add(
        PopupMenuItem(
          value: 'resume',
          child: ListTile(
            leading: const Icon(Icons.play_arrow, size: 18, color: Colors.green),
            title: Text(
              l10n.dashboardMenuResume,
              style: const TextStyle(fontSize: 13),
            ),
            dense: true,
          ),
        ),
      );
    }

    items.add(const PopupMenuDivider());
    items.add(
      proItem(
        'diagnostics',
        Icons.build_circle_outlined,
        l10n.diagTabDiagnostics,
        iconColor: Colors.orange,
      ),
    );
    items.add(
      proItem(
        'doctor',
        Icons.medical_services_outlined,
        l10n.dashboardMenuDoctor,
        iconColor: Colors.teal,
      ),
    );
    items.add(
      proItem(
        'snapshots',
        Icons.camera_alt_outlined,
        l10n.snapshotTabList,
        iconColor: Colors.indigo,
      ),
    );

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: items,
    ).then((value) {
      if (value == null) return;
      // Select the instance first
      ref.read(multiProjectSelectedInstanceProvider.notifier).select(pai);

      final connectionsNotifier = ref.read(activeConnectionsProvider.notifier);

      switch (value) {
        case 'ssh':
          launchSsh(
            projectId: pai.projectId,
            zone: pai.zone,
            instanceName: pai.name,
          );
        case 'rdp':
          connectionsNotifier.launchRDP(pai.projectId, pai.zone, pai.name);
        case 'vnc':
          connectionsNotifier.launchVNC(pai.projectId, pai.zone, pai.name);
        case 'sftp':
          // Open SFTP via tunnel
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.dashboardOpeningSftp)));
        case 'sshfs':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.dashboardOpeningSshfsMount)),
          );
        case 'winpass':
          showWindowsCredentialsDialog(
            context,
            ref: ref,
            projectId: pai.projectId,
            zone: pai.zone,
            instanceName: pai.name,
          );
        case 'start':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.dashboardStartingInstanceShort)),
          );
          connectionsNotifier.startInstanceWithMethod(
            pai.projectId,
            pai.zone,
            pai.name,
          );
        case 'stop':
          connectionsNotifier.disconnectAllForInstance(pai.name).then((_) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.dashboardStoppingInstanceShort)),
            );
            connectionsNotifier.stopInstanceWithMethod(
              pai.projectId,
              pai.zone,
              pai.name,
            );
          });
        case 'suspend':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.dashboardSuspendingInstanceShort)),
          );
          connectionsNotifier.suspendInstanceWithMethod(
            pai.projectId,
            pai.zone,
            pai.name,
          );
        case 'resume':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.dashboardResumingInstanceShort)),
          );
          connectionsNotifier.resumeInstanceWithMethod(
            pai.projectId,
            pai.zone,
            pai.name,
          );
        case 'reset':
          connectionsNotifier.disconnectAllForInstance(pai.name).then((_) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.dashboardResettingInstanceShort)),
            );
            connectionsNotifier.resetInstanceWithMethod(
              pai.projectId,
              pai.zone,
              pai.name,
            );
          });
        case 'diagnostics':
          showDiagnosticsPanel(
            context,
            projectId: pai.projectId,
            zone: pai.zone,
            instanceName: pai.name,
          );
        case 'doctor':
          showConnectivityDoctor(
            context,
            projectId: pai.projectId,
            zone: pai.zone,
            instanceName: pai.name,
          );
        case 'snapshots':
          showSnapshotManager(
            context,
            projectId: pai.projectId,
            zone: pai.zone,
            instanceName: pai.name,
          );
      }
    });
  }
}

class InstanceDetailPane extends ConsumerWidget {
  const InstanceDetailPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Thin wrapper kept for backward compatibility until the workspace panel
    // (Task 7) replaces this in the root layout. The actual content now
    // lives in OverviewTab, parameterized by an explicit target instead of
    // reading the globally-selected instance here.
    final selectedInstance = ref.watch(multiProjectSelectedInstanceProvider);
    final l10n = AppLocalizations.of(context);

    if (selectedInstance == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.touch_app, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              l10n.dashboardSelectInstanceHint,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return OverviewTab(target: selectedInstance);
  }
}

class ProjectSelector extends ConsumerWidget {
  const ProjectSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);
    final selectedProject = ref.watch(selectedProjectProvider);
    final l10n = AppLocalizations.of(context);

    return projectsAsync.when(
      data: (projects) {
        if (projects.isEmpty) return Text(l10n.appNoProjectsFound);

        // Ensure selected value exists in the list
        final validSelection =
            projects.any((p) => p.projectId == selectedProject)
            ? selectedProject
            : null;

        // If selection became invalid, update provider safely?
        // Better to just show null in UI, provider will update when user picks.

        return DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: l10n.appSelectProjectLabel,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 0,
            ),
          ),
          isExpanded: true,
          value: validSelection,
          items: projects.map((GcpProject p) {
            return DropdownMenuItem<String>(
              value: p.projectId,
              child: Text(
                // Show both name and projectId for clarity
                p.name != null && p.name != p.projectId
                    ? "${p.name} (${p.projectId})"
                    : p.projectId,
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: (value) {
            ref.read(selectedProjectProvider.notifier).select(value);
            ref
                .read(selectedInstanceProvider.notifier)
                .select(null); // Clear selection
          },
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (err, _) => Text(l10n.appErrorLoadingProjects('$err')),
    );
  }
}

// ==========================================
// MULTI-PROJECT UI COMPONENTS (v2.0.0)
// ==========================================

/// Button to open the project management dialog
class MultiProjectSelectorButton extends ConsumerWidget {
  const MultiProjectSelectorButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final multiProjectState = ref.watch(multiProjectProvider);
    final count = multiProjectState.selectedProjectIds.length;
    final isLoading =
        multiProjectState.isRefreshing || multiProjectState.hasLoadingProjects;
    final hasErrors = multiProjectState.projectsWithError.isNotEmpty;
    final l10n = AppLocalizations.of(context);

    return ElevatedButton(
      onPressed: () => _showProjectManagementDialog(context),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
        backgroundColor: hasErrors ? Colors.orange.shade50 : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.folder_special, color: hasErrors ? Colors.orange : null),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              count == 0
                  ? l10n.appSelectProjectsButton
                  : l10n.appProjectsSelectedCount(
                      count,
                      multiProjectState.totalInstances,
                    ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasErrors) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: l10n.appProjectsErrorsTooltip(
                multiProjectState.projectsWithError.length,
              ),
              child: Icon(
                Icons.warning,
                size: 16,
                color: Colors.orange.shade700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showProjectManagementDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const ProjectManagementDialog(),
    );
  }
}

/// Dialog for managing project selection
class ProjectManagementDialog extends ConsumerStatefulWidget {
  const ProjectManagementDialog({super.key});

  @override
  ConsumerState<ProjectManagementDialog> createState() =>
      _ProjectManagementDialogState();
}

class _ProjectManagementDialogState
    extends ConsumerState<ProjectManagementDialog> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Get a consistent color for a project based on its ID
  Color _getProjectColor(String projectId) {
    final hash = projectId.hashCode;
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.amber,
      Colors.cyan,
      Colors.deepOrange,
    ];
    return colors[hash.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsProvider);
    final multiProjectState = ref.watch(multiProjectProvider);
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.folder_special, color: Colors.blue),
          const SizedBox(width: 12),
          Expanded(child: Text(l10n.appManageProjectsTitle)),
          // Refresh button
          IconButton(
            icon: multiProjectState.isRefreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: l10n.appRefreshAllProjectsTooltip,
            onPressed: multiProjectState.isRefreshing
                ? null
                : () => ref
                      .read(multiProjectProvider.notifier)
                      .refreshAllProjects(),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 450,
        child: Column(
          children: [
            // Search bar
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.appSearchProjectsHint,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
              ),
              onChanged: (value) => setState(() {}),
            ),
            const SizedBox(height: 12),

            // Selected count indicator
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    color: Colors.blue.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.appProjectsSelectedOfMax(
                      multiProjectState.selectedProjectIds.length,
                      StorageService.maxSelectedProjects,
                    ),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade700,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    l10n.appTotalVmsLabel(multiProjectState.totalInstances),
                    style: TextStyle(color: Colors.blue.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Project list
            Expanded(
              child: projectsAsync.when(
                data: (projects) {
                  final query = _searchController.text.toLowerCase();
                  final filtered = projects
                      .where(
                        (p) =>
                            p.projectId.toLowerCase().contains(query) ||
                            (p.name?.toLowerCase().contains(query) ?? false),
                      )
                      .toList();

                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        query.isEmpty
                            ? l10n.appNoProjectsAvailable
                            : l10n.appNoMatchingProjects,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final project = filtered[index];
                      final isSelected = multiProjectState.selectedProjectIds
                          .contains(project.projectId);
                      final projectState =
                          multiProjectState.projectStates[project.projectId];
                      final hasError = projectState?.error != null;
                      final isLoading = projectState?.isLoading ?? false;
                      final instanceCount = projectState?.instanceCount ?? 0;
                      final projectColor = _getProjectColor(project.projectId);

                      return CheckboxListTile(
                        value: isSelected,
                        onChanged:
                            multiProjectState.selectedProjectIds.length >=
                                    StorageService.maxSelectedProjects &&
                                !isSelected
                            ? null // Disable if at limit and not selected
                            : (value) {
                                ref
                                    .read(multiProjectProvider.notifier)
                                    .toggleProject(project.projectId);
                              },
                        title: Row(
                          children: [
                            // Color indicator
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? projectColor
                                    : Colors.grey.shade300,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                project.name ?? project.projectId,
                                style: TextStyle(
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Row(
                          children: [
                            Expanded(
                              child: Text(
                                project.projectId,
                                style: const TextStyle(fontSize: 11),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isLoading)
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else if (hasError)
                              Tooltip(
                                message: projectState!.error!.split('\n').first,
                                child: const Icon(
                                  Icons.error,
                                  size: 16,
                                  color: Colors.red,
                                ),
                              )
                            else if (isSelected && instanceCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: projectColor.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  l10n.appInstanceCountVms(instanceCount),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: projectColor.shade700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 48,
                        color: Colors.red,
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.appErrorLoadingProjects('$err')),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: multiProjectState.selectedProjectIds.isEmpty
              ? null
              : () => ref.read(multiProjectProvider.notifier).clearAll(),
          child: Text(l10n.appClearAllButton),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.appDoneButton),
        ),
      ],
    );
  }
}

// ==========================================
// CONNECTION HISTORY DIALOG
// ==========================================

/// Dialog showing connection history
class ConnectionHistoryDialog extends ConsumerWidget {
  const ConnectionHistoryDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(connectionHistoryProvider);
    final multiProjectState = ref.watch(multiProjectProvider);
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.history, size: 28),
          const SizedBox(width: 12),
          Text(l10n.appConnectionHistoryTitle),
          const Spacer(),
          if (history.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l10n.appClearButton),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(l10n.appClearHistoryTitle),
                    content: Text(l10n.appClearHistoryConfirm),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(l10n.commonCancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(
                          l10n.appClearButton,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await ref
                      .read(connectionHistoryProvider.notifier)
                      .clearHistory();
                }
              },
            ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 400,
        child: history.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.history, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(
                      l10n.appNoConnectionHistory,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.appNoConnectionHistoryHint,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final entry = history[index];
                  final timeAgo = _formatTimeAgo(entry.timestamp, l10n);

                  // Check if VM still exists in current project state
                  final vmExists = multiProjectState.allInstances.any(
                    (i) => i.uniqueKey == entry.uniqueKey,
                  );

                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _getConnectionTypeColor(
                        entry.connectionType,
                      ),
                      child: Icon(
                        _getConnectionTypeIcon(entry.connectionType),
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.instanceName,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _getConnectionTypeColor(
                              entry.connectionType,
                            ).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            entry.typeLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: _getConnectionTypeColor(
                                entry.connectionType,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${entry.projectId} • ${entry.zone}',
                            style: const TextStyle(fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          timeAgo,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    trailing: vmExists
                        ? IconButton(
                            icon: const Icon(Icons.play_arrow),
                            tooltip: l10n.appConnectAgainTooltip,
                            onPressed: () {
                              // Find and select the VM
                              final vm = multiProjectState.allInstances
                                  .firstWhere(
                                    (i) => i.uniqueKey == entry.uniqueKey,
                                  );
                              ref
                                  .read(
                                    multiProjectSelectedInstanceProvider
                                        .notifier,
                                  )
                                  .select(vm);
                              Navigator.of(context).pop();
                            },
                          )
                        : Tooltip(
                            message: l10n.appVmNotFoundTooltip,
                            child: Icon(
                              Icons.error_outline,
                              color: Colors.grey.shade400,
                            ),
                          ),
                    onTap: vmExists
                        ? () {
                            final vm = multiProjectState.allInstances
                                .firstWhere(
                                  (i) => i.uniqueKey == entry.uniqueKey,
                                );
                            ref
                                .read(
                                  multiProjectSelectedInstanceProvider.notifier,
                                )
                                .select(vm);
                            Navigator.of(context).pop();
                          }
                        : null,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  String _formatTimeAgo(DateTime timestamp, AppLocalizations l10n) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) {
      return l10n.appJustNow;
    } else if (diff.inMinutes < 60) {
      return l10n.appMinutesAgo(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return l10n.appHoursAgo(diff.inHours);
    } else if (diff.inDays < 7) {
      return l10n.appDaysAgo(diff.inDays);
    } else {
      return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
    }
  }

  Color _getConnectionTypeColor(String type) {
    switch (type) {
      case 'rdp':
        return Colors.blue;
      case 'ssh':
        return Colors.green;
      case 'vnc':
        return Colors.purple;
      case 'sftp':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  IconData _getConnectionTypeIcon(String type) {
    switch (type) {
      case 'rdp':
        return Icons.desktop_windows;
      case 'ssh':
        return Icons.terminal;
      case 'vnc':
        return Icons.remove_red_eye;
      case 'sftp':
        return Icons.folder_open;
      default:
        return Icons.link;
    }
  }
}

/// Helper extension for color shade access
extension ColorShade on Color {
  Color get shade700 {
    final hsl = HSLColor.fromColor(this);
    return hsl.withLightness((hsl.lightness - 0.1).clamp(0.0, 1.0)).toColor();
  }
}
