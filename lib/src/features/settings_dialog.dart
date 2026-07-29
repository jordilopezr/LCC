import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'gcloud_provider.dart';
import 'settings_provider.dart';
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
                        Row(
                          children: [
                            _buildEditionChip(l10n.commonEditionLabel(kEdition)),
                            const SizedBox(width: 8),
                            if (kUpdate > 0) ...[
                              _buildEditionChip(
                                  l10n.commonUpdateLabel(kUpdate.toString())),
                              const SizedBox(width: 8),
                            ],
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
      error: (err, stack) => Text(l10n.settingsErrorDetectingRdp('$err'), style: const TextStyle(fontSize: 12)),
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
      error: (err, stack) => Text(l10n.settingsErrorDetectingVnc('$err'), style: const TextStyle(fontSize: 12)),
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
        child: Text(l10n.settingsErrorCheckingDeps('$err'), style: const TextStyle(fontSize: 12)),
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
      case RdpClientType.mstsc:
        return l10n.settingsRdpDescMstsc;
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
      case RdpClientType.mstsc:
        return Icons.window;
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

/// Helper function to show settings dialog
Future<void> showSettingsDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (context) => const SettingsDialog(),
  );
}
