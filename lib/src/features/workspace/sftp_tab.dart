import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../gcloud_provider.dart';
import '../sftp/sftp_dual_view.dart';
import '../ssh_consent_dialog.dart';
import 'workspace_session.dart';

class SftpTab extends ConsumerStatefulWidget {
  final WorkspaceSession session;
  const SftpTab({super.key, required this.session});

  @override
  ConsumerState<SftpTab> createState() => _SftpTabState();
}

class _SftpTabState extends ConsumerState<SftpTab> {
  int? _port;
  String? _username;
  String? _identityFile;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final vm = widget.session.target;
    try {
      final outcome = await ensureSshAccess(
        context,
        projectId: vm.projectId,
        zone: vm.zone,
        instance: vm.name,
      );
      if (outcome is SshAccessAbandoned) {
        // Leaving both `_error` and `_port` null renders "Connecting…"
        // forever — the tab would never resolve. The forward already reports
        // this state; the tabs must agree.
        if (!mounted) return;
        setState(() =>
            _error = AppLocalizations.of(context).workspaceTerminalAbandoned);
        return;
      }
      if (outcome is SshAccessRefused) {
        if (!mounted) return;
        setState(() => _error = AppLocalizations.of(context).sshConsentDenied);
        return;
      }
      final granted = outcome as SshAccessGranted;
      if (!mounted) return;
      final port = await ref
          .read(activeConnectionsProvider.notifier)
          .connect(vm.projectId, vm.zone, vm.name, remotePort: 22);
      if (port == null) throw Exception('Tunnel could not be established');
      if (mounted) {
        setState(() {
          _port = port;
          _username = granted.username;
          _identityFile = granted.keyPath;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_error != null) {
      return Center(child: Text(l10n.workspaceTerminalError(_error!)));
    }
    if (_port == null) {
      return Center(child: Text(l10n.workspaceTerminalConnecting));
    }
    return SftpDualView(
      host: 'localhost',
      port: _port!,
      username: _username!,
      identityFile: _identityFile,
      instanceName: widget.session.target.name,
    );
  }
}
