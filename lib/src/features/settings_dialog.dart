import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'app_error.dart';
import 'gcloud_provider.dart';
import 'settings_provider.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/rdp_client.dart';
import '../bridge/api.dart/vnc_client.dart';
import '../version.dart';

/// Settings dialog for configuring app preferences
class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  final _customIntervalController = TextEditingController();
  bool _showCustomInterval = false;

  @override
  void dispose() {
    _customIntervalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final autoRefreshEnabled = ref.watch(autoRefreshEnabledProvider);
    final autoRefreshInterval = ref.watch(autoRefreshIntervalProvider);
    final notificationsEnabled = ref.watch(notificationsEnabledProvider);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.settings, size: 28),
          const SizedBox(width: 12),
          Text(l10n.settingsTitle),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ===== APPEARANCE SECTION =====
              Text(
                l10n.settingsAppearanceTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              _buildThemeSelector(),
              const Divider(height: 32),

              // ===== LANGUAGE SECTION =====
              Text(
                l10n.settingsLanguageTitle,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Consumer(builder: (context, ref, _) {
                final current = ref.watch(localeProvider);
                return Column(children: [
                  RadioListTile<String>(
                    title: Text(AppLocalizations.of(context).settingsLanguageSystem),
                    value: 'system',
                    groupValue: current?.languageCode ?? 'system',
                    onChanged: (_) => ref.read(localeProvider.notifier).setLocale(null),
                  ),
                  RadioListTile<String>(
                    title: const Text('English'),
                    value: 'en',
                    groupValue: current?.languageCode ?? 'system',
                    onChanged: (_) =>
                        ref.read(localeProvider.notifier).setLocale(const Locale('en')),
                  ),
                  RadioListTile<String>(
                    title: const Text('Español'),
                    value: 'es',
                    groupValue: current?.languageCode ?? 'system',
                    onChanged: (_) =>
                        ref.read(localeProvider.notifier).setLocale(const Locale('es')),
                  ),
                ]);
              }),
              const Divider(height: 32),

              // ===== AUTH ENGINE SECTION =====
              _EngineSelector(
                slot: 'auth',
                title: l10n.settingsAuthEngineTitle,
                nativeLabel: l10n.settingsAuthEngineNative,
                nativeSubtitle: l10n.settingsAuthEngineNativeSubtitle,
                gcloudLabel: l10n.settingsAuthEngineGcloud,
                gcloudSubtitle: l10n.settingsAuthEngineGcloudSubtitle,
                onChanged: () {
                  // Without this the UI keeps showing the previous engine's
                  // accounts and projects until something else invalidates.
                  ref.invalidate(gcloudStatusProvider);
                  ref.invalidate(accountProvider);
                  ref.invalidate(projectsProvider);
                  ref.invalidate(instancesProvider);
                },
              ),
              const Divider(height: 32),

              // ===== AUTO-REFRESH SECTION =====
              Text(
                l10n.settingsAutoRefreshTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: Text(l10n.settingsEnableAutoRefresh),
                subtitle: Text(l10n.settingsAutoRefreshSubtitle),
                value: autoRefreshEnabled,
                onChanged: (value) {
                  ref.read(autoRefreshEnabledProvider.notifier).setEnabled(value);
                },
              ),
              const SizedBox(height: 8),
              if (autoRefreshEnabled) ...[
                Text(
                  l10n.settingsRefreshIntervalLabel,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                  // Full interval selector
                  ...RefreshInterval.values
                      .where((interval) => interval != RefreshInterval.custom)
                      .map((interval) {
                    // ignore: deprecated_member_use
                    return RadioListTile<RefreshInterval>(
                      title: Text(_getIntervalLabel(l10n, interval)),
                      subtitle: interval.seconds > 0
                          ? Text(l10n.settingsUpdateEverySeconds(interval.seconds))
                          : null,
                      value: interval,
                      // ignore: deprecated_member_use
                      groupValue: autoRefreshInterval,
                      // ignore: deprecated_member_use
                      onChanged: (value) {
                        if (value != null) {
                          ref
                              .read(autoRefreshIntervalProvider.notifier)
                              .setInterval(value);
                          setState(() => _showCustomInterval = false);
                        }
                      },
                    );
                  }),
                  // Custom interval option
                  // ignore: deprecated_member_use
                  RadioListTile<bool>(
                    title: Text(l10n.settingsCustomInterval),
                    subtitle: _showCustomInterval
                        ? null
                        : Text(l10n.settingsCustomIntervalSubtitle),
                    value: true,
                    // ignore: deprecated_member_use
                    groupValue: _showCustomInterval ||
                        autoRefreshInterval == RefreshInterval.custom,
                    // ignore: deprecated_member_use
                    onChanged: (value) {
                      if (value == true) {
                        setState(() => _showCustomInterval = true);
                      }
                    },
                  ),
                  if (_showCustomInterval ||
                      autoRefreshInterval == RefreshInterval.custom) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 32, right: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _customIntervalController,
                              decoration: InputDecoration(
                                labelText: l10n.settingsSecondsLabel,
                                hintText: '30',
                                border: const OutlineInputBorder(),
                                helperText: l10n.settingsSecondsHelper,
                              ),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () {
                              final seconds =
                                  int.tryParse(_customIntervalController.text);
                              if (seconds == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.settingsInvalidNumber),
                                  ),
                                );
                                return;
                              }
                              if (seconds < 5 || seconds > 600) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.settingsIntervalRange),
                                  ),
                                );
                                return;
                              }
                              ref
                                  .read(autoRefreshIntervalProvider.notifier)
                                  .setCustomInterval(seconds);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.settingsRefreshIntervalSet(seconds)),
                                ),
                              );
                            },
                            child: Text(l10n.settingsSetButton),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              const Divider(height: 32),

              // ===== NOTIFICATIONS SECTION =====
              Text(
                l10n.settingsNotificationsTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: Text(l10n.settingsEnableNotifications),
                subtitle: Text(l10n.settingsNotificationsSubtitle),
                value: notificationsEnabled,
                onChanged: (value) {
                  ref.read(notificationsEnabledProvider.notifier).setEnabled(value);
                },
              ),
              const SizedBox(height: 8),
              if (notificationsEnabled) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.settingsNotifiedAboutLabel,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      Text(l10n.settingsNotifyVmState, style: const TextStyle(fontSize: 12)),
                      Text(l10n.settingsNotifyIapFailures, style: const TextStyle(fontSize: 12)),
                      Text(l10n.settingsNotifyLifecycleResults, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
              const Divider(height: 32),

              // ===== SYSTEM DEPENDENCIES SECTION =====
              Text(
                l10n.settingsSystemDependenciesTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              _buildDependencyStatus(),
              const Divider(height: 32),

              // ===== RDP CLIENT SECTION =====
              Row(
                children: [
                  Text(
                    l10n.settingsRdpClientTitle,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildRdpClientSelector(),
              const Divider(height: 32),

              // ===== VNC CLIENT SECTION =====
              Row(
                children: [
                  Text(
                    l10n.settingsVncClientTitle,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildVncClientSelector(),
              const Divider(height: 32),

              // ===== ABOUT SECTION =====
              Text(
                l10n.settingsAboutTitle,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Image.asset('assets/app_icon_transparent.png', height: 40, width: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.appTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 4),
                        // Wrap (not Row) so the edition/update chips and build
                        // stamp flow to a second line instead of overflowing —
                        // Spanish labels ("Actualización", "Compilación") are
                        // long enough to overrun the narrow About column.
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _buildEditionChip(l10n.commonEditionLabel(kEdition)),
                            if (kUpdate > 0)
                              _buildEditionChip(
                                  l10n.commonUpdateLabel(kUpdate.toString())),
                            Text(l10n.commonBuildLabel(kBuild),
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontFamily: 'monospace')),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('© 2026 Jordi Lopez Reyes',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.blue.shade100),
                          ),
                          child: Text(
                            l10n.settingsEditionsDescription,
                            style: TextStyle(fontSize: 11, color: Colors.blue.shade800, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),

              // ===== SUPPORT SECTION =====
              Text(
                l10n.settingsSupportDevelopmentTitle,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.favorite, color: Colors.orange),
                title: const Text('Buy Me a Coffee'),
                subtitle: Text(
                  'buymeacoffee.com/jordimlopezr\n\n${l10n.settingsSupportMessage}',
                  style: const TextStyle(fontSize: 12),
                ),
                isThreeLine: true,
                onTap: () => Process.run('xdg-open', ['https://buymeacoffee.com/jordimlopezr']),
                mouseCursor: SystemMouseCursors.click,
              ),

              // ===== ADVANCED SECTION =====
              const Divider(height: 32),
              ExpansionTile(
                title: Text(
                  l10n.settingsAdvancedTitle,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(l10n.settingsAdvancedSubtitle),
                initiallyExpanded: false,
                childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
                children: [
                  _EngineSelector(
                    slot: 'tunnel',
                    title: l10n.settingsTunnelEngineTitle,
                    nativeLabel: l10n.settingsTunnelEngineNative,
                    nativeSubtitle: l10n.settingsTunnelEngineNativeSubtitle,
                    gcloudLabel: l10n.settingsTunnelEngineGcloud,
                    gcloudSubtitle: l10n.settingsTunnelEngineGcloudSubtitle,
                    footnote: l10n.settingsEngineAppliesToNewOnly,
                  ),
                  const SizedBox(height: 16),
                  _EngineSelector(
                    slot: 'ssh_forward',
                    title: l10n.settingsSshForwardEngineTitle,
                    nativeLabel: l10n.settingsSshForwardEngineNative,
                    nativeSubtitle: l10n.settingsSshForwardEngineNativeSubtitle,
                    gcloudLabel: l10n.settingsSshForwardEngineGcloud,
                    gcloudSubtitle: l10n.settingsSshForwardEngineGcloudSubtitle,
                    footnote: l10n.settingsEngineAppliesToNewOnly,
                  ),
                ],
              ),
            ],
          ),
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

  Widget _buildThemeSelector() {
    final l10n = AppLocalizations.of(context);
    final currentTheme = ref.watch(themeModeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            l10n.settingsChooseThemeLabel,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        ...AppThemeMode.values.map((mode) {
          final isSelected = currentTheme == mode;
          return RadioListTile<AppThemeMode>(
            title: Row(
              children: [
                Icon(
                  _getThemeIcon(mode),
                  size: 20,
                  color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
                const SizedBox(width: 12),
                Text(_getThemeLabel(l10n, mode)),
              ],
            ),
            subtitle: Text(_getThemeDescription(l10n, mode), style: const TextStyle(fontSize: 11)),
            value: mode,
            groupValue: currentTheme,
            onChanged: (value) {
              if (value != null) {
                ref.read(themeModeProvider.notifier).setTheme(value);
              }
            },
          );
        }),
      ],
    );
  }

  IconData _getThemeIcon(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return Icons.light_mode;
      case AppThemeMode.dark:
        return Icons.dark_mode;
      case AppThemeMode.system:
        return Icons.settings_brightness;
    }
  }

  String _getThemeLabel(AppLocalizations l10n, AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return l10n.settingsThemeLight;
      case AppThemeMode.dark:
        return l10n.settingsThemeDark;
      case AppThemeMode.system:
        return l10n.settingsThemeSystem;
    }
  }

  String _getIntervalLabel(AppLocalizations l10n, RefreshInterval interval) {
    switch (interval) {
      case RefreshInterval.disabled:
        return l10n.settingsIntervalDisabled;
      case RefreshInterval.fast10s:
        return l10n.settingsInterval10s;
      case RefreshInterval.default30s:
        return l10n.settingsInterval30s;
      case RefreshInterval.medium60s:
        return l10n.settingsInterval60s;
      case RefreshInterval.slow120s:
        return l10n.settingsInterval120s;
      case RefreshInterval.verySlow300s:
        return l10n.settingsInterval300s;
      case RefreshInterval.custom:
        return l10n.settingsCustomInterval;
    }
  }

  String _getThemeDescription(AppLocalizations l10n, AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return l10n.settingsThemeLightDesc;
      case AppThemeMode.dark:
        return l10n.settingsThemeDarkDesc;
      case AppThemeMode.system:
        return l10n.settingsThemeSystemDesc;
    }
  }

  Widget _buildEditionChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.35)),
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

  Widget _buildRdpClientSelector() {
    final l10n = AppLocalizations.of(context);
    final selectedClient = ref.watch(rdpClientProvider);
    final availableClientsAsync = ref.watch(availableRdpClientsProvider);

    return availableClientsAsync.when(
      data: (availableClients) {
        if (availableClients.isEmpty) {
          return Card(
            color: Colors.orange,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.settingsNoRdpClients,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                l10n.settingsSelectRdpClient,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            ...RdpClientType.values.map((client) {
              final isAvailable = availableClients.contains(client);
              final displayName = ref.read(rdpClientProvider.notifier).displayName(client);

              // ignore: deprecated_member_use
              return RadioListTile<RdpClientType>(
                title: Row(
                  children: [
                    Text(displayName),
                    if (!isAvailable) ...[
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(l10n.settingsNotInstalled, style: const TextStyle(fontSize: 10)),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        backgroundColor: Colors.grey.shade300,
                        labelStyle: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ],
                ),
                subtitle: isAvailable
                    ? Text(_getClientDescription(l10n, client))
                    : Text(l10n.settingsInstallClientHint, style: const TextStyle(fontSize: 11)),
                value: client,
                // ignore: deprecated_member_use
                groupValue: selectedClient,
                // ignore: deprecated_member_use
                onChanged: isAvailable
                    ? (value) {
                        if (value != null) {
                          ref.read(rdpClientProvider.notifier).setClient(value);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.settingsRdpClientSet(displayName)),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    : null,
                secondary: Icon(
                  _getClientIcon(client),
                  color: isAvailable ? Colors.blue : Colors.grey,
                ),
              );
            }),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.settingsClientTip,
                style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Text(
        l10n.settingsErrorDetectingRdp(localizedError(l10n, err, standalone: false)),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _buildVncClientSelector() {
    final l10n = AppLocalizations.of(context);
    final selectedClient = ref.watch(vncClientProvider);
    final availableClientsAsync = ref.watch(availableVncClientsProvider);

    return availableClientsAsync.when(
      data: (availableClients) {
        if (availableClients.isEmpty) {
          return Card(
            color: Colors.orange,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.settingsNoVncClients,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                l10n.settingsSelectVncClient,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            ...VncClientType.values.map((client) {
              final isAvailable = availableClients.contains(client);
              final displayName = ref.read(vncClientProvider.notifier).displayName(client);

              // ignore: deprecated_member_use
              return RadioListTile<VncClientType>(
                title: Row(
                  children: [
                    Text(displayName),
                    if (!isAvailable) ...[
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(l10n.settingsNotInstalled, style: const TextStyle(fontSize: 10)),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        backgroundColor: Colors.grey.shade300,
                        labelStyle: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ],
                ),
                subtitle: isAvailable
                    ? Text(_getVncClientDescription(l10n, client))
                    : Text(l10n.settingsInstallClientHint, style: const TextStyle(fontSize: 11)),
                value: client,
                // ignore: deprecated_member_use
                groupValue: selectedClient,
                // ignore: deprecated_member_use
                onChanged: isAvailable
                    ? (value) {
                        if (value != null) {
                          ref.read(vncClientProvider.notifier).setClient(value);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.settingsVncClientSet(displayName)),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    : null,
                secondary: Icon(
                  _getVncClientIcon(client),
                  color: isAvailable ? Colors.green : Colors.grey,
                ),
              );
            }),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.settingsClientTip,
                style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Text(
        l10n.settingsErrorDetectingVnc(localizedError(l10n, err, standalone: false)),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _buildDependencyStatus() {
    final l10n = AppLocalizations.of(context);
    final depStatus = ref.watch(dependencyStatusProvider);

    return depStatus.when(
      data: (status) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                l10n.settingsDependencyStatusLabel,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            // Required
            _depRow(l10n, 'gcloud CLI', status.gcloudInstalled, required: true),
            const Divider(height: 16, indent: 16, endIndent: 16),
            // Optional
            _depRow(l10n, l10n.settingsDepRdpClients, status.rdpClientsCount > 0, count: status.rdpClientsCount),
            _depRow(l10n, l10n.settingsDepVncClients, status.vncClientsCount > 0, count: status.vncClientsCount),
            _depRow(l10n, l10n.settingsDepSqlClients, status.dbClientsCount > 0, count: status.dbClientsCount),
            _depRow(l10n, 'SSHFS', status.sshfsAvailable),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, stack) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          l10n.settingsErrorCheckingDeps(localizedError(l10n, err, standalone: false)),
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _depRow(AppLocalizations l10n, String name, bool available, {bool required = false, int? count}) {
    return ListTile(
      dense: true,
      leading: Icon(
        available ? Icons.check_circle : Icons.cancel,
        color: available ? Colors.green : (required ? Colors.red : Colors.grey),
        size: 20,
      ),
      title: Row(
        children: [
          Text(name, style: const TextStyle(fontSize: 13)),
          if (required) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Text(l10n.settingsRequiredBadge, style: TextStyle(fontSize: 10, color: Colors.blue.shade700)),
            ),
          ],
        ],
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: available ? Colors.green.shade50 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          available
              ? (count != null ? l10n.settingsInstalledCount(count) : l10n.settingsInstalledLabel)
              : l10n.settingsNotFound,
          style: TextStyle(
            fontSize: 11,
            color: available ? Colors.green.shade700 : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  String _getClientDescription(AppLocalizations l10n, RdpClientType client) {
    switch (client) {
      case RdpClientType.remmina:
        return l10n.settingsRdpDescRemmina;
      case RdpClientType.freeRdp:
        return l10n.settingsRdpDescFreeRdp;
      case RdpClientType.krdc:
        return l10n.settingsRdpDescKrdc;
      case RdpClientType.gnomeConnections:
        return l10n.settingsRdpDescGnome;
    }
  }

  String _getVncClientDescription(AppLocalizations l10n, VncClientType client) {
    switch (client) {
      case VncClientType.remmina:
        return l10n.settingsVncDescRemmina;
      case VncClientType.tigerVnc:
        return l10n.settingsVncDescTigerVnc;
      case VncClientType.krdc:
        return l10n.settingsVncDescKrdc;
      case VncClientType.vinagre:
        return l10n.settingsVncDescVinagre;
    }
  }

  IconData _getClientIcon(RdpClientType client) {
    switch (client) {
      case RdpClientType.remmina:
        return Icons.desktop_windows;
      case RdpClientType.freeRdp:
        return Icons.terminal;
      case RdpClientType.krdc:
        return Icons.computer;
      case RdpClientType.gnomeConnections:
        return Icons.devices;
    }
  }

  IconData _getVncClientIcon(VncClientType client) {
    switch (client) {
      case VncClientType.remmina:
        return Icons.desktop_windows;
      case VncClientType.tigerVnc:
        return Icons.visibility;
      case VncClientType.krdc:
        return Icons.computer;
      case VncClientType.vinagre:
        return Icons.remove_red_eye;
    }
  }
}

/// What an engine selector shows: the choice it writes, plus the engine the
/// environment is forcing over it, if any.
class _EngineChoice {
  const _EngineChoice({required this.selected, required this.envOverride, this.envVar});

  /// The stored choice — what the radio buttons reflect and what they write.
  final String selected;

  /// The engine the slot's environment variable is forcing, or null when the
  /// environment is not overriding and `selected` is therefore also what is
  /// in force.
  final String? envOverride;

  /// The name of the environment variable doing the forcing, e.g.
  /// `LCC_TUNNEL_ENGINE`. Only fetched — and only non-null — when
  /// `envOverride` is non-null; the notice that reads it is not shown
  /// otherwise.
  final String? envVar;
}

/// A sentence-friendly name for an engine, for use inside the override notice.
String _engineDisplayName(AppLocalizations l10n, String engine) =>
    engine == 'gcloud'
        ? l10n.settingsAuthEngineNameGcloud
        : l10n.settingsAuthEngineNameNative;

/// One engine selector: the environment-override notice, the two radios, and
/// the error handling. Three of these exist; the logic lives here once.
class _EngineSelector extends StatefulWidget {
  const _EngineSelector({
    required this.slot,
    required this.title,
    required this.nativeLabel,
    required this.nativeSubtitle,
    required this.gcloudLabel,
    required this.gcloudSubtitle,
    this.footnote,
    this.onChanged,
  });

  final String slot;
  final String title;
  final String nativeLabel;
  final String nativeSubtitle;
  final String gcloudLabel;
  final String gcloudSubtitle;

  /// Shown under the radios when the choice has a caveat worth stating.
  final String? footnote;

  /// Ran after a successful change. Only the auth slot needs one: it decides
  /// which accounts and projects the rest of the UI is showing.
  final VoidCallback? onChanged;

  @override
  State<_EngineSelector> createState() => _EngineSelectorState();
}

class _EngineSelectorState extends State<_EngineSelector> {
  late Future<_EngineChoice> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_EngineChoice> _load() async {
    // The stored choice is what the selector shows, because it is what the
    // selector writes. `envOverride` is what the app is *actually* using when
    // the slot's environment variable outranks it — non-null only then.
    final envOverride = await engineOverride(slot: widget.slot);
    // The variable name is only meaningful — and only fetched — when there is
    // an override notice to put it in.
    final envVar =
        envOverride == null ? null : await engineEnvVar(slot: widget.slot);
    final selected =
        await storedEngine(slot: widget.slot) ?? await engineFor(slot: widget.slot);
    return _EngineChoice(selected: selected, envOverride: envOverride, envVar: envVar);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        FutureBuilder<_EngineChoice>(
          future: _future,
          builder: (context, snapshot) {
            final choice = snapshot.data;
            if (choice == null) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              );
            }
            final selected = choice.selected;
            Future<void> choose(String? value) async {
              if (value == null || value == selected) return;
              try {
                await setEngine(slot: widget.slot, engine: value);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.settingsAuthEngineChangeFailed(
                          localizedError(l10n, e, standalone: false))),
                    ),
                  );
                }
                return;
              }
              widget.onChanged?.call();
              if (mounted) {
                setState(() {
                  _future = Future.value(
                    _EngineChoice(
                      selected: value,
                      envOverride: choice.envOverride,
                      envVar: choice.envVar,
                    ),
                  );
                });
              }
            }
            return Column(children: [
              // The environment outranks the stored file by design — it
              // is the diagnostic escape hatch the hostile-environment QA
              // runs with. What must not happen is the radio moving with
              // nothing changing and nobody saying so.
              if (choice.envOverride != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber, size: 18, color: Colors.orange.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.settingsEngineEnvOverride(
                            choice.envVar!,
                            _engineDisplayName(l10n, choice.envOverride!),
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              RadioListTile<String>(
                value: 'native',
                groupValue: selected,
                onChanged: choose,
                title: Text(widget.nativeLabel),
                subtitle: Text(widget.nativeSubtitle),
              ),
              RadioListTile<String>(
                value: 'gcloud',
                groupValue: selected,
                onChanged: choose,
                title: Text(widget.gcloudLabel),
                subtitle: Text(widget.gcloudSubtitle),
              ),
              if (widget.footnote != null)
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
                  child: Text(
                    widget.footnote!,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
            ]);
          },
        ),
      ],
    );
  }
}

/// Helper function to show settings dialog
Future<void> showSettingsDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (context) => const SettingsDialog(),
  );
}
