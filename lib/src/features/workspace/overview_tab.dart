import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../../bridge/api.dart/rdp_client.dart';
import '../../bridge/api.dart/vnc_client.dart';
import '../app_error.dart';
import '../gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/vnc_display.dart';
import '../settings_provider.dart';
import '../database_connection_panel.dart';
import '../windows_credentials_dialog.dart';
import '../sshfs_mount_dialog.dart';
import '../snapshot_manager_dialog.dart';
import '../tunnel_manager_dialog.dart'
    show tunnelErrorDetailIsRedundant, tunnelErrorMessage;
import '../../services/storage_service.dart';
import 'workspace_provider.dart';

/// Helper: Get all active tunnels for a given instance.
///
/// Duplicated from `main.dart`'s (now-removed) top-level helper of the same
/// name: this was only ever used by the instance detail pane, which now
/// lives here as [OverviewTab].
List<MapEntry<String, TunnelState>> getTunnelsForInstance(
  Map<String, TunnelState> connections,
  String instanceName,
) {
  return connections.entries
      .where((entry) => entry.key.startsWith('$instanceName:'))
      .toList();
}

class OverviewTab extends ConsumerWidget {
  final ProjectAwareInstance target;
  const OverviewTab({super.key, required this.target});

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
  Widget build(BuildContext context, WidgetRef ref) {
    final connections = ref.watch(activeConnectionsProvider);
    final l10n = AppLocalizations.of(context);

    // Get project ID from the ProjectAwareInstance
    final selectedProject = target.projectId;
    final projectColor = _getProjectColor(selectedProject);

    // Get ALL tunnels for this instance
    final activeTunnels = getTunnelsForInstance(
      connections,
      target.name,
    );
    final isConnected = activeTunnels.any((t) => t.value.status == 'connected');
    final isConnecting = activeTunnels.any(
      (t) => t.value.status == 'connecting',
    );
    // final errorTunnels = activeTunnels.where((t) => t.value.error != null).toList();
    final isRunning = target.status == "RUNNING";
    final isSuspended = target.status == "SUSPENDED";

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.computer, size: 48, color: Colors.blueAccent),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    // Project indicator row
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: projectColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          selectedProject,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: Text(
                            target.machineType,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "${target.zone}  •  ${target.status}",
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Instance Resources Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.memory, size: 18, color: Colors.blue.shade700),
                    const SizedBox(width: 8),
                    Text(
                      l10n.dashboardInstanceResourcesTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _ResourceChip(
                        icon: Icons.developer_board,
                        label: l10n.dashboardCpuLabel,
                        value: target.cpuCount != null
                            ? l10n.dashboardVcpusValue(
                                target.cpuCount!,
                              )
                            : l10n.diagValueNa,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ResourceChip(
                        icon: Icons.memory,
                        label: l10n.dashboardRamLabel,
                        value: target.memoryMb != null
                            ? l10n.dashboardSizeGbValue(
                                (target.memoryMb! / 1024)
                                    .toStringAsFixed(1),
                              )
                            : l10n.diagValueNa,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ResourceChip(
                        icon: Icons.storage,
                        label: l10n.dashboardDiskLabel,
                        value: target.diskGb != null
                            ? l10n.diagSizeGb(target.diskGb!)
                            : l10n.diagValueNa,
                      ),
                    ),
                  ],
                ),
                // Addresses, when the VM has them. A VM reachable only through
                // IAP has no external one, and showing "N/A" for something it
                // is not supposed to have would read as a fault; the chip is
                // simply absent. With neither address there is no row at all.
                if (target.internalIp != null || target.externalIp != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (target.internalIp != null)
                        Expanded(
                          child: _ResourceChip(
                            icon: Icons.lan,
                            label: l10n.diagLabelInternalIp,
                            value: target.internalIp!,
                          ),
                        ),
                      if (target.internalIp != null && target.externalIp != null)
                        const SizedBox(width: 12),
                      if (target.externalIp != null)
                        Expanded(
                          child: _ResourceChip(
                            icon: Icons.public,
                            label: l10n.diagLabelExternalIp,
                            value: target.externalIp!,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // OS Login & Windows indicators
          if (target.osLoginEnabled || target.isWindows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (target.osLoginEnabled)
                    Chip(
                      avatar: Icon(
                        Icons.security,
                        size: 16,
                        color: Colors.green.shade700,
                      ),
                      label: Text(
                        l10n.dashboardOsLoginChip,
                        style: const TextStyle(fontSize: 12),
                      ),
                      backgroundColor: Colors.green.shade50,
                      visualDensity: VisualDensity.compact,
                    ),
                  if (target.isWindows)
                    Chip(
                      avatar: Icon(
                        Icons.desktop_windows,
                        size: 16,
                        color: Colors.blue.shade700,
                      ),
                      label: const Text(
                        'Windows',
                        style: TextStyle(fontSize: 12),
                      ),
                      backgroundColor: Colors.blue.shade50,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),

          // Labels section
          if (target.labels.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.label_outline,
                        size: 16,
                        color: Colors.grey.shade700,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.diagLabelsTitle,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: target.labels.map((label) {
                      return Chip(
                        label: Text(
                          '${label.$1}: ${label.$2}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          const SizedBox(height: 20),

          // Show all active tunnels for this instance
          if (activeTunnels.isNotEmpty) ...[
            Text(
              l10n.dashboardActiveTunnelsTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...activeTunnels.map((tunnelEntry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildTunnelDashboard(
                  context,
                  tunnelEntry.value,
                  tunnelEntry.key,
                  target.name,
                  ref,
                ),
              );
            }),
          ],

          const SizedBox(height: 32),
          Text(
            l10n.dashboardActionsTitle,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            _actionSectionHeader(context, l10n.dashboardActionsGroupAccess),
            Wrap(
              spacing: 16.0,
              runSpacing: 16.0,
              children: [
              _ActionButton(
                icon: Icons.desktop_windows,
                label: l10n.dashboardConnectRdpButton,
                onPressed: (isRunning && !isConnecting)
                    ? () async {
                        final settings = await _showConnectionSettingsDialog(
                          context,
                          target.name,
                          ref,
                        );
                        if (settings != null) {
                          final launched = await ref
                              .read(activeConnectionsProvider.notifier)
                              .launchRDP(
                                selectedProject,
                                target.zone,
                                target.name,
                                settings: settings,
                              );
                          if (!launched && context.mounted) {
                            await _showLaunchError(
                              context,
                              projectId: selectedProject,
                              target: target,
                              remotePort: 3389,
                              showLocalhostHint: false,
                              ref: ref,
                            );
                          }
                          // Add to connection history
                          ref
                              .read(connectionHistoryProvider.notifier)
                              .addEntry(
                                ConnectionHistoryEntry(
                                  instanceName: target.name,
                                  projectId: selectedProject,
                                  zone: target.zone,
                                  connectionType: 'rdp',
                                  timestamp: DateTime.now(),
                                ),
                              );
                        }
                      }
                    : null,
              ),
              _ActionButton(
                icon: Icons.remove_red_eye,
                label: l10n.dashboardConnectVncButton,
                backgroundColor: Colors.green.shade50,
                foregroundColor: Colors.green.shade700,
                onPressed: (isRunning && !isConnecting)
                    ? () async {
                        final chosen = await _showVncConnectionSettingsDialog(
                          context,
                          selectedProject,
                          target.zone,
                          target.name,
                          ref,
                        );
                        if (chosen != null) {
                          final launched = await ref
                              .read(activeConnectionsProvider.notifier)
                              .launchVNC(
                                selectedProject,
                                target.zone,
                                target.name,
                                settings: chosen.$1,
                                display: chosen.$2,
                              );
                          if (!launched && context.mounted) {
                            await _showLaunchError(
                              context,
                              projectId: selectedProject,
                              target: target,
                              remotePort: vncPortForDisplay(chosen.$2),
                              showLocalhostHint: true,
                              ref: ref,
                            );
                          }
                          // Add to connection history
                          ref
                              .read(connectionHistoryProvider.notifier)
                              .addEntry(
                                ConnectionHistoryEntry(
                                  instanceName: target.name,
                                  projectId: selectedProject,
                                  zone: target.zone,
                                  connectionType: 'vnc',
                                  timestamp: DateTime.now(),
                                ),
                              );
                        }
                      }
                    : null,
              ),
              _ActionButton(
                icon: Icons.terminal,
                label: l10n.dashboardConnectSshButton,
                onPressed: (!isRunning || isConnecting)
                    ? null
                    : () {
                        // Opens an embedded SSH terminal tab instead of an
                        // external terminal window (see workspace design doc).
                        ref.read(workspaceProvider.notifier).openSsh(target);
                        // Add to connection history
                        ref
                            .read(connectionHistoryProvider.notifier)
                            .addEntry(
                              ConnectionHistoryEntry(
                                instanceName: target.name,
                                projectId: selectedProject,
                                zone: target.zone,
                                connectionType: 'ssh',
                                timestamp: DateTime.now(),
                              ),
                            );
                      },
              ),
              _ActionButton(
                icon: Icons.folder_open,
                label: l10n.dashboardOpenSftpButton,
                onPressed: (!isRunning || isConnecting)
                    ? null
                    : () {
                        // Opens an embedded SFTP browser tab (which manages
                        // its own tunnel/username) instead of a dialog.
                        ref.read(workspaceProvider.notifier).openSftp(target);
                        // Add to connection history
                        ref
                            .read(connectionHistoryProvider.notifier)
                            .addEntry(
                              ConnectionHistoryEntry(
                                instanceName: target.name,
                                projectId: selectedProject,
                                zone: target.zone,
                                connectionType: 'sftp',
                                timestamp: DateTime.now(),
                              ),
                            );
                      },
              ),
              _ActionButton(
                icon: Icons.settings_ethernet,
                label: l10n.dashboardCustomTunnelButton,
                backgroundColor: Colors.purple.shade50,
                foregroundColor: Colors.purple.shade700,
                onPressed: (!isRunning || isConnecting)
                    ? null
                    : () async {
                        final choice = await _showCustomTunnelDialog(context);
                        if (choice == null || !context.mounted) return;
                        final messenger = ScaffoldMessenger.of(context);
                        final int? localPort;
                        if (choice.sshForward) {
                          localPort = await ref
                              .read(activeConnectionsProvider.notifier)
                              .connectSshForward(
                                  context,
                                  selectedProject, target.zone, target.name,
                                  remotePort: choice.port,
                                  localPort: choice.localPort);
                        } else {
                          localPort = await ref
                              .read(activeConnectionsProvider.notifier)
                              .connect(selectedProject, target.zone, target.name,
                                  remotePort: choice.port,
                                  localPort: choice.localPort);
                        }
                        if (!context.mounted) return;
                        if (localPort != null) {
                          final address = '127.0.0.1:$localPort';
                          final reused = choice.localPort != null &&
                              localPort != choice.localPort;
                          messenger.showSnackBar(SnackBar(
                            content: Text(reused
                                ? l10n.customTunnelReusedPort(
                                    address, choice.localPort!)
                                : l10n.customTunnelReady(address)),
                            duration: reused
                                ? const Duration(seconds: 6)
                                : const Duration(seconds: 4),
                            action: SnackBarAction(
                              label: l10n.commonCopy,
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: address));
                                messenger.showSnackBar(SnackBar(
                                    content: Text(
                                        l10n.customTunnelAddressCopied)));
                              },
                            ),
                          ));
                        } else {
                          final key = choice.sshForward
                              ? makeSshForwardKey(target.name, choice.port)
                              : makeTunnelKey(target.name, choice.port);
                          final failed =
                              ref.read(activeConnectionsProvider)[key];
                          await _showCustomTunnelError(
                            context,
                            error: failed?.error ?? '',
                            errorCode: failed?.errorCode,
                            projectId: selectedProject,
                            zone: target.zone,
                            instanceName: target.name,
                            // SSH forward is itself the localhost fix — don't show that hint.
                            showLocalhostHint: !choice.sshForward,
                            ref: ref,
                          );
                        }
                      },
              ),
              _ActionButton(
                icon: Icons.storage,
                label: l10n.dashboardDatabaseButton,
                backgroundColor: Colors.deepPurple.shade50,
                foregroundColor: Colors.deepPurple.shade700,
                onPressed: (isRunning && !isConnecting)
                    ? () {
                        showDatabaseConnectionPanel(
                          context,
                          projectId: selectedProject,
                          zone: target.zone,
                          instanceName: target.name,
                        );
                      }
                    : null,
              ),
              if (!Platform.isWindows)
                _ActionButton(
                  icon: Icons.folder_shared,
                  label: l10n.dashboardMenuMountSshfs,
                  backgroundColor: Colors.teal.shade50,
                  foregroundColor: Colors.teal.shade700,
                  onPressed: (isRunning && !isConnecting)
                      ? () async {
                          // Check for existing SSH tunnel (port 22)
                          final activeTunnels = getTunnelsForInstance(
                            connections,
                            target.name,
                          );
                          int? tunnelPort;

                          // Look for an existing SSH tunnel
                          for (final tunnel in activeTunnels) {
                            if (tunnel.value.remotePort == 22 &&
                                tunnel.value.status == 'connected') {
                              tunnelPort = tunnel.value.port;
                              break;
                            }
                          }

                          // If no SSH tunnel exists, create one
                          if (tunnelPort == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.dashboardCreatingSshTunnelSshfs,
                                ),
                              ),
                            );
                            final newPort = await ref
                                .read(activeConnectionsProvider.notifier)
                                .connect(
                                  selectedProject,
                                  target.zone,
                                  target.name,
                                  remotePort: 22,
                                );
                            if (newPort == null) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.dashboardSshfsTunnelFailed,
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                              return;
                            }
                            tunnelPort = newPort;
                          }

                          if (context.mounted && tunnelPort != null) {
                            showSshfsMountDialog(
                              context,
                              ref: ref,
                              projectId: selectedProject,
                              zone: target.zone,
                              instanceName: target.name,
                              tunnelPort: tunnelPort,
                            );
                          }
                        }
                      : null,
                ),
              _ActionButton(
                icon: Icons.vpn_key,
                label: l10n.winCredTitle,
                backgroundColor: Colors.blue.shade50,
                foregroundColor: Colors.blue.shade700,
                onPressed: (isRunning && !isConnecting)
                    ? () {
                        showWindowsCredentialsDialog(
                          context,
                          ref: ref,
                          projectId: selectedProject,
                          zone: target.zone,
                          instanceName: target.name,
                        );
                      }
                    : null,
              ),
              _ActionButton(
                icon: isConnected ? Icons.link_off : Icons.network_check,
                label: isConnected
                    ? l10n.dashboardDisconnectAllTunnelsButton
                    : l10n.dashboardTestIapConnectionButton,
                backgroundColor: isConnected
                    ? Colors.red.shade50
                    : Colors.blue.shade50,
                foregroundColor: isConnected
                    ? Colors.red
                    : Colors.blue.shade700,
                onPressed: (isConnecting)
                    ? null
                    : () async {
                        if (isConnected) {
                          await ref
                              .read(activeConnectionsProvider.notifier)
                              .disconnectAllForInstance(target.name);
                        } else {
                          // Test IAP connectivity
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.dashboardTestingIapConnection,
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                          ref
                              .read(activeConnectionsProvider.notifier)
                              .connect(
                                selectedProject,
                                target.zone,
                                target.name,
                              );
                        }
                      },
              ),
              ],
            ),
              const SizedBox(height: 20),
            _actionSectionHeader(context, l10n.dashboardActionsGroupPower),
            Wrap(
              spacing: 16.0,
              runSpacing: 16.0,
              children: [
              _ActionButton(
                icon: Icons.play_arrow,
                label: l10n.dashboardStartInstanceButton,
                backgroundColor: Colors.green.shade50,
                foregroundColor: Colors.green.shade700,
                onPressed: (isRunning || isConnecting)
                    ? null
                    : () async {
                        try {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.dashboardStartingInstanceProgress,
                              ),
                            ),
                          );
                          await ref
                              .read(activeConnectionsProvider.notifier)
                              .startInstanceWithMethod(
                                selectedProject,
                                target.zone,
                                target.name,
                              );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.clientTestInstanceStartedSuccess,
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.dashboardStartInstanceFailed(
                                    localizedError(l10n, e, standalone: false),
                                  ),
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
              _ActionButton(
                icon: Icons.stop,
                label: l10n.dashboardStopInstanceButton,
                backgroundColor: Colors.orange.shade50,
                foregroundColor: Colors.orange.shade700,
                onPressed: (!isRunning || isConnecting)
                    ? null
                    : () async {
                        final confirmed = await _showConfirmationDialog(
                          context,
                          title: l10n.dashboardStopInstanceButton,
                          message: l10n.dashboardStopInstanceConfirm(
                            target.name,
                          ),
                          confirmText: l10n.dashboardMenuStop,
                          isDestructive: true,
                        );
                        if (confirmed == true) {
                          try {
                            // Disconnect all tunnels first
                            await ref
                                .read(activeConnectionsProvider.notifier)
                                .disconnectAllForInstance(
                                  target.name,
                                );

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardStoppingInstanceProgress,
                                  ),
                                ),
                              );
                            }

                            await ref
                                .read(activeConnectionsProvider.notifier)
                                .stopInstanceWithMethod(
                                  selectedProject,
                                  target.zone,
                                  target.name,
                                );

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.clientTestInstanceStoppedSuccess,
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardStopInstanceFailed(
                                      localizedError(l10n, e, standalone: false),
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }
                      },
              ),
              _ActionButton(
                icon: Icons.restart_alt,
                label: l10n.dashboardResetInstanceButton,
                backgroundColor: Colors.red.shade50,
                foregroundColor: Colors.red.shade700,
                onPressed: (!isRunning || isConnecting)
                    ? null
                    : () async {
                        final confirmed = await _showConfirmationDialog(
                          context,
                          title: l10n.dashboardResetInstanceButton,
                          message: l10n.dashboardResetInstanceConfirm(
                            target.name,
                          ),
                          confirmText: l10n.dashboardMenuReset,
                          isDestructive: true,
                        );
                        if (confirmed == true) {
                          try {
                            // Disconnect all tunnels first
                            await ref
                                .read(activeConnectionsProvider.notifier)
                                .disconnectAllForInstance(
                                  target.name,
                                );

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardResettingInstanceProgress,
                                  ),
                                ),
                              );
                            }

                            await ref
                                .read(activeConnectionsProvider.notifier)
                                .resetInstanceWithMethod(
                                  selectedProject,
                                  target.zone,
                                  target.name,
                                );

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.clientTestInstanceResetSuccess,
                                  ),
                                ),
                              );
                              // Wait a bit before refreshing to allow GCP to update status
                              await Future.delayed(const Duration(seconds: 3));
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardResetInstanceFailed(
                                      localizedError(l10n, e, standalone: false),
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }
                      },
              ),
              _ActionButton(
                icon: Icons.pause_circle_outline,
                label: l10n.dashboardSuspendInstanceButton,
                backgroundColor: Colors.amber.shade50,
                foregroundColor: Colors.amber.shade800,
                onPressed: (!isRunning || isConnecting)
                    ? null
                    : () async {
                        final confirmed = await _showConfirmationDialog(
                          context,
                          title: l10n.dashboardSuspendInstanceButton,
                          message: l10n.dashboardSuspendInstanceConfirm(
                            target.name,
                          ),
                          confirmText: l10n.dashboardMenuSuspend,
                          isDestructive: false,
                        );
                        if (confirmed == true) {
                          try {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardSuspendingInstanceProgress,
                                  ),
                                ),
                              );
                            }

                            await ref
                                .read(activeConnectionsProvider.notifier)
                                .suspendInstanceWithMethod(
                                  selectedProject,
                                  target.zone,
                                  target.name,
                                );

                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardInstanceSuspendedSuccess,
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.dashboardSuspendInstanceFailed(
                                      localizedError(l10n, e, standalone: false),
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }
                      },
              ),
              _ActionButton(
                icon: Icons.play_circle_outline,
                label: l10n.dashboardResumeInstanceButton,
                backgroundColor: Colors.green.shade50,
                foregroundColor: Colors.green.shade700,
                onPressed: (!isSuspended || isConnecting)
                    ? null
                    : () async {
                        try {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.dashboardResumingInstanceProgress,
                              ),
                            ),
                          );
                          await ref
                              .read(activeConnectionsProvider.notifier)
                              .resumeInstanceWithMethod(
                                selectedProject,
                                target.zone,
                                target.name,
                              );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.dashboardInstanceResumedSuccess,
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.dashboardResumeInstanceFailed(
                                    localizedError(l10n, e, standalone: false),
                                  ),
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
              ],
            ),
              const SizedBox(height: 20),
            _actionSectionHeader(context, l10n.dashboardActionsGroupTools),
            Wrap(
              spacing: 16.0,
              runSpacing: 16.0,
              children: [
              _ActionButton(
                icon: Icons.build_circle_outlined,
                label: l10n.diagTabDiagnostics,
                backgroundColor: Colors.orange.shade50,
                foregroundColor: Colors.orange.shade700,
                onPressed: (true)
                    ? () {
                        ref
                            .read(workspaceProvider.notifier)
                            .openDiagnostics(target);
                      }
                    : null,
              ),
              _ActionButton(
                icon: Icons.medical_services_outlined,
                label: l10n.dashboardMenuDoctor,
                backgroundColor: Colors.teal.shade50,
                foregroundColor: Colors.teal.shade700,
                onPressed: (true)
                    ? () {
                        ref.read(workspaceProvider.notifier).openDoctor(target);
                      }
                    : null,
              ),
              _ActionButton(
                icon: Icons.camera_alt_outlined,
                label: l10n.snapshotTabList,
                backgroundColor: Colors.indigo.shade50,
                foregroundColor: Colors.indigo.shade700,
                onPressed: (true)
                    ? () {
                        showSnapshotManager(
                          context,
                          projectId: selectedProject,
                          zone: target.zone,
                          instanceName: target.name,
                        );
                      }
                    : null,
              ),
              ],
            ),
            ],
          ),

          if (isConnecting)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }

  /// Show Custom Tunnel Dialog to select port
  Future<({int port, bool sshForward, int? localPort})?> _showCustomTunnelDialog(
      BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    int? selectedPort;
    final customPortController = TextEditingController();
    final localPortController = TextEditingController();
    bool isCustomPort = false;
    bool sshForward = false;
    int? localPort;
    bool localPortValid = true; // empty is valid (auto)

    // Common service presets
    final Map<String, int> servicePresets = {
      'RDP (Remote Desktop)': 3389,
      'SSH': 22,
      'PostgreSQL': 5432,
      'MySQL/MariaDB': 3306,
      'HTTP': 8080,
      'HTTPS': 443,
      'MongoDB': 27017,
      'Redis': 6379,
    };

    if (!context.mounted) return null;

    try {
      return await showDialog<({int port, bool sshForward, int? localPort})>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.settings_ethernet, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(l10n.appCustomTunnelTitle),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                            value: false,
                            label: Text(l10n.customTunnelModeDirect)),
                        ButtonSegment(
                            value: true,
                            label: Text(l10n.customTunnelModeSshForward)),
                      ],
                      selected: {sshForward},
                      onSelectionChanged: (s) =>
                          setState(() => sshForward = s.first),
                    ),
                    if (sshForward) ...[
                      const SizedBox(height: 8),
                      Text(l10n.customTunnelSshForwardHint,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      l10n.appCustomTunnelDescription,
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),

                    // Service Preset Chips
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: servicePresets.entries.map((entry) {
                        final isSelected =
                            selectedPort == entry.value && !isCustomPort;
                        return ChoiceChip(
                          label: Text(
                            '${entry.key}\n:${entry.value}',
                            textAlign: TextAlign.center,
                          ),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                selectedPort = entry.value;
                                isCustomPort = false;
                                customPortController.clear();
                              } else {
                                selectedPort = null;
                              }
                            });
                          },
                          selectedColor: Colors.blue.shade100,
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: isSelected
                                ? Colors.blue.shade900
                                : Colors.black87,
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),

                    // Custom Port Input
                    TextField(
                      controller: customPortController,
                      decoration: InputDecoration(
                        labelText: l10n.appCustomPortLabel,
                        hintText: l10n.appCustomPortHint,
                        prefixIcon: const Icon(Icons.edit),
                        border: const OutlineInputBorder(),
                        filled: isCustomPort,
                        fillColor: isCustomPort ? Colors.blue.shade50 : null,
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (value) {
                        setState(() {
                          final port = int.tryParse(value);
                          if (port != null && port >= 1 && port <= 65535) {
                            selectedPort = port;
                            isCustomPort = true;
                          } else {
                            if (isCustomPort) selectedPort = null;
                          }
                        });
                      },
                    ),

                    const SizedBox(height: 12),
                    TextField(
                      controller: localPortController,
                      decoration: InputDecoration(
                        labelText: l10n.customTunnelLocalPortLabel,
                        hintText: l10n.customTunnelLocalPortHint,
                        prefixIcon: const Icon(Icons.dns_outlined),
                        border: const OutlineInputBorder(),
                        errorText: localPortValid ? null : l10n.appCustomPortHint,
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (value) {
                        setState(() {
                          if (value.isEmpty) {
                            localPort = null;
                            localPortValid = true;
                          } else {
                            final p = int.tryParse(value);
                            if (p != null && p >= 1 && p <= 65535) {
                              localPort = p;
                              localPortValid = true;
                            } else {
                              localPort = null;
                              localPortValid = false;
                            }
                          }
                        });
                      },
                    ),

                    if (selectedPort != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: Colors.green,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l10n.appSelectedPortLabel(selectedPort!),
                              style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: Text(l10n.commonCancel),
                ),
                ElevatedButton(
                  onPressed: (selectedPort == null || !localPortValid)
                      ? null
                      : () => Navigator.pop(context, (
                          port: selectedPort!,
                          sshForward: sshForward,
                          localPort: localPort,
                        )),
                  child: Text(l10n.commonConnect),
                ),
              ],
            );
          },
        );
      },
    );
    } finally {
      customPortController.dispose();
      localPortController.dispose();
    }
  }

  /// [error] is the untranslated detail from Rust; [errorCode] is the stable
  /// `TunnelError::code()`. Both are needed: the code alone cannot name the
  /// port, and the detail alone cannot say what went wrong — passing only the
  /// detail is what once rendered a bare port number as "Operation failed: 3000".
  Future<void> _showCustomTunnelError(
    BuildContext context, {
    required String error,
    required String? errorCode,
    required String projectId,
    required String zone,
    required String instanceName,
    required bool showLocalhostHint,
    required WidgetRef ref,
  }) async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      // Name the builder context `dialogContext` so it does not shadow the outer
      // `context`. The Doctor button pops the dialog (dialogContext) and then
      // opens the doctor on the still-mounted outer `context`.
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.customTunnelFailedTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(errorCode != null && errorCode.isNotEmpty
                  ? tunnelErrorMessage(l10n, errorCode, detail: error)
                  : localizedError(l10n, error)),
              if (showLocalhostHint &&
                  isBackendUnreachable(error, code: errorCode)) ...[
                const SizedBox(height: 12),
                Text(l10n.customTunnelLocalhostHint,
                    style: TextStyle(color: Colors.orange.shade900)),
              ],
              if (error.isNotEmpty &&
                  !tunnelErrorDetailIsRedundant(errorCode ?? '', error)) ...[
                const SizedBox(height: 12),
                SelectableText(error,
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace')),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(workspaceProvider.notifier).openDoctor(target);
            },
            child: Text(l10n.customTunnelRunDoctor),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  /// Say why pressing Connect on VNC or RDP produced no client.
  ///
  /// Two different failures reach here and they are not interchangeable. The
  /// tunnel itself may not exist — on 2026-10-01 a project with no firewall
  /// rule for 5900 failed this way four times in silence — and that gets the
  /// same dialog a custom tunnel gets. Or the tunnel is up and the client
  /// would not start, which is a passing annoyance rather than something to
  /// run the Doctor over.
  ///
  /// `showLocalhostHint` is on for VNC, where a `vncserver` bound to 127.0.0.1
  /// is unreachable through IAP and fails identically to a closed port. It is
  /// off for RDP: Windows RDP and a default xrdp listen on every interface,
  /// so there the hint would send the user looking in the wrong place when the
  /// answer is the firewall or RDP being disabled.
  Future<void> _showLaunchError(
    BuildContext context, {
    required String projectId,
    required ProjectAwareInstance target,
    required int remotePort,
    required bool showLocalhostHint,
    required WidgetRef ref,
  }) async {
    final key = makeTunnelKey(target.name, remotePort);
    final failed = ref.read(activeConnectionsProvider)[key];

    if (failed?.status == 'error') {
      await _showCustomTunnelError(
        context,
        error: failed?.error ?? '',
        errorCode: failed?.errorCode,
        projectId: projectId,
        zone: target.zone,
        instanceName: target.name,
        showLocalhostHint: showLocalhostHint,
        ref: ref,
      );
      return;
    }

    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(localizedError(l10n, failed?.error ?? '')),
      duration: const Duration(seconds: 6),
    ));
  }

  Future<RdpSettings?> _showConnectionSettingsDialog(
    BuildContext context,
    String instanceName,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context);
    final userController = TextEditingController();
    final passController = TextEditingController();
    final domainController = TextEditingController();
    bool fullscreen = false;
    bool saveCredentials = false;

    // Default resolution
    int width = 1920;
    int height = 1080;

    // Load saved credentials
    final saved = await StorageService().getRdpCredentials(instanceName);
    if (saved['username'] != null) {
      userController.text = saved['username']!;
      saveCredentials = true;
    }
    if (saved['password'] != null) passController.text = saved['password']!;
    if (saved['domain'] != null) domainController.text = saved['domain']!;

    if (!context.mounted) return null;

    return showDialog<RdpSettings>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(l10n.appConnectionSettingsTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: userController,
                      decoration: InputDecoration(
                        labelText: l10n.commonUsernameLabel,
                      ),
                    ),
                    TextField(
                      controller: passController,
                      decoration: InputDecoration(
                        labelText: l10n.winCredPasswordWord,
                      ),
                      obscureText: true,
                    ),
                    TextField(
                      controller: domainController,
                      decoration: InputDecoration(
                        labelText: l10n.appDomainOptionalLabel,
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      title: Text(l10n.appSaveCredentialsLabel),
                      value: saveCredentials,
                      onChanged: (val) =>
                          setState(() => saveCredentials = val ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(),
                    SwitchListTile(
                      title: Text(l10n.appFullscreenLabel),
                      value: fullscreen,
                      onChanged: (val) => setState(() => fullscreen = val),
                    ),
                    if (!fullscreen)
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue: width.toString(),
                              decoration: InputDecoration(
                                labelText: l10n.appWidthLabel,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (v) => width = int.tryParse(v) ?? 1920,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              initialValue: height.toString(),
                              decoration: InputDecoration(
                                labelText: l10n.appHeightLabel,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (v) =>
                                  height = int.tryParse(v) ?? 1080,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null), // Cancel
                  child: Text(l10n.commonCancel),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (saveCredentials) {
                      await StorageService().saveRdpCredentials(
                        instanceName: instanceName,
                        username: userController.text,
                        password: passController.text,
                        domain: domainController.text,
                      );
                    } else {
                      await StorageService().clearRdpCredentials(instanceName);
                    }

                    if (context.mounted) {
                      Navigator.pop(
                        context,
                        RdpSettings(
                          username: userController.text.isNotEmpty
                              ? userController.text
                              : null,
                          password: passController.text.isNotEmpty
                              ? passController.text
                              : null,
                          domain: domainController.text.isNotEmpty
                              ? domainController.text
                              : null,
                          fullscreen: fullscreen,
                          width: fullscreen ? null : width,
                          height: fullscreen ? null : height,
                          ignoreCertificate: false,
                          clientType: ref.read(rdpClientProvider),
                        ),
                      );
                    }
                  },
                  child: Text(l10n.commonConnect),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Returns the settings plus the VNC display the user chose, or null if
  /// they cancelled. The display is not part of `VncSettings` on purpose:
  /// Rust receives an already-resolved local port and has no use for it, so
  /// putting it there would mean changing the bridge for a UI concern.
  /// Returns the settings plus the VNC display the user chose, or null if
  /// they cancelled. The display is not part of `VncSettings` on purpose:
  /// Rust receives an already-resolved local port and has no use for it, so
  /// putting it there would mean changing the bridge for a UI concern.
  Future<(VncSettings, int)?> _showVncConnectionSettingsDialog(
    BuildContext context,
    String projectId,
    String zone,
    String instanceName,
    WidgetRef ref,
  ) async {
    if (!context.mounted) return null;
    return showDialog<(VncSettings, int)>(
      context: context,
      builder: (_) => VncConnectionSettingsDialog(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
      ),
    );
  }

  /// Build comprehensive tunnel status dashboard with metrics
  Widget _buildTunnelDashboard(
    BuildContext context,
    TunnelState tunnel,
    String tunnelKey,
    String instanceName,
    WidgetRef ref,
  ) {
    final l10n = AppLocalizations.of(context);
    // Determine health status color and icon
    final bool isHealthy = tunnel.status == 'connected' && tunnel.error == null;
    final bool isError = tunnel.status == 'error';
    final bool isReconnecting = tunnel.status == 'reconnecting';

    final Color statusColor;
    final Color bgColor;
    final Color borderColor;
    final IconData statusIcon;
    final String statusText;

    if (isReconnecting) {
      statusColor = Colors.orange;
      bgColor = Colors.orange.shade50;
      borderColor = Colors.orange.shade200;
      statusIcon = Icons.autorenew;
      statusText = l10n.tunnelStatusReconnecting;
    } else if (isError) {
      statusColor = Colors.red;
      bgColor = Colors.red.shade50;
      borderColor = Colors.red.shade200;
      statusIcon = Icons.error;
      statusText = l10n.dashboardTunnelUnhealthy;
    } else if (isHealthy) {
      statusColor = Colors.green;
      bgColor = Colors.green.shade50;
      borderColor = Colors.green.shade200;
      statusIcon = Icons.check_circle;
      statusText = l10n.tunnelStatusHealthy;
    } else {
      statusColor = Colors.orange;
      bgColor = Colors.orange.shade50;
      borderColor = Colors.orange.shade200;
      statusIcon = Icons.warning;
      statusText = l10n.dashboardTunnelDegraded;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with status
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          l10n.dashboardTunnelPortLabel(
                            '${tunnel.remotePort ?? "?"}',
                          ),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: statusColor.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Status badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isHealthy
                                    ? Icons.favorite
                                    : Icons.warning_amber,
                                size: 12,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                statusText,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (tunnel.port != null)
                      Text(
                        'localhost:${tunnel.port}',
                        style: TextStyle(
                          fontSize: 13,
                          color: statusColor.withValues(alpha: 0.7),
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
              // Disconnect button
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                tooltip: l10n.dashboardDisconnectTunnelTooltip,
                onPressed: () async {
                  await ref
                      .read(activeConnectionsProvider.notifier)
                      .disconnect(instanceName, tunnel.remotePort!);
                },
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Metrics Grid
          Row(
            children: [
              // Uptime metric
              Expanded(
                child: _MetricCard(
                  icon: Icons.schedule,
                  label: l10n.dashboardUptimeLabel,
                  value: tunnel.uptime(l10n),
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 12),
              // Last health check metric
              Expanded(
                child: _MetricCard(
                  icon: Icons.health_and_safety,
                  label: l10n.dashboardLastCheckLabel,
                  value: tunnel.lastCheckRelative(l10n),
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 12),
              // Latency metric
              Expanded(
                child: _MetricCard(
                  icon: Icons.speed,
                  label: l10n.dashboardLatencyLabel,
                  value: tunnel.latencyMs != null
                      ? '${tunnel.latencyMs}ms'
                      : l10n.diagValueNa,
                  color: tunnel.latencyMs != null
                      ? (tunnel.latencyMs! < 50
                            ? Colors.green
                            : (tunnel.latencyMs! < 200
                                  ? Colors.orange
                                  : Colors.red))
                      : Colors.grey,
                ),
              ),
            ],
          ),

          // Reconnection progress (if reconnecting)
          if (isReconnecting) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.dashboardAttemptLabel(
                        tunnel.reconnectAttempts + 1,
                        tunnel.maxReconnectAttempts,
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      ref
                          .read(activeConnectionsProvider.notifier)
                          .retryConnection(tunnelKey);
                    },
                    child: Text(
                      l10n.tunnelRetryNow,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Retry button for error state
          if (isError && tunnel.projectId != null && tunnel.zone != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(l10n.dashboardRetryConnectionButton),
                onPressed: () {
                  ref
                      .read(activeConnectionsProvider.notifier)
                      .retryConnection(tunnelKey);
                },
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Monitoring info
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.autorenew,
                  size: 14,
                  color: Colors.black.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.dashboardAutoMonitoringLabel(
                      tunnel.autoReconnectEnabled
                          ? l10n.dashboardOnState
                          : l10n.dashboardOffState,
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.black.withValues(alpha: 0.6),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showConfirmationDialog(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmText,
    bool isDestructive = false,
  }) async {
    final l10n = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                isDestructive ? Icons.warning : Icons.help_outline,
                color: isDestructive ? Colors.orange : Colors.blue,
              ),
              const SizedBox(width: 8),
              Text(title),
            ],
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: isDestructive ? Colors.red : Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: Text(confirmText),
            ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color.withValues(alpha: 0.7)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.black.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ResourceChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

/// Secondary header above a group of action buttons in the Overview tab.
/// Deliberately quieter than the "Actions" title so it groups without competing.
Widget _actionSectionHeader(BuildContext context, String label) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      label,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final button = ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
    return button;
  }
}

/// The VNC connection dialog, as a widget rather than a closure inside a
/// method.
///
/// Public and standalone so a test can render it: `es_overflow_test` lays out
/// every screen it can reach, and a dialog that only exists inside a private
/// method is a dialog that suite never sees. Two screens were found
/// overflowing in Spanish on 2026-09-30 for exactly that reason.
class VncConnectionSettingsDialog extends ConsumerStatefulWidget {
  const VncConnectionSettingsDialog({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  final String projectId;
  final String zone;
  final String instanceName;

  @override
  ConsumerState<VncConnectionSettingsDialog> createState() =>
      _VncConnectionSettingsDialogState();
}

class _VncConnectionSettingsDialogState
    extends ConsumerState<VncConnectionSettingsDialog> {
  final TextEditingController passController = TextEditingController();
  late final TextEditingController displayController;
  bool fullscreen = false;
  bool viewOnly = false;
  VncQuality quality = VncQuality.auto;
  int width = 1920;
  int height = 1080;

  @override
  void initState() {
    super.initState();
    // Prefilled with what this VM used last time, so the number is typed once
    // per VM rather than once per connection.
    //
    // initState runs the instant the dialog opens, which can be before the
    // stored displays have been read: the raw state then says 0 for a VM saved
    // on :1, and a user who accepts the field would save the 0 believing they
    // chose it. So fill in what is known now and correct it when the read
    // lands — unless the user has already typed something of their own.
    final vmKey = vncVmKey(widget.projectId, widget.zone, widget.instanceName);
    final prefilled =
        vncDisplayFor(ref.read(vncDisplayProvider), vmKey).toString();
    displayController = TextEditingController(text: prefilled);
    // NOT COVERED BY ANY TEST (checked by mutation): dropping the
    // `== prefilled` guard, so the correction overwrites a number the user
    // already typed, leaves every test green. The window is the few
    // milliseconds the preferences read takes, too short for a test without
    // injecting a delayed preferences store, and for a person to type in.
    unawaited(
        ref.read(vncDisplayProvider.notifier).displayFor(vmKey).then((stored) {
      if (mounted && displayController.text == prefilled) {
        displayController.text = '$stored';
      }
    }));
  }

  @override
  void dispose() {
    passController.dispose();
    displayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.remove_red_eye, color: Colors.green),
          const SizedBox(width: 8),
          // Flexible because the Spanish title is long enough to push the row
          // 136 px past a 720 px window. A Text in a Row takes its intrinsic
          // width and never wraps on its own.
          Flexible(child: Text(l10n.appVncConnectionSettingsTitle)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: displayController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.appVncDisplayLabel,
                // The port is shown, not hidden: the display is what
                // you typed when you started the server, the port is
                // what everything below this dialog works in, and
                // seeing both is how you notice you meant the other.
                helperText: parseVncDisplay(displayController.text) !=
                        null
                    ? l10n.appVncDisplayHelper(
                        parseVncDisplay(displayController.text)!,
                        vncPortForDisplay(
                            parseVncDisplay(displayController.text)!),
                      )
                    : l10n.appVncDisplayInvalid(1, 5901),
                errorText: parseVncDisplay(displayController.text) ==
                        null
                    ? l10n.appVncDisplayInvalid(1, 5901)
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passController,
              decoration: InputDecoration(
                labelText: l10n.appPasswordOptionalLabel,
                helperText: l10n.appVncPasswordHelper,
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            const Divider(),
            Text(
              l10n.appDisplayOptionsLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(l10n.appFullscreenLabel),
              value: fullscreen,
              onChanged: (val) => setState(() => fullscreen = val),
            ),
            if (!fullscreen)
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: width.toString(),
                      decoration: InputDecoration(
                        labelText: l10n.appWidthLabel,
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => width = int.tryParse(v) ?? 1920,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      initialValue: height.toString(),
                      decoration: InputDecoration(
                        labelText: l10n.appHeightLabel,
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (v) =>
                          height = int.tryParse(v) ?? 1080,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text(l10n.appViewOnlyLabel),
              subtitle: Text(
                l10n.appViewOnlyHelper,
                style: const TextStyle(fontSize: 12),
              ),
              value: viewOnly,
              onChanged: (val) => setState(() => viewOnly = val),
            ),
            const SizedBox(height: 8),
            const Divider(),
            Text(
              l10n.appQualityLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<VncQuality>(
              value: quality,
              decoration: InputDecoration(
                labelText: l10n.appConnectionQualityLabel,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: VncQuality.auto,
                  child: Text(l10n.appQualityAuto),
                ),
                DropdownMenuItem(
                  value: VncQuality.high,
                  child: Text(l10n.appQualityHigh),
                ),
                DropdownMenuItem(
                  value: VncQuality.medium,
                  child: Text(l10n.appQualityMedium),
                ),
                DropdownMenuItem(
                  value: VncQuality.low,
                  child: Text(l10n.appQualityLow),
                ),
              ],
              onChanged: (val) =>
                  setState(() => quality = val ?? VncQuality.auto),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null), // Cancel
          child: Text(l10n.commonCancel),
        ),
        ElevatedButton(
          // Disabled rather than validated on press: an unreachable
          // Connect button says "fix that field" without a second
          // error message to dismiss.
          onPressed: parseVncDisplay(displayController.text) == null
              ? null
              : () async {
                  if (context.mounted) {
                    Navigator.pop(
                      context,
                      (
                        VncSettings(
                          password: passController.text.isNotEmpty
                              ? passController.text
                              : null,
                          fullscreen: fullscreen,
                          width: fullscreen ? null : width,
                          height: fullscreen ? null : height,
                          viewOnly: viewOnly,
                          quality: quality,
                          clientType: ref.read(vncClientProvider),
                        ),
                        parseVncDisplay(displayController.text)!,
                      ),
                    );
                  }
                },
          child: Text(l10n.commonConnect),
        ),
      ],
    );
  }
}
