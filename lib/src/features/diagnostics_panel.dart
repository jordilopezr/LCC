import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/diagnostics.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

/// Parameters for the diagnostics panel
class DiagnosticsParams {
  final String projectId;
  final String zone;
  final String instanceName;

  const DiagnosticsParams({
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });
}

/// Main diagnostics panel dialog
class DiagnosticsPanel extends ConsumerStatefulWidget {
  final DiagnosticsParams params;

  const DiagnosticsPanel({super.key, required this.params});

  @override
  ConsumerState<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends ConsumerState<DiagnosticsPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 700,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.build_circle_outlined, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.diagTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          l10n.diagSubtitle(
                            widget.params.instanceName,
                            widget.params.zone,
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Tab bar
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(icon: const Icon(Icons.terminal), text: l10n.diagTabSerialConsole),
                Tab(icon: const Icon(Icons.info_outline), text: l10n.diagTabDiagnostics),
                Tab(icon: const Icon(Icons.history), text: l10n.diagTabAuditLogs),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  SerialConsoleTab(params: widget.params),
                  VmDiagnosticsTab(params: widget.params),
                  AuditLogsTab(params: widget.params),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SERIAL CONSOLE TAB
// ============================================================

class SerialConsoleTab extends ConsumerStatefulWidget {
  final DiagnosticsParams params;

  const SerialConsoleTab({super.key, required this.params});

  @override
  ConsumerState<SerialConsoleTab> createState() => _SerialConsoleTabState();
}

class _SerialConsoleTabState extends ConsumerState<SerialConsoleTab> {
  SerialPortOutput? _output;
  bool _isLoading = false;
  String? _error;
  int _selectedPort = 1;
  bool _autoRefresh = false;
  Timer? _autoRefreshTimer;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _fetchSerialOutput();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchSerialOutput({int? start}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final output = await getSerialOutput(
        projectId: widget.params.projectId,
        zone: widget.params.zone,
        instanceName: widget.params.instanceName,
        port: _selectedPort,
        start: start,
      );

      setState(() {
        _output = output;
        _isLoading = false;
      });

      // Auto-scroll to bottom if enabled
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _toggleAutoRefresh() {
    setState(() {
      _autoRefresh = !_autoRefresh;
    });

    if (_autoRefresh) {
      _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _fetchSerialOutput(start: _output?.next.toInt());
      });
    } else {
      _autoRefreshTimer?.cancel();
    }
  }

  Future<void> _exportLogs() async {
    if (_output == null) return;

    try {
      final directory = await getDownloadsDirectory() ?? await getTemporaryDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final safeInstanceName = widget.params.instanceName
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final filename = 'serial_${safeInstanceName}_$timestamp.txt';
      final file = File('${directory.path}/$filename');

      await file.writeAsString(_output!.contents);

      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.diagLogsExportedTo(file.path)),
            action: SnackBarAction(
              label: l10n.diagOpenAction,
              onPressed: () {
                // Open file manager at location
                Process.run('xdg-open', [directory.path]);
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.diagExportFailed(e.toString()))),
        );
      }
    }
  }

  List<String> _getFilteredLines() {
    if (_output == null) return [];
    final lines = _output!.contents.split('\n');
    if (_searchQuery.isEmpty) return lines;
    return lines.where((line) =>
      line.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: Row(
            children: [
              // Port selector
              Text(l10n.diagPortLabel),
              DropdownButton<int>(
                value: _selectedPort,
                items: [1, 2, 3, 4].map((port) =>
                  DropdownMenuItem(
                    value: port,
                    child: Text('COM$port'),
                  ),
                ).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedPort = value);
                    _fetchSerialOutput();
                  }
                },
              ),

              const SizedBox(width: 16),

              // Search
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: l10n.diagSearchHint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),

              const SizedBox(width: 8),

              // Auto-scroll toggle
              Tooltip(
                message: l10n.diagAutoScrollTooltip,
                child: IconButton(
                  icon: Icon(
                    _autoScroll ? Icons.vertical_align_bottom : Icons.vertical_align_center,
                    color: _autoScroll ? Theme.of(context).colorScheme.primary : null,
                  ),
                  onPressed: () => setState(() => _autoScroll = !_autoScroll),
                ),
              ),

              // Auto-refresh toggle
              Tooltip(
                message: _autoRefresh ? l10n.diagStopAutoRefreshTooltip : l10n.diagAutoRefreshTooltip,
                child: IconButton(
                  icon: Icon(
                    _autoRefresh ? Icons.pause_circle_outline : Icons.play_circle_outline,
                    color: _autoRefresh ? Colors.green : null,
                  ),
                  onPressed: _toggleAutoRefresh,
                ),
              ),

              // Manual refresh
              Tooltip(
                message: l10n.commonRefresh,
                child: IconButton(
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: _isLoading ? null : () => _fetchSerialOutput(),
                ),
              ),

              // Export
              Tooltip(
                message: l10n.diagExportLogsTooltip,
                child: IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: _output != null ? _exportLogs : null,
                ),
              ),

              // Copy all
              Tooltip(
                message: l10n.diagCopyToClipboardTooltip,
                child: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: _output != null
                      ? () {
                          Clipboard.setData(ClipboardData(text: _output!.contents));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.diagCopiedToClipboard)),
                          );
                        }
                      : null,
                ),
              ),
            ],
          ),
        ),

        // Content
        Expanded(
          child: _buildContent(),
        ),

        // Footer
        if (_output != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.diagFetchedAt(_output!.fetchedAt.substring(0, 19)),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  _searchQuery.isNotEmpty
                      ? l10n.diagLinesCountFiltered(_getFilteredLines().length)
                      : l10n.diagLinesCount(_getFilteredLines().length),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildContent() {
    final l10n = AppLocalizations.of(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
              const SizedBox(height: 16),
              Text(
                _error!.contains('SERIAL_PORT_DISABLED')
                    ? l10n.diagSerialPortDisabledTitle
                    : l10n.diagErrorLoadingSerialTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (_error!.contains('SERIAL_PORT_DISABLED'))
                ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(
                      text: 'gcloud compute instances add-metadata INSTANCE --zone=ZONE --metadata=serial-port-logging-enable=TRUE',
                    ));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.diagCommandCopiedToClipboard)),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: Text(l10n.diagCopyEnableCommandButton),
                ),
            ],
          ),
        ),
      );
    }

    if (_isLoading && _output == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_output == null) {
      return Center(child: Text(l10n.diagNoData));
    }

    final lines = _getFilteredLines();

    return Container(
      color: Colors.black87,
      child: SelectableText.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Colors.greenAccent,
          ),
          children: lines.map((line) {
            // Highlight search matches
            if (_searchQuery.isNotEmpty) {
              final lowerLine = line.toLowerCase();
              final lowerQuery = _searchQuery.toLowerCase();
              final matchIndex = lowerLine.indexOf(lowerQuery);

              if (matchIndex >= 0) {
                return TextSpan(children: [
                  TextSpan(text: line.substring(0, matchIndex)),
                  TextSpan(
                    text: line.substring(matchIndex, matchIndex + _searchQuery.length),
                    style: const TextStyle(
                      backgroundColor: Colors.yellow,
                      color: Colors.black,
                    ),
                  ),
                  TextSpan(text: '${line.substring(matchIndex + _searchQuery.length)}\n'),
                ]);
              }
            }
            return TextSpan(text: '$line\n');
          }).toList(),
        ),
        scrollPhysics: const AlwaysScrollableScrollPhysics(),
      ),
    );
  }
}

