import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../gcloud_provider.dart';
import '../sftp_browser.dart';
import '../../bridge/api.dart/api.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final vm = widget.session.target;
    try {
      final username = await getUsername();
      if (!mounted) return;
      final port = await ref
          .read(activeConnectionsProvider.notifier)
          .connect(vm.projectId, vm.zone, vm.name, remotePort: 22);
      if (port == null) throw Exception('Tunnel could not be established');
      if (mounted) {
        setState(() {
          _port = port;
          _username = username;
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
    return SftpBrowserBody(
      host: 'localhost',
      port: _port!,
      username: _username!,
      instanceName: widget.session.target.name,
    );
  }
}
