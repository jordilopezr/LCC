// Sprint 16: VM Snapshot Manager dialog (2 tabs — List & Create)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/snapshots.dart';
import 'snapshot_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showSnapshotManager(
  BuildContext context, {
  required String projectId,
  required String zone,
  required String instanceName,
}) {
  return showDialog(
    context: context,
    builder: (_) => SnapshotManagerDialog(
      projectId: projectId,
      zone: zone,
      instanceName: instanceName,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main dialog widget
// ─────────────────────────────────────────────────────────────────────────────

class SnapshotManagerDialog extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const SnapshotManagerDialog({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<SnapshotManagerDialog> createState() =>
      _SnapshotManagerDialogState();
}

class _SnapshotManagerDialogState extends ConsumerState<SnapshotManagerDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // Initialize the provider with this instance
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(snapshotProvider.notifier)
          .setInstance(widget.projectId, widget.zone, widget.instanceName);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshotsAsync = ref.watch(snapshotProvider);
    final snapshotCount = switch (snapshotsAsync) {
      AsyncData(:final value) => value.length,
      _ => 0,
    };

    return Dialog(
      child: SizedBox(
        width: 700,
        height: 580,
        child: Column(
          children: [
            _buildHeader(context),
            _buildTabBar(context, snapshotCount),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _SnapshotListTab(
                    projectId: widget.projectId,
                    zone: widget.zone,
                    instanceName: widget.instanceName,
                  ),
                  _CreateSnapshotTab(
                    projectId: widget.projectId,
                    zone: widget.zone,
                    instanceName: widget.instanceName,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.camera_alt_outlined, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.snapshotDialogTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  '${widget.instanceName}  ·  ${widget.zone}',
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
    );
  }

  Widget _buildTabBar(BuildContext context, int count) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: TabBar(
        controller: _tabController,
        tabs: [
          Tab(
            icon: const Icon(Icons.camera_roll_outlined, size: 18),
            text: count > 0
                ? l10n.snapshotTabListWithCount(count)
                : l10n.snapshotTabList,
          ),
          Tab(
            icon: const Icon(Icons.add_a_photo_outlined, size: 18),
            text: l10n.snapshotTabCreate,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1 — Snapshot list
// ─────────────────────────────────────────────────────────────────────────────

class _SnapshotListTab extends ConsumerWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const _SnapshotListTab({
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshotsAsync = ref.watch(snapshotProvider);
    final l10n = AppLocalizations.of(context);

    return snapshotsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(l10n.commonErrorPrefix(err.toString()),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
              onPressed: () => ref.invalidate(snapshotProvider),
            ),
          ],
        ),
      ),
      data: (snapshots) => _buildList(context, ref, snapshots),
    );
  }

  Widget _buildList(
      BuildContext context, WidgetRef ref, List<GcpSnapshot> snapshots) {
    final l10n = AppLocalizations.of(context);
    if (snapshots.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined,
                size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              l10n.snapshotEmptyList,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRefresh),
              onPressed: () => ref
                  .read(snapshotProvider.notifier)
                  .setInstance(projectId, zone, instanceName),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(l10n.commonRefresh),
                onPressed: () => ref
                    .read(snapshotProvider.notifier)
                    .setInstance(projectId, zone, instanceName),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            itemCount: snapshots.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _SnapshotCard(
              snapshot: snapshots[i],
              projectId: projectId,
              zone: zone,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Snapshot card
// ─────────────────────────────────────────────────────────────────────────────

class _SnapshotCard extends ConsumerWidget {
  final GcpSnapshot snapshot;
  final String projectId;
  final String zone;

  const _SnapshotCard({
    required this.snapshot,
    required this.projectId,
    required this.zone,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final statusColor = _statusColor(snapshot.status);
    final formattedDate = _formatTimestamp(snapshot.creationTimestamp);
    final diskSizeStr = '${snapshot.diskSizeGb} GB';
    final storageStr = _formatBytes(snapshot.storageBytes);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name + status chip
            Row(
              children: [
                const Icon(Icons.camera_alt_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    snapshot.name,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                _StatusChip(status: snapshot.status, color: statusColor),
              ],
            ),
            const SizedBox(height: 6),
            // Metadata row
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _MetaItem(Icons.schedule, l10n.snapshotMetaCreated(formattedDate)),
                _MetaItem(Icons.storage, l10n.snapshotMetaDisk(diskSizeStr)),
                if (snapshot.storageBytes > BigInt.zero)
                  _MetaItem(Icons.cloud_outlined,
                      l10n.snapshotMetaStored(storageStr)),
                _MetaItem(Icons.dns_outlined,
                    l10n.snapshotMetaSource(snapshot.sourceDisk)),
              ],
            ),
            if (snapshot.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                snapshot.description,
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 10),
            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.restore, size: 16),
                  label: Text(l10n.snapshotRestoreDiskButton),
                  onPressed: snapshot.status == 'READY'
                      ? () => _confirmRestore(context, ref)
                      : null,
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                  ),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: Text(l10n.commonDelete),
                  onPressed: snapshot.status == 'CREATING'
                      ? null
                      : () => _confirmDelete(context, ref),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'READY' => Colors.green.shade700,
      'CREATING' => Colors.amber.shade700,
      'FAILED' => Colors.red.shade700,
      _ => Colors.grey.shade600,
    };
  }

  String _formatTimestamp(String ts) {
    if (ts.isEmpty) return '—';
    try {
      final dt = DateTime.parse(ts);
      return '${dt.year}-${_p(dt.month)}-${_p(dt.day)}  ${_p(dt.hour)}:${_p(dt.minute)}';
    } catch (_) {
      return ts.length > 19 ? ts.substring(0, 19) : ts;
    }
  }

  String _p(int v) => v.toString().padLeft(2, '0');

  String _formatBytes(BigInt bytes) {
    if (bytes <= BigInt.zero) return '—';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= BigInt.from(gb)) {
      return '${(bytes.toDouble() / gb).toStringAsFixed(2)} GB';
    }
    if (bytes >= BigInt.from(mb)) {
      return '${(bytes.toDouble() / mb).toStringAsFixed(2)} MB';
    }
    return '$bytes B';
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.snapshotDeleteTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.snapshotDeleteConfirm),
            const SizedBox(height: 8),
            Text(
              snapshot.name,
              style: const TextStyle(
                  fontFamily: 'monospace', fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await ref
          .read(snapshotProvider.notifier)
          .deleteSnapshotByName(snapshot.name);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(l10n.snapshotDeletedSnackbar(snapshot.name))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.snapshotDeleteError(e.toString()))),
        );
      }
    }
  }

  Future<void> _confirmRestore(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    // Generate a safe new disk name
    final now = DateTime.now();
    final suffix =
        '${now.year}${_p(now.month)}${_p(now.day)}-${_p(now.hour)}${_p(now.minute)}${_p(now.second)}';
    final prefix = snapshot.sourceDisk.length > 30
        ? snapshot.sourceDisk.substring(0, 30)
        : snapshot.sourceDisk;
    final suggestedName = '$prefix-restore-$suffix';
    final nameController = TextEditingController(text: suggestedName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.snapshotRestoreTitle),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.snapshotRestoreDescription(snapshot.name)),
              const SizedBox(height: 4),
              Text(
                l10n.snapshotRestoreVmNote,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: l10n.snapshotNewDiskNameLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                maxLength: 63,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.snapshotCreateDiskButton),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final newDiskName = nameController.text.trim();

    try {
      // Show loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: SizedBox(
            height: 80,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.snapshotCreatingDiskFromSnapshot),
                ],
              ),
            ),
          ),
        ),
      );

      await ref
          .read(snapshotProvider.notifier)
          .createDiskFromSnapshotByName(snapshot.name, newDiskName);

      if (context.mounted) Navigator.of(context).pop(); // close loading

      if (context.mounted) {
        _showRestoreSuccessDialog(context, newDiskName, zone);
      }
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop(); // close loading
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.snapshotCreateDiskError(e.toString()))),
        );
      }
    }
  }

  void _showRestoreSuccessDialog(
      BuildContext context, String newDiskName, String zone) {
    final l10n = AppLocalizations.of(context);
    final vm = snapshot.sourceDisk;
    final commands = '''# 1. Detach the current boot disk
gcloud compute instances detach-disk $vm \\
  --disk=$vm --zone=$zone

# 2. Attach the restored disk
gcloud compute instances attach-disk $vm \\
  --disk=$newDiskName --zone=$zone --boot

# 3. Start the instance
gcloud compute instances start $vm --zone=$zone

# 4. (Optional) Delete the old disk when confirmed
gcloud compute disks delete $vm --zone=$zone --quiet''';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Text(l10n.snapshotDiskCreatedTitle),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.snapshotDiskCreatedMessage(newDiskName, zone)),
              const SizedBox(height: 12),
              Text(
                l10n.snapshotRestoreCommandsIntro,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  commands,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: Text(l10n.snapshotCopyCommandsButton),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: commands));
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text(l10n.snapshotCommandsCopiedSnackbar)),
              );
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final Color color;

  const _StatusChip({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaItem(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Colors.grey.shade600),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 2 — Create snapshot
// ─────────────────────────────────────────────────────────────────────────────

class _CreateSnapshotTab extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const _CreateSnapshotTab({
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<_CreateSnapshotTab> createState() => _CreateSnapshotTabState();
}

class _CreateSnapshotTabState extends ConsumerState<_CreateSnapshotTab> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  final _descController = TextEditingController();

  String? _bootDiskName;
  bool _loadingDisk = true;
  String? _diskError;
  bool _creating = false;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
        text: _generateSnapshotName(widget.instanceName));
    _loadBootDisk();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  String _generateSnapshotName(String instanceName) {
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final prefix =
        instanceName.length > 30 ? instanceName.substring(0, 30) : instanceName;
    return '$prefix-$date-$time';
  }

  Future<void> _loadBootDisk() async {
    setState(() {
      _loadingDisk = true;
      _diskError = null;
    });
    try {
      final name = await getBootDiskName(
        projectId: widget.projectId,
        zone: widget.zone,
        instanceName: widget.instanceName,
      );
      if (mounted) {
        setState(() {
          _bootDiskName = name;
          _loadingDisk = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _diskError = e.toString();
          _loadingDisk = false;
        });
      }
    }
  }

  String? _validateName(String? value) {
    final l10n = AppLocalizations.of(context);
    if (value == null || value.isEmpty) return l10n.snapshotNameRequired;
    if (value.length > 63) return l10n.snapshotNameMaxLength;
    if (!RegExp(r'^[a-z]').hasMatch(value)) {
      return l10n.snapshotNameMustStartLowercase;
    }
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(value)) {
      return l10n.snapshotNameInvalidChars;
    }
    if (value.endsWith('-')) return l10n.snapshotNameNoTrailingHyphen;
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final l10n = AppLocalizations.of(context);
    setState(() => _creating = true);

    try {
      await ref
          .read(snapshotProvider.notifier)
          .createSnapshotForInstance(
            _nameController.text.trim(),
            _descController.text.trim(),
          );

      if (mounted) {
        setState(() => _creating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  l10n.snapshotCreatedSnackbar(_nameController.text.trim()))),
        );
        // Reset form
        _nameController.text =
            _generateSnapshotName(widget.instanceName);
        _descController.clear();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _creating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.snapshotCreateError(e.toString()))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Snapshot name
                TextFormField(
                  controller: _nameController,
                  maxLength: 63,
                  decoration: InputDecoration(
                    labelText: l10n.snapshotNameFieldLabel,
                    helperText: l10n.snapshotNameFieldHelper,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: _validateName,
                  enabled: !_creating,
                ),
                const SizedBox(height: 16),

                // Description
                TextFormField(
                  controller: _descController,
                  maxLength: 256,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: l10n.snapshotDescriptionFieldLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  enabled: !_creating,
                ),
                const SizedBox(height: 16),

                // Boot disk info card
                _buildDiskInfoCard(),

                const SizedBox(height: 24),

                // Submit button
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: Text(l10n.snapshotCreateButton),
                    onPressed: (_creating || _loadingDisk) ? null : _submit,
                  ),
                ),

                const SizedBox(height: 12),
                Text(
                  l10n.snapshotCreateDurationNote,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),

        // Loading overlay during creation
        if (_creating)
          Container(
            color: Colors.black26,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(l10n.snapshotCreatingOverlay,
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDiskInfoCard() {
    final l10n = AppLocalizations.of(context);
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.storage_outlined, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: _loadingDisk
                  ? Row(
                      children: [
                        const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text(l10n.snapshotDetectingBootDisk,
                            style: const TextStyle(fontSize: 13)),
                      ],
                    )
                  : _diskError != null
                      ? Text(
                          l10n.snapshotBootDiskDetectError(_diskError!),
                          style: const TextStyle(
                              fontSize: 12, color: Colors.orange),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l10n.snapshotBootDiskLabel,
                                style: const TextStyle(fontSize: 12)),
                            Text(
                              _bootDiskName ?? '—',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
            ),
            if (_diskError != null)
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: l10n.commonRetry,
                onPressed: _loadBootDisk,
              ),
          ],
        ),
      ),
    );
  }
}
