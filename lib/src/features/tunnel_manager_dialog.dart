import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_error.dart';
import 'gcloud_provider.dart';
import '../bridge/api.dart/api.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

/// Map a Rust `TunnelError::code()` to a localized message.
///
/// Unknown codes fall back to the generic message so a new Rust error can never
/// surface a raw identifier to the user.
///
/// [detail] is the untranslated payload from `TunnelError::detail()`. Codes that
/// carry a port use it to name that port; without it they degrade to the
/// portless wording rather than leaking the raw value.
String tunnelErrorMessage(AppLocalizations l10n, String code, {String? detail}) {
  switch (code) {
    case 'not_authenticated':
      return l10n.tunnelErrorNotAuthenticated;
    case 'permission_denied':
      return l10n.tunnelErrorPermissionDenied;
    case 'instance_not_found':
      return l10n.tunnelErrorInstanceNotFound;
    case 'instance_not_running':
      return l10n.tunnelErrorInstanceNotRunning;
    case 'firewall_blocked':
      return l10n.tunnelErrorFirewallBlocked;
    case 'relay_unreachable':
      return l10n.tunnelErrorRelayUnreachable;
    case 'protocol_error':
      return l10n.tunnelErrorProtocolError;
    // Raised after the fact, not on connect: the tunnel worked and then the
    // session under it died. The wording says so, because "could not establish"
    // would send the user looking for a setup problem that never existed.
    case 'session_lost':
      return l10n.tunnelErrorSessionLost;
    case 'backend_unreachable':
      final port = _portFrom(detail);
      return port != null
          ? l10n.tunnelErrorBackendUnreachable(port)
          : l10n.tunnelErrorRelayUnreachable;
    case 'local_port_unavailable':
      // Port 0 means "no ephemeral port could be bound at all", which the
      // portless wording describes; a real port means that specific one is
      // taken, and saying which is the whole point.
      final port = _portFrom(detail);
      return port != null
          ? l10n.tunnelErrorLocalPortInUse(port)
          : l10n.tunnelErrorLocalPortUnavailable;
    default:
      return l10n.tunnelErrorUnknown;
  }
}

/// The tag naming the engine used for a tunnel — holding it, or the one that
/// failed to start it — or null when there is none to show: no engine ran, or
/// it is one this build does not know, which must never reach the screen as a
/// raw identifier.
///
/// Worded as Settings words the choice, not as the log spells it: the tag
/// answers "which of my two options is carrying this?".
String? tunnelEngineLabel(AppLocalizations l10n, String? engine) {
  switch (engine) {
    case 'native':
      return l10n.tunnelEngineNative;
    case 'gcloud':
      return l10n.tunnelEngineGcloud;
    default:
      return null;
  }
}

/// The port named by an error's detail payload, or null when it names none.
String? _portFrom(String? detail) {
  final port = int.tryParse(detail?.trim() ?? '');
  return (port != null && port > 0) ? port.toString() : null;
}

/// Codes whose detail is just a port number.
const _portCarryingCodes = {'backend_unreachable', 'local_port_unavailable'};

/// Whether [detail] still says anything once [code]'s message has been shown.
///
/// The port-carrying codes now name the port in the message itself, so echoing
/// the bare number underneath is exactly the noise users saw as
/// "Operation failed: 3000" followed by "3000".
bool tunnelErrorDetailIsRedundant(String code, String? detail) =>
    _portCarryingCodes.contains(code) && _portFrom(detail) != null;

/// Show the Tunnel Manager Dialog
void showTunnelManagerDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const TunnelManagerDialog(),
  );
}

class TunnelManagerDialog extends ConsumerStatefulWidget {
  const TunnelManagerDialog({super.key});

  @override
  ConsumerState<TunnelManagerDialog> createState() => _TunnelManagerDialogState();
}

