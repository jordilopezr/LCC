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
    return SizedBox(
      height: 40,
      child: _ScrollableTabs(
          sessions: sessions, activeId: activeId, notifier: notifier),
    );
  }
}

class _ScrollableTabs extends StatefulWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _ScrollableTabs(
      {required this.sessions, required this.activeId, required this.notifier});

  @override
  State<_ScrollableTabs> createState() => _ScrollableTabsState();
}

class _ScrollableTabsState extends State<_ScrollableTabs> {
  final ScrollController _controller = ScrollController();
  final Map<String, GlobalKey> _tabKeys = {};
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_recomputeOverflow);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeOverflow();
      _ensureActiveVisible();
    });
  }

  @override
  void didUpdateWidget(covariant _ScrollableTabs old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeOverflow();
      if (old.activeId != widget.activeId) _ensureActiveVisible();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _recomputeOverflow() {
    if (!_controller.hasClients) return;
    final can = _controller.position.maxScrollExtent > 0;
    if (can != _overflow) setState(() => _overflow = can);
  }

  void _ensureActiveVisible() {
    final id = widget.activeId;
    if (id == null) return;
    final key = _tabKeys[id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 200), alignment: 0.5);
    }
  }

  void _step(double delta) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + delta)
        .clamp(0.0, _controller.position.maxScrollExtent);
    _controller.animateTo(target,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  GlobalKey _keyFor(String id) => _tabKeys.putIfAbsent(id, () => GlobalKey());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(children: [
      if (_overflow)
        IconButton(
          key: const ValueKey('scroll-left'),
          icon: const Icon(Icons.chevron_left, size: 18),
          tooltip: l10n.workspaceScrollTabsLeft,
          visualDensity: VisualDensity.compact,
          onPressed: () => _step(-160),
        ),
      Expanded(
        child: ListView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          children: [
            for (final s in widget.sessions)
              KeyedSubtree(
                key: _keyFor(s.id),
                child: _Tab(
                  label: _tabLabel(context, s),
                  active: s.id == widget.activeId,
                  onTap: () => widget.notifier.focus(s.id),
                  onClose: () => widget.notifier.close(s.id),
                  closeTooltip: l10n.workspaceCloseTab,
                ),
              ),
          ],
        ),
      ),
      if (_overflow)
        IconButton(
          key: const ValueKey('scroll-right'),
          icon: const Icon(Icons.chevron_right, size: 18),
          tooltip: l10n.workspaceScrollTabsRight,
          visualDensity: VisualDensity.compact,
          onPressed: () => _step(160),
        ),
      PopupMenuButton<String>(
        key: const ValueKey('all-tabs-menu'),
        icon: const Icon(Icons.keyboard_arrow_down, size: 18),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          minimumSize: Size.zero,
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        tooltip: l10n.workspaceAllTabs,
        onSelected: widget.notifier.focus,
        itemBuilder: (context) => [
          for (final s in widget.sessions)
            PopupMenuItem<String>(
              value: s.id,
              child: Text(_tabLabel(context, s)),
            ),
        ],
      ),
    ]);
  }
}

String _tabLabel(BuildContext context, WorkspaceSession s) {
  final l10n = AppLocalizations.of(context);
  final kind = switch (s.type) {
    SessionType.overview => l10n.workspaceTabOverview,
    SessionType.ssh => l10n.workspaceTabSsh,
    SessionType.sftp => l10n.workspaceTabSftp,
  };
  return '${s.target.name} · $kind';
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