// ============================================================
// VM DIAGNOSTICS TAB
// ============================================================

class VmDiagnosticsTab extends ConsumerStatefulWidget {
  final DiagnosticsParams params;

  const VmDiagnosticsTab({super.key, required this.params});

  @override
  ConsumerState<VmDiagnosticsTab> createState() => _VmDiagnosticsTabState();
}

class _VmDiagnosticsTabState extends ConsumerState<VmDiagnosticsTab> {
  VmDiagnostics? _diagnostics;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchDiagnostics();
  }

  Future<void> _fetchDiagnostics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final diagnostics = await getInstanceDiagnostics(
        projectId: widget.params.projectId,
        zone: widget.params.zone,
        instanceName: widget.params.instanceName,
      );

      setState(() {
        _diagnostics = diagnostics;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
            const SizedBox(height: 16),
            Text(l10n.commonErrorPrefix(_error!)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchDiagnostics,
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      );
    }

    if (_diagnostics == null) {
      return Center(child: Text(l10n.diagNoData));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Refresh button
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: _fetchDiagnostics,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRefresh),
              ),
            ],
          ),

          // Status card
          _buildStatusCard(),

          const SizedBox(height: 16),

          // Guest Agent card
          _buildGuestAgentCard(),

          const SizedBox(height: 16),

          // Network interfaces card
          _buildNetworkCard(),

          const SizedBox(height: 16),

          // Disks card
          _buildDisksCard(),

          const SizedBox(height: 16),

          // Labels card
          if (_diagnostics!.labels.isNotEmpty) _buildLabelsCard(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final l10n = AppLocalizations.of(context);
    final d = _diagnostics!;
    final statusColor = d.status == 'RUNNING'
        ? Colors.green
        : d.status == 'STOPPED'
            ? Colors.grey
            : Colors.orange;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.computer),
                const SizedBox(width: 8),
                Text(l10n.diagInstanceStatusTitle, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            _buildInfoRow(l10n.diagLabelStatus, d.status, valueColor: statusColor),
            _buildInfoRow(l10n.diagLabelMachineType, d.machineType),
            _buildInfoRow(l10n.diagLabelZone, d.zone),
            _buildInfoRow(l10n.diagLabelProject, d.projectId),
            if (d.creationTimestamp != null)
              _buildInfoRow(l10n.diagLabelCreated, _formatTimestamp(d.creationTimestamp!)),
            if (d.lastStartTimestamp != null)
              _buildInfoRow(l10n.diagLabelLastStarted, _formatTimestamp(d.lastStartTimestamp!)),
            if (d.lastStopTimestamp != null)
              _buildInfoRow(l10n.diagLabelLastStopped, _formatTimestamp(d.lastStopTimestamp!)),
          ],
        ),
      ),
    );
  }

  Widget _buildGuestAgentCard() {
    final l10n = AppLocalizations.of(context);
    final agent = _diagnostics!.guestAgentStatus;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  agent.isReporting ? Icons.check_circle : Icons.warning,
                  color: agent.isReporting ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Text(l10n.diagGuestAgentTitle, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            _buildInfoRow(
              l10n.diagLabelStatus,
              agent.isReporting ? l10n.diagStatusReporting : l10n.diagStatusNotReporting,
              valueColor: agent.isReporting ? Colors.green : Colors.orange,
            ),
            if (agent.osType != null) _buildInfoRow(l10n.diagLabelOsType, agent.osType!),
            if (agent.osVersion != null) _buildInfoRow(l10n.diagLabelOsVersion, agent.osVersion!),
            if (agent.lastHeartbeat != null)
              _buildInfoRow(l10n.diagLabelLastHeartbeat, agent.lastHeartbeat!),
            if (!agent.isReporting)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.diagGuestAgentWarning,
                  style: TextStyle(
                    color: Colors.orange.shade700,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkCard() {
    final l10n = AppLocalizations.of(context);
    final networks = _diagnostics!.networkInterfaces;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lan),
                const SizedBox(width: 8),
                Text(l10n.diagNetworkInterfacesTitle, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            ...networks.asMap().entries.map((entry) {
              final idx = entry.key;
              final ni = entry.value;
              return Padding(
                padding: EdgeInsets.only(top: idx > 0 ? 12 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (idx > 0) const Divider(),
                    Text(l10n.diagInterfaceNumber(idx + 1),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    _buildInfoRow(l10n.diagLabelNetwork, ni.network),
                    if (ni.subnetwork != null) _buildInfoRow(l10n.diagLabelSubnetwork, ni.subnetwork!),
                    if (ni.internalIp != null) _buildInfoRow(l10n.diagLabelInternalIp, ni.internalIp!),
                    if (ni.externalIp != null)
                      _buildInfoRow(l10n.diagLabelExternalIp, ni.externalIp!)
                    else
                      _buildInfoRow(l10n.diagLabelExternalIp, l10n.diagValueNone, valueColor: Colors.grey),
                    if (ni.networkTier != null) _buildInfoRow(l10n.diagLabelTier, ni.networkTier!),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildDisksCard() {
    final l10n = AppLocalizations.of(context);
    final disks = _diagnostics!.disks;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storage),
                const SizedBox(width: 8),
                Text(l10n.diagDisksTitle, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            ...disks.asMap().entries.map((entry) {
              final idx = entry.key;
              final disk = entry.value;
              return Padding(
                padding: EdgeInsets.only(top: idx > 0 ? 12 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (idx > 0) const Divider(),
                    Row(
                      children: [
                        Text(disk.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (disk.isBoot)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(l10n.diagBootChip, style: const TextStyle(fontSize: 10)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (disk.diskType != null) _buildInfoRow(l10n.diagLabelType, disk.diskType!),
                    if (disk.sizeGb != null) _buildInfoRow(l10n.diagLabelSize, l10n.diagSizeGb(disk.sizeGb!)),
                    _buildInfoRow(l10n.diagLabelMode, disk.mode),
                    _buildInfoRow(l10n.diagLabelAutoDelete, disk.autoDelete ? l10n.commonYes : l10n.commonNo),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildLabelsCard() {
    final l10n = AppLocalizations.of(context);
    final labels = _diagnostics!.labels;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.label_outline),
                const SizedBox(width: 8),
                Text(l10n.diagLabelsTitle, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: labels.map((label) {
                return Chip(
                  label: Text(l10n.diagLabelKeyValue(label.$1, label.$2)),
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return timestamp;
    }
  }
}

// ============================================================
// AUDIT LOGS TAB
// ============================================================

class AuditLogsTab extends ConsumerStatefulWidget {
  final DiagnosticsParams params;

  const AuditLogsTab({super.key, required this.params});

  @override
  ConsumerState<AuditLogsTab> createState() => _AuditLogsTabState();
}

class _AuditLogsTabState extends ConsumerState<AuditLogsTab> {
  List<AuditLogEntry>? _logs;
  bool _isLoading = false;
  String? _error;
  int _hoursAgo = 24;
  bool _filterByInstance = true;

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  Future<void> _fetchLogs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final logs = await getInstanceAuditLogs(
        projectId: widget.params.projectId,
        instanceName: _filterByInstance ? widget.params.instanceName : null,
        maxEntries: 100,
        hoursAgo: _hoursAgo,
      );

      setState(() {
        _logs = logs;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: Row(
            children: [
              // Time filter
              Text(l10n.diagLastLabel),
              DropdownButton<int>(
                value: _hoursAgo,
                items: [
                  DropdownMenuItem(value: 1, child: Text(l10n.diagHours1)),
                  DropdownMenuItem(value: 6, child: Text(l10n.diagHours6)),
                  DropdownMenuItem(value: 24, child: Text(l10n.diagHours24)),
                  DropdownMenuItem(value: 72, child: Text(l10n.diagDays3)),
                  DropdownMenuItem(value: 168, child: Text(l10n.diagDays7)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _hoursAgo = value);
                    _fetchLogs();
                  }
                },
              ),

              const SizedBox(width: 16),

              // Instance filter toggle
              FilterChip(
                label: Text(l10n.diagThisInstanceOnly),
                selected: _filterByInstance,
                onSelected: (value) {
                  setState(() => _filterByInstance = value);
                  _fetchLogs();
                },
              ),

              const Spacer(),

              // Refresh
              IconButton(
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                onPressed: _isLoading ? null : _fetchLogs,
              ),
            ],
          ),
        ),

        // Content
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    final l10n = AppLocalizations.of(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
              const SizedBox(height: 16),
              Text(
                _error!.contains('PERMISSION_DENIED')
                    ? l10n.diagPermissionDeniedTitle
                    : l10n.diagErrorLoadingAuditLogsTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading && _logs == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_logs == null || _logs!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(l10n.diagNoAuditLogsFound),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _logs!.length,
      itemBuilder: (context, index) {
        final log = _logs![index];
        return _buildLogEntry(log);
      },
    );
  }

  Widget _buildLogEntry(AuditLogEntry log) {
    final l10n = AppLocalizations.of(context);
    final severityColor = switch (log.severity) {
      'ERROR' => Colors.red,
      'WARNING' => Colors.orange,
      'INFO' => Colors.blue,
      _ => Colors.grey,
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: severityColor.withValues(alpha: 0.2),
          child: Icon(
            _getMethodIcon(log.methodName),
            size: 18,
            color: severityColor,
          ),
        ),
        title: Text(
          log.methodName ?? l10n.diagUnknownOperation,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          l10n.diagLogSubtitle(
            _formatTimestamp(log.timestamp),
            log.principalEmail ?? l10n.diagSystemFallback,
          ),
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLogDetailRow(l10n.diagLabelSeverity, log.severity),
                _buildLogDetailRow(l10n.diagLabelResource, log.resourceName ?? l10n.diagValueNa),
                _buildLogDetailRow(l10n.diagLabelResourceType, log.resourceType),
                _buildLogDetailRow(l10n.diagLabelLog, log.logName),
                if (log.statusCode != null)
                  _buildLogDetailRow(
                    l10n.diagLabelStatus,
                    '${log.statusCode}${log.statusMessage != null ? " - ${log.statusMessage}" : ""}',
                  ),
                if (log.requestSummary != null)
                  _buildLogDetailRow(l10n.diagLabelRequest, log.requestSummary!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  IconData _getMethodIcon(String? method) {
    if (method == null) return Icons.help_outline;

    if (method.contains('start')) return Icons.play_arrow;
    if (method.contains('stop')) return Icons.stop;
    if (method.contains('reset')) return Icons.refresh;
    if (method.contains('delete')) return Icons.delete;
    if (method.contains('create') || method.contains('insert')) return Icons.add;
    if (method.contains('update') || method.contains('patch')) return Icons.edit;
    if (method.contains('get') || method.contains('list')) return Icons.visibility;
    if (method.contains('setMetadata')) return Icons.settings;

    return Icons.terminal;
  }

  String _formatTimestamp(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return timestamp;
    }
  }
}

/// Show the diagnostics panel dialog
Future<void> showDiagnosticsPanel(
  BuildContext context, {
  required String projectId,
  required String zone,
  required String instanceName,
}) {
  return showDialog(
    context: context,
    builder: (context) => DiagnosticsPanel(
      params: DiagnosticsParams(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
      ),
    ),
  );
}