class _TunnelManagerDialogState extends ConsumerState<TunnelManagerDialog> {
  bool _isCleaningUp = false;

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(tunnelStatsProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(Icons.lan, color: theme.colorScheme.primary, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    l10n.tunnelManagerTitle,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  if (stats.totalTunnels > 0)
                    Badge(
                      label: Text('${stats.totalTunnels}'),
                      child: const SizedBox.shrink(),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Summary chips
              if (stats.totalTunnels > 0) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SummaryChip(
                      label: l10n.tunnelTotalCount(stats.totalTunnels),
                      color: theme.colorScheme.primary,
                      icon: Icons.lan,
                    ),
                    _SummaryChip(
                      label: l10n.tunnelHealthyCount(stats.healthyCount),
                      color: Colors.green,
                      icon: Icons.check_circle,
                    ),
                    if (stats.errorCount > 0)
                      _SummaryChip(
                        label: l10n.tunnelErrorCount(stats.errorCount),
                        color: Colors.red,
                        icon: Icons.error,
                      ),
                    if (stats.reconnectingCount > 0)
                      _SummaryChip(
                        label: l10n.tunnelReconnectingCount(stats.reconnectingCount),
                        color: Colors.orange,
                        icon: Icons.autorenew,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
              ],

              // Tunnel list
              Flexible(
                child: stats.totalTunnels == 0
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lan_outlined, size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Text(
                              l10n.tunnelNoActiveTunnels,
                              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.tunnelConnectPrompt,
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: stats.allTunnels.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = stats.allTunnels[index];
                          return _TunnelCard(
                            tunnelKey: entry.key,
                            tunnel: entry.value,
                          );
                        },
                      ),
              ),

              // Actions
              if (stats.totalTunnels > 0) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // The two actions wrap onto a second line when they do not
                    // fit — in Spanish they never did — and Close stays put on
                    // the right. A plain Row overflowed as soon as the manager
                    // had a tunnel to show.
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.power_off, size: 18),
                            label: Text(l10n.tunnelDisconnectAll),
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(l10n.tunnelDisconnectAllTitle),
                                  content: Text(l10n.tunnelDisconnectAllConfirm(stats.totalTunnels)),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                      child: Text(l10n.tunnelDisconnectAll),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true && context.mounted) {
                                await ref.read(activeConnectionsProvider.notifier).disconnectAll();
                              }
                            },
                          ),
                          OutlinedButton.icon(
                            icon: _isCleaningUp
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.cleaning_services, size: 18),
                            label: Text(l10n.tunnelCleanupZombies),
                            onPressed: _isCleaningUp
                                ? null
                                : () async {
                                    setState(() => _isCleaningUp = true);
                                    try {
                                      final cleaned = await cleanupDeadConnections();
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(cleaned.isEmpty
                                                ? l10n.tunnelNoZombiesFound
                                                : l10n.tunnelCleanedUpZombies(cleaned.length)),
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              l10n.tunnelCleanupFailed(
                                                localizedError(l10n, e, standalone: false),
                                              ),
                                            ),
                                          ),
                                        );
                                      }
                                    } finally {
                                      if (mounted) setState(() => _isCleaningUp = false);
                                    }
                                  },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.commonClose),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Individual tunnel card in the manager
class _TunnelCard extends ConsumerWidget {
  final String tunnelKey;
  final TunnelState tunnel;

