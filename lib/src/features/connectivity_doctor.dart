import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/doctor.dart';

/// Connectivity Doctor Dialog - Sprint 7
///
/// Automated troubleshooter that diagnoses connectivity problems with GCP VMs.
/// Runs 10 checks grouped in 5 categories, shows results with status icons,
/// and provides fix suggestions and export functionality.
class ConnectivityDoctorDialog extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const ConnectivityDoctorDialog({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<ConnectivityDoctorDialog> createState() =>
      _ConnectivityDoctorDialogState();
}

class _ConnectivityDoctorDialogState
    extends ConsumerState<ConnectivityDoctorDialog> {
  DoctorReport? _report;
  bool _isRunning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _runDoctor();
  }

  Future<void> _runDoctor() async {
    setState(() {
      _isRunning = true;
      _error = null;
    });

    try {
      final report = await runDoctor(
        projectId: widget.projectId,
        zone: widget.zone,
        instanceName: widget.instanceName,
      );
      if (mounted) {
        setState(() {
          _report = report;
          _isRunning = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isRunning = false;
        });
      }
    }
  }

  Future<void> _exportReport() async {
    if (_report == null) return;

    try {
      final markdown = await generateDoctorReport(report: _report!);
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(
          '${dir.path}/doctor_report_${widget.instanceName}_$timestamp.md');
      await file.writeAsString(markdown);

      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.doctorReportExported(file.path)),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: l10n.doctorCopyPath,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: file.path));
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.doctorExportFailed('$e'))),
        );
      }
    }
  }

  Future<void> _executeFix(String fixActionId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.doctorConfirmFixTitle),
          content: Text(
            fixActionId == 'start_vm'
                ? l10n.doctorConfirmStartVm(widget.instanceName)
                : fixActionId == 're_authenticate'
                    ? l10n.doctorConfirmReauthenticate
                    : l10n.doctorConfirmExecuteFix(fixActionId),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.doctorExecute),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      final result = await executeDoctorFix(
        fixActionId: fixActionId,
        projectId: widget.projectId,
        zone: widget.zone,
        instanceName: widget.instanceName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          // Rust-produced result message; not translated this phase.
          SnackBar(content: Text(result)),
        );
        // Re-run doctor after fix
        _runDoctor();
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.doctorFixFailed('$e'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.medical_services_outlined,
                    size: 28,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.doctorTitle,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        Text(
                          widget.instanceName,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer
                                .withAlpha(178),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Action bar
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _isRunning ? null : _runDoctor,
                    icon: _isRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    label: Text(
                        _isRunning ? l10n.doctorRunning : l10n.doctorRunAgain),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed:
                        _report != null && !_isRunning ? _exportReport : null,
                    icon: const Icon(Icons.download, size: 18),
                    label: Text(l10n.doctorExportReport),
                  ),
                  const Spacer(),
                  if (_report != null) ...[
                    _SummaryChip(
                      label: '${_report!.passCount}',
                      icon: Icons.check_circle,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 4),
                    _SummaryChip(
                      label: '${_report!.warningCount}',
                      icon: Icons.warning,
                      color: Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    _SummaryChip(
                      label: '${_report!.failCount}',
                      icon: Icons.cancel,
                      color: Colors.red,
                    ),
                    const SizedBox(width: 4),
                    _SummaryChip(
                      label: '${_report!.skippedCount}',
                      icon: Icons.skip_next,
                      color: Colors.grey,
                    ),
                  ],
                ],
              ),
            ),

            const Divider(height: 1),

            // Body
            Expanded(
              child: _buildBody(theme, l10n),
            ),

            // Footer
            if (_report != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(28)),
                ),
                child: Row(
                  children: [
                    Text(
                      l10n.doctorTotalDuration(
                          _report!.totalDurationMs.toInt()),
                      style: theme.textTheme.bodySmall,
                    ),
                    const Spacer(),
                    Text(
                      _report!.generatedAt.split('T').first,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, AppLocalizations l10n) {
    if (_isRunning && _report == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.doctorRunningChecks),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(l10n.commonErrorPrefix('$_error')),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _runDoctor,
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      );
    }

    if (_report == null) {
      return Center(child: Text(l10n.doctorNoResultsYet));
    }

    // Group checks by category
    final categories = DoctorCheckCategory.values;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final category in categories) ...[
            _buildCategorySection(theme, l10n, category, _report!.checks),
          ],
        ],
      ),
    );
  }

  Widget _buildCategorySection(
    ThemeData theme,
    AppLocalizations l10n,
    DoctorCheckCategory category,
    List<DoctorCheckResult> allChecks,
  ) {
    final checks =
        allChecks.where((c) => c.category == category).toList();
    if (checks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Row(
            children: [
              Icon(
                _categoryIcon(category),
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                _categoryDisplayName(category, l10n),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        ...checks.map((check) => _DoctorCheckTile(
              check: check,
              onCopyCommand: check.fixCommand != null
                  ? () {
                      Clipboard.setData(
                          ClipboardData(text: check.fixCommand!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(l10n.doctorCommandCopied)),
                      );
                    }
                  : null,
              onFix: check.fixActionId != null
                  ? () => _executeFix(check.fixActionId!)
                  : null,
            )),
        const SizedBox(height: 8),
      ],
    );
  }

  IconData _categoryIcon(DoctorCheckCategory category) {
    switch (category) {
      case DoctorCheckCategory.authentication:
        return Icons.lock_outline;
      case DoctorCheckCategory.projectPermissions:
        return Icons.folder_shared_outlined;
      case DoctorCheckCategory.iapNetwork:
        return Icons.security;
      case DoctorCheckCategory.vmStatus:
        return Icons.computer;
      case DoctorCheckCategory.localEnvironment:
        return Icons.desktop_windows;
    }
  }

  String _categoryDisplayName(
      DoctorCheckCategory category, AppLocalizations l10n) {
    switch (category) {
      case DoctorCheckCategory.authentication:
        return l10n.doctorCategoryAuthentication;
      case DoctorCheckCategory.projectPermissions:
        return l10n.doctorCategoryProjectPermissions;
      case DoctorCheckCategory.iapNetwork:
        return l10n.doctorCategoryIapNetwork;
      case DoctorCheckCategory.vmStatus:
        return l10n.doctorCategoryVmStatus;
      case DoctorCheckCategory.localEnvironment:
        return l10n.doctorCategoryLocalEnvironment;
    }
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _SummaryChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(color: color, fontSize: 12)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _DoctorCheckTile extends StatelessWidget {
  final DoctorCheckResult check;
  final VoidCallback? onCopyCommand;
  final VoidCallback? onFix;

  const _DoctorCheckTile({
    required this.check,
    this.onCopyCommand,
    this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: ExpansionTile(
        leading: _statusIcon(),
        // check.name is Rust-produced content; not translated this phase.
        title: Text(check.name, style: theme.textTheme.bodyMedium),
        subtitle: Text(
          check.message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          '${check.durationMs}ms',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (check.details != null) ...[
                  Text(
                    check.details!,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                ],
                if (check.suggestion != null) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline,
                          size: 16, color: Colors.amber.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          check.suggestion!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.amber.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (check.fixCommand != null || check.fixActionId != null)
                  Row(
                    children: [
                      if (check.fixCommand != null)
                        OutlinedButton.icon(
                          onPressed: onCopyCommand,
                          icon: const Icon(Icons.copy, size: 14),
                          label: Text(l10n.doctorCopyCommand),
                          style: OutlinedButton.styleFrom(
                            textStyle: const TextStyle(fontSize: 12),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                          ),
                        ),
                      if (check.fixCommand != null &&
                          check.fixActionId != null)
                        const SizedBox(width: 8),
                      if (check.fixActionId != null)
                        FilledButton.icon(
                          onPressed: onFix,
                          icon: const Icon(Icons.build, size: 14),
                          label: Text(l10n.doctorFix),
                          style: FilledButton.styleFrom(
                            textStyle: const TextStyle(fontSize: 12),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
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

  Widget _statusIcon() {
    switch (check.status) {
      case DoctorCheckStatus.pass:
        return const Icon(Icons.check_circle, color: Colors.green, size: 24);
      case DoctorCheckStatus.warning:
        return const Icon(Icons.warning, color: Colors.orange, size: 24);
      case DoctorCheckStatus.fail:
        return const Icon(Icons.cancel, color: Colors.red, size: 24);
      case DoctorCheckStatus.skipped:
        return const Icon(Icons.skip_next, color: Colors.grey, size: 24);
    }
  }
}

/// Show the connectivity doctor dialog
Future<void> showConnectivityDoctor(
  BuildContext context, {
  required String projectId,
  required String zone,
  required String instanceName,
}) {
  return showDialog(
    context: context,
    builder: (context) => ConnectivityDoctorDialog(
      projectId: projectId,
      zone: zone,
      instanceName: instanceName,
    ),
  );
}
