/// SSHFS Mount Dialog - Sprint 6
///
/// UI for mounting remote filesystems via SSHFS through IAP tunnels.
/// Provides two tabs:
/// 1. Mount - Configure and mount a remote directory
/// 2. Active Mounts - View and manage active mounts

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/sshfs_mount.dart';
import 'sshfs_mount_provider.dart';

/// Show the SSHFS mount dialog
void showSshfsMountDialog(
  BuildContext context, {
  required WidgetRef ref,
  required String projectId,
  required String zone,
  required String instanceName,
  required int tunnelPort,
}) {
  showDialog(
    context: context,
    builder: (context) => SshfsMountDialog(
      projectId: projectId,
      zone: zone,
      instanceName: instanceName,
      tunnelPort: tunnelPort,
    ),
  );
}

class SshfsMountDialog extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;
  final int tunnelPort;

  const SshfsMountDialog({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
    required this.tunnelPort,
  });

  @override
  ConsumerState<SshfsMountDialog> createState() => _SshfsMountDialogState();
}

class _SshfsMountDialogState extends ConsumerState<SshfsMountDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _usernameController = TextEditingController();
  final _remotePathController = TextEditingController();
  final _localPathController = TextEditingController();

  // Mount options
  bool _readOnly = false;
  bool _cache = true;
  bool _compression = true;
  bool _reconnect = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _remotePathController.text = '/home';
    _loadDefaults();
  }

  Future<void> _loadDefaults() async {
    // Load username from GCP account
    try {
      final email = await getGcloudAccountEmail();
      if (mounted) {
        final userPart = email.split('@').first;
        _usernameController.text = userPart.replaceAll('.', '_');
      }
    } catch (_) {
      _usernameController.text = '';
    }

    // Load default mount point
    try {
      final defaultPath = await ref.read(sshfsMountProvider.notifier)
          .getDefaultMountPoint(widget.instanceName, '/home');
      if (mounted) {
        _localPathController.text = defaultPath;
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _tabController.dispose();
    _usernameController.dispose();
    _remotePathController.dispose();
    _localPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(sshfsMountProvider);
    final theme = Theme.of(context);
    final isAvailable = ref.watch(sshfsAvailableProvider);

    return Dialog(
      child: Container(
        width: 650,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.folder_shared,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sshfsDialogTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        widget.instanceName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
            const SizedBox(height: 16),

            // SSHFS status warning
            if (!isAvailable)
              _buildSshfsWarning(state.status, theme),

            // Tab bar
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: l10n.sshfsMountAction),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l10n.sshfsActiveMountsTab),
                      if (state.activeMounts.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${state.activeMounts.length}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onPrimary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildMountTab(state, theme, isAvailable),
                  _buildActiveMountsTab(state, theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSshfsWarning(SshfsStatus? status, ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final issues = status?.issues ?? [l10n.sshfsUnavailableDefaultIssue];

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withAlpha(100),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber, color: theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Text(
                l10n.sshfsNotAvailableTitle,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...issues.map((issue) => Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(issue, style: theme.textTheme.bodySmall),
          )),
        ],
      ),
    );
  }

  Widget _buildMountTab(SshfsMountState state, ThemeData theme, bool isAvailable) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Info box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.sshfsMountInfoText(widget.instanceName, widget.tunnelPort),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Username field
          TextField(
            controller: _usernameController,
            enabled: isAvailable,
            decoration: InputDecoration(
              labelText: l10n.sshfsUsernameLabel,
              hintText: l10n.sshfsUsernameHint,
              prefixIcon: const Icon(Icons.person),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          // Remote path field
          TextField(
            controller: _remotePathController,
            enabled: isAvailable,
            decoration: InputDecoration(
              labelText: l10n.sshfsRemotePathLabel,
              hintText: '/home/user or /var/log',
              prefixIcon: const Icon(Icons.folder_open),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _updateLocalPath(),
          ),
          const SizedBox(height: 16),

          // Local path field
          TextField(
            controller: _localPathController,
            enabled: isAvailable,
            decoration: InputDecoration(
              labelText: l10n.sshfsLocalMountPointLabel,
              hintText: '/home/you/mounts/vm-name',
              prefixIcon: const Icon(Icons.folder),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: isAvailable ? _resetLocalPath : null,
                tooltip: l10n.sshfsResetToDefaultTooltip,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Mount options
          Text(l10n.sshfsMountOptionsTitle, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),

          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _buildOptionChip(l10n.sshfsReadOnlyOption, _readOnly, (v) => setState(() => _readOnly = v), isAvailable),
              _buildOptionChip(l10n.sshfsCacheOption, _cache, (v) => setState(() => _cache = v), isAvailable),
              _buildOptionChip(l10n.sshfsCompressionOption, _compression, (v) => setState(() => _compression = v), isAvailable),
              _buildOptionChip(l10n.sshfsAutoReconnectOption, _reconnect, (v) => setState(() => _reconnect = v), isAvailable),
            ],
          ),
          const SizedBox(height: 24),

          // Mount button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isAvailable && !state.isLoading ? _mount : null,
              icon: state.isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(state.isLoading ? l10n.sshfsMountingButton : l10n.sshfsMountAction),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
          ),

          // Error/Success message
          if (state.error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(state.error!)),
                ],
              ),
            ),
          ],

          if (state.successMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withAlpha(50),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(child: Text(state.successMessage!)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionChip(String label, bool value, ValueChanged<bool> onChanged, bool enabled) {
    return FilterChip(
      label: Text(label),
      selected: value,
      onSelected: enabled ? onChanged : null,
    );
  }

  Widget _buildActiveMountsTab(SshfsMountState state, ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final instanceMounts = ref.watch(instanceMountsProvider((
      projectId: widget.projectId,
      instanceName: widget.instanceName,
    )));

    if (state.activeMounts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.sshfsNoActiveMountsTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.sshfsNoActiveMountsSubtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Unmount all button
        if (state.activeMounts.length > 1)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.sshfsActiveMountsCount(state.activeMounts.length),
                  style: theme.textTheme.bodySmall,
                ),
                TextButton.icon(
                  onPressed: state.isLoading ? null : _unmountAll,
                  icon: const Icon(Icons.eject, size: 18),
                  label: Text(l10n.sshfsUnmountAllButton),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),

        // Instance-specific mounts section
        if (instanceMounts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.computer, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.sshfsThisInstance(widget.instanceName),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ],

        // Mounts list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: state.activeMounts.length,
            itemBuilder: (context, index) {
              final mount = state.activeMounts[index];
              final isCurrentInstance = mount.projectId == widget.projectId &&
                  mount.instanceName == widget.instanceName;

              return _buildMountCard(mount, theme, isCurrentInstance, state.isLoading);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMountCard(SshfsMount mount, ThemeData theme, bool isCurrentInstance, bool isLoading) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isCurrentInstance
          ? theme.colorScheme.primaryContainer.withAlpha(50)
          : null,
      child: ExpansionTile(
        leading: Icon(
          Icons.folder_shared,
          color: isCurrentInstance
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          mount.instanceName,
          style: TextStyle(
            fontWeight: isCurrentInstance ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          '${mount.remotePath} → ${mount.localMountPoint}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: isCurrentInstance
            ? Chip(
                label: Text(l10n.commonCurrentChip),
                labelStyle: TextStyle(fontSize: 10, color: theme.colorScheme.primary),
                backgroundColor: theme.colorScheme.primaryContainer,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow(l10n.sshfsInfoProject, mount.projectId, theme),
                _buildInfoRow(l10n.sshfsInfoZone, mount.zone, theme),
                _buildInfoRow(l10n.commonUsernameLabel, mount.username, theme),
                _buildInfoRow(l10n.sshfsRemotePathLabel, mount.remotePath, theme),
                _buildInfoRow(l10n.sshfsInfoLocalMount, mount.localMountPoint, theme),
                _buildInfoRow(l10n.sshfsInfoTunnelPort, mount.tunnelPort.toString(), theme),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: isLoading ? null : () => _openInFileManager(mount.id),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: Text(l10n.sshfsOpenButton),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: isLoading ? null : () => _unmount(mount.localMountPoint),
                      icon: const Icon(Icons.eject, size: 18),
                      label: Text(l10n.sshfsUnmountButton),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateLocalPath() async {
    try {
      final defaultPath = await ref.read(sshfsMountProvider.notifier)
          .getDefaultMountPoint(widget.instanceName, _remotePathController.text);
      if (mounted) {
        _localPathController.text = defaultPath;
      }
    } catch (_) {}
  }

  Future<void> _resetLocalPath() async {
    await _updateLocalPath();
  }

  Future<void> _mount() async {
    final l10n = AppLocalizations.of(context);
    final username = _usernameController.text.trim();
    final remotePath = _remotePathController.text.trim();
    final localPath = _localPathController.text.trim();

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.commonPleaseEnterUsername)),
      );
      return;
    }

    if (remotePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.sshfsRemotePathRequired)),
      );
      return;
    }

    if (localPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.sshfsLocalPathRequired)),
      );
      return;
    }

    ref.read(sshfsMountProvider.notifier).clearMessages();

    final options = SshfsMountOptions(
      readOnly: _readOnly,
      cache: _cache,
      compression: _compression,
      reconnect: _reconnect,
      serverAliveInterval: 15,
      allowOther: false,
      followSymlinks: true,
      sshPort: null,
      identityFile: null,
    );

    final result = await ref.read(sshfsMountProvider.notifier).mount(
      projectId: widget.projectId,
      zone: widget.zone,
      instanceName: widget.instanceName,
      username: username,
      remotePath: remotePath,
      localMountPoint: localPath,
      tunnelPort: widget.tunnelPort,
      options: options,
    );

    if (result.success && mounted) {
      _tabController.animateTo(1); // Switch to Active Mounts tab
    }
  }

  Future<void> _unmount(String mountPoint) async {
    await ref.read(sshfsMountProvider.notifier).unmount(mountPoint);
  }

  Future<void> _unmountAll() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.sshfsUnmountAllButton),
        content: Text(l10n.sshfsUnmountAllConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.sshfsUnmountAllButton),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(sshfsMountProvider.notifier).unmountAll();
    }
  }

  Future<void> _openInFileManager(String mountId) async {
    await ref.read(sshfsMountProvider.notifier).openInFileManager(mountId);
  }
}