  const _TunnelCard({required this.tunnelKey, required this.tunnel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final parsed = parseTunnelKey(tunnelKey);
    final instanceName = parsed?.$1 ?? tunnelKey;
    final remotePort = parsed?.$2 ?? 0;

    final engineLabel = tunnelEngineLabel(l10n, tunnel.engine);

    final isHealthy = tunnel.status == 'connected' && tunnel.error == null;
    final isError = tunnel.status == 'error';
    final isReconnecting = tunnel.status == 'reconnecting';

    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (isReconnecting) {
      statusColor = Colors.orange;
      statusIcon = Icons.autorenew;
      statusText = l10n.tunnelStatusReconnecting;
    } else if (isError) {
      statusColor = Colors.red;
      statusIcon = Icons.error;
      statusText = l10n.commonError;
    } else if (isHealthy) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusText = l10n.tunnelStatusHealthy;
    } else {
      statusColor = Colors.grey;
      statusIcon = Icons.help_outline;
      statusText = tunnel.status;
    }

    // Latency color
    Color? latencyColor;
    if (tunnel.latencyMs != null) {
      if (tunnel.latencyMs! < 50) {
        latencyColor = Colors.green;
      } else if (tunnel.latencyMs! < 200) {
        latencyColor = Colors.orange;
      } else {
        latencyColor = Colors.red;
      }
    }

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Instance name + ports + status badge
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              instanceName,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isSshForwardKey(tunnelKey)) ...[
                            const SizedBox(width: 6),
                            _Tag(label: l10n.tunnelKindSshForward, shades: Colors.teal),
                          ],
                          // Identity, not a measurement: it belongs beside the
                          // name, in a neutral grey that competes with neither
                          // the status colour nor the forward tag.
                          if (engineLabel != null) ...[
                            const SizedBox(width: 6),
                            Tooltip(
                              message: l10n.tunnelEngineTooltip,
                              child: _Tag(label: engineLabel, shades: Colors.grey),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        ':$remotePort -> localhost:${tunnel.port ?? "?"}',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    statusText,
                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Metrics row: latency, uptime, last check, reconnect attempts
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (tunnel.latencyMs != null)
                  _MiniMetric(
                    icon: Icons.speed,
                    label: '${tunnel.latencyMs}ms',
                    color: latencyColor!,
                  ),
                _MiniMetric(
                  icon: Icons.schedule,
                  label: tunnel.uptime(l10n),
                  color: Colors.grey.shade600,
                ),
                _MiniMetric(
                  icon: Icons.health_and_safety,
                  label: tunnel.lastCheckRelative(l10n),
                  color: Colors.grey.shade600,
                ),
                if (isReconnecting)
                  _MiniMetric(
                    icon: Icons.replay,
                    label: '${tunnel.reconnectAttempts}/${tunnel.maxReconnectAttempts}',
                    color: Colors.orange,
                  ),
              ],
            ),

            if (isError) ...[
              const SizedBox(height: 6),
              Text(
                tunnelErrorMessage(l10n, tunnel.errorCode ?? '',
                    detail: tunnel.error),
                style: TextStyle(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w500),
              ),
              if (tunnel.error != null &&
                  tunnel.error!.isNotEmpty &&
                  !tunnelErrorDetailIsRedundant(
                      tunnel.errorCode ?? '', tunnel.error))
                Text(
                  tunnel.error!,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],

            const SizedBox(height: 8),

            // Actions row
            Row(
              children: [
                // Auto-reconnect toggle (hidden for SSH forwards — they are
                // not health-checked/auto-reconnected).
                if (!isSshForwardKey(tunnelKey))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.tunnelAutoReconnect,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    SizedBox(
                      height: 28,
                      child: Switch(
                        value: tunnel.autoReconnectEnabled,
                        onChanged: (value) {
                          ref.read(activeConnectionsProvider.notifier)
                              .setAutoReconnect(tunnelKey, value);
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                // Retry and Disconnect take what the toggle leaves and wrap
                // onto a second line when they do not fit — on an errored
                // row in Spanish they never did. Right-aligned, as the Spacer
                // had them.
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    children: [
                      // Retry button (for error state) — not for SSH forwards, which
                      // would spuriously retry via the IAP path.
                      if (isError && !isSshForwardKey(tunnelKey))
                        TextButton.icon(
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(l10n.tunnelRetryNow, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            ref.read(activeConnectionsProvider.notifier).retryConnection(tunnelKey);
                          },
                        ),
                      // Disconnect button
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 16, color: Colors.red),
                        label: Text(l10n.commonDisconnect, style: const TextStyle(fontSize: 12, color: Colors.red)),
                        onPressed: () async {
                          // Route by full key so an SSH forward (sshfwd:…) is stopped
                          // via stopSshForward, not the IAP stopConnection.
                          await ref.read(activeConnectionsProvider.notifier)
                              .disconnectByKey(tunnelKey);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A small outlined label on a tunnel's identity line.
class _Tag extends StatelessWidget {
  final String label;
  final MaterialColor shades;

  const _Tag({required this.label, required this.shades});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: shades.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: shades.shade200),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: shades.shade800,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Summary chip widget
class _SummaryChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _SummaryChip({required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}

/// Mini metric display
class _MiniMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MiniMetric({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}
