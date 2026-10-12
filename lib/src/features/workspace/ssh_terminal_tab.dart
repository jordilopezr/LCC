import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../gcloud_provider.dart';
import '../ssh_consent_dialog.dart';
import 'ssh_terminal_controller.dart';
import 'workspace_session.dart';

class SshTerminalTab extends ConsumerStatefulWidget {
  final WorkspaceSession session;
  const SshTerminalTab({super.key, required this.session});

  @override
  ConsumerState<SshTerminalTab> createState() => _SshTerminalTabState();
}

class _SshTerminalTabState extends ConsumerState<SshTerminalTab> {
  SshTerminalController? _controller;
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
        // Neither a controller nor an error would ever be set, and the build
        // below renders "Connecting…" for both nulls — so the tab would sit
        // on that message forever. The forward already says so out loud
        // (`_connectSshForward` in gcloud_provider.dart); say it here too.
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
      final controller = SshTerminalController(
        username: granted.username,
        identityFile: granted.keyPath,
        instanceName: vm.name,
        ensureTunnel: () => ref
            .read(activeConnectionsProvider.notifier)
            .connect(vm.projectId, vm.zone, vm.name, remotePort: 22),
      );
      setState(() => _controller = controller);
      await controller.start();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = _controller;
    if (c == null) {
      final error = _error;
      if (error != null) {
        return Center(child: Text(error, textAlign: TextAlign.center));
      }
      return Center(child: Text(l10n.workspaceTerminalConnecting));
    }
    return ValueListenableBuilder<TerminalPhase>(
      valueListenable: c.phaseNotifier,
      builder: (context, phase, _) {
        switch (phase) {
          case TerminalPhase.connectingTunnel:
          case TerminalPhase.launching:
            return Center(child: Text(l10n.workspaceTerminalConnecting));
          case TerminalPhase.error:
            return _statusPanel(l10n.workspaceTerminalError(c.errorDetail ?? ''),
                l10n.commonRetry, c.reconnect);
          case TerminalPhase.disconnected:
            return Column(children: [
              Expanded(child: TerminalView(c.terminal)),
              _reconnectBar(l10n, c.reconnect),
            ]);
          case TerminalPhase.connected:
            return TerminalView(c.terminal);
        }
      },
    );
  }

  Widget _reconnectBar(AppLocalizations l10n, VoidCallback onReconnect) =>
      Container(
        padding: const EdgeInsets.all(8),
        color: Colors.orange.shade50,
        child: Row(children: [
          Expanded(child: Text(l10n.workspaceTerminalDisconnected)),
          TextButton(onPressed: onReconnect, child: Text(l10n.workspaceReconnect)),
        ]),
      );

  Widget _statusPanel(String message, String action, VoidCallback onAction) =>
      Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: onAction, child: Text(action)),
        ]),
      );
}
