import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'workspace_provider.dart';
import 'workspace_session.dart';
import 'overview_tab.dart';
import 'ssh_terminal_tab.dart';
import 'sftp_tab.dart';

class WorkspacePanel extends ConsumerWidget {
  const WorkspacePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ws = ref.watch(workspaceProvider);
    final notifier = ref.read(workspaceProvider.notifier);

    if (ws.sessions.isEmpty) {
      return Center(child: Text(l10n.workspaceNoTabs));
    }
    final activeIndex =
        ws.sessions.indexWhere((s) => s.id == ws.activeId).clamp(0, ws.sessions.length - 1);

    return Column(children: [
      _TabStrip(sessions: ws.sessions, activeId: ws.activeId, notifier: notifier),
      const Divider(height: 1),
      Expanded(
        child: IndexedStack(
          index: activeIndex,
          children: [
            for (final s in ws.sessions)
              KeyedSubtree(key: ValueKey(s.id), child: _content(s)),
          ],
        ),
      ),
    ]);
  }

  Widget _content(WorkspaceSession s) {
    switch (s.type) {
      case SessionType.overview:
        return OverviewTab(target: s.target);
      case SessionType.ssh:
        return SshTerminalTab(session: s);
      case SessionType.sftp:
        return SftpTab(session: s);
    }
  }
}

class _TabStrip extends StatelessWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _TabStrip(
      {required this.sessions, required this.activeId, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(WorkspaceSession s) {
      final kind = switch (s.type) {
        SessionType.overview => l10n.workspaceTabOverview,
        SessionType.ssh => l10n.workspaceTabSsh,
        SessionType.sftp => l10n.workspaceTabSftp,
      };
      return '${s.target.name} · $kind';
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in sessions)
            _Tab(
              label: label(s),
              active: s.id == activeId,
              onTap: () => notifier.focus(s.id),
              onClose: () => notifier.close(s.id),
              closeTooltip: l10n.workspaceCloseTab,
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final String closeTooltip;
  const _Tab(
      {required this.label,
      required this.active,
      required this.onTap,
      required this.onClose,
      required this.closeTooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: active ? scheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  fontWeight: active ? FontWeight.bold : FontWeight.normal)),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            tooltip: closeTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ]),
      ),
    );
  }
}
