import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'workspace_provider.dart';
import 'workspace_session.dart';
import 'workspace_group.dart';
import 'group_color_theme.dart';
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
      _TabStrip(
          sessions: ws.sessions,
          groups: ws.groups,
          activeId: ws.activeId,
          notifier: notifier),
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
  final List<WorkspaceGroup> groups;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _TabStrip(
      {required this.sessions,
      required this.groups,
      required this.activeId,
      required this.notifier});

  @override
  Widget build(BuildContext context) {
    final pinned = sessions.where((s) => s.pinned).toList();
    final rest = sessions.where((s) => !s.pinned).toList();
    return SizedBox(
      height: 40,
      child: Row(children: [
        if (pinned.isNotEmpty)
          _PinnedZone(
              sessions: pinned,
              groups: groups,
              activeId: activeId,
              notifier: notifier),
        Expanded(
          child: _ScrollableTabs(
              sessions: rest,
              groups: groups,
              activeId: activeId,
              notifier: notifier),
        ),
      ]),
    );
  }
}

class _PinnedZone extends StatelessWidget {
  final List<WorkspaceSession> sessions;
  final List<WorkspaceGroup> groups;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _PinnedZone(
      {required this.sessions,
      required this.groups,
      required this.activeId,
      required this.notifier});

  IconData _icon(SessionType t) => switch (t) {
        SessionType.overview => Icons.dashboard_outlined,
        SessionType.ssh => Icons.terminal,
        SessionType.sftp => Icons.folder_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('pinned-zone'),
      decoration: BoxDecoration(
        border: Border(
            right: BorderSide(color: scheme.outlineVariant, width: 2)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final s in sessions)
          _TabContextMenu(
            session: s,
            notifier: notifier,
            groups: groups,
            child: InkWell(
              key: ValueKey('pinned-tab-${s.id}'),
              onTap: () => notifier.focus(s.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: s.id == activeId ? scheme.primary : Colors.transparent,
                    ),
                  ),
                ),
                child: Icon(_icon(s.type), size: 16),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Wraps a tab with a right-click (secondary-tap) context menu.
class _TabContextMenu extends StatelessWidget {
  final WorkspaceSession session;
  final WorkspaceNotifier notifier;
  final List<WorkspaceGroup> groups;
  final Widget child;
  const _TabContextMenu(
      {required this.session,
      required this.notifier,
      required this.groups,
      required this.child});

  Future<void> _show(BuildContext context, Offset pos) async {
    final l10n = AppLocalizations.of(context);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy, overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: [
        PopupMenuItem(
            value: 'pin',
            child: Text(session.pinned ? l10n.workspaceUnpinTab : l10n.workspacePinTab)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'newgroup', child: Text(l10n.workspaceNewGroup)),
        for (final g in groups)
          PopupMenuItem(
              value: 'addto:${g.id}',
              child: Text('${l10n.workspaceAddToGroup}: ${g.name}')),
        PopupMenuItem(value: 'groupvm', child: Text(l10n.workspaceGroupByVm)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'close', child: Text(l10n.workspaceCloseTab)),
        PopupMenuItem(value: 'others', child: Text(l10n.workspaceCloseOthers)),
        PopupMenuItem(value: 'right', child: Text(l10n.workspaceCloseToRight)),
      ],
    );
    if (value == null) return;
    if (value == 'pin') {
      notifier.togglePin(session.id);
    } else if (value == 'newgroup') {
      notifier.newGroupFromSession(session.id);
    } else if (value.startsWith('addto:')) {
      notifier.addToGroup(session.id, value.substring(6));
    } else if (value == 'groupvm') {
      notifier.groupByVm(session.vmKey);
    } else if (value == 'close') {
      notifier.close(session.id);
    } else if (value == 'others') {
      notifier.closeOthers(session.id);
    } else if (value == 'right') {
      notifier.closeToRight(session.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (d) => _show(context, d.globalPosition),
      child: child,
    );
  }
}

class _ScrollableTabs extends StatefulWidget {
  final List<WorkspaceSession> sessions;
  final List<WorkspaceGroup> groups;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _ScrollableTabs(
      {required this.sessions,
      required this.groups,
      required this.activeId,
      required this.notifier});

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

  List<Widget> _buildRow(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    final emitted = <String>{};
    for (final s in widget.sessions) {
      if (s.groupId != null) {
        if (!emitted.add(s.groupId!)) continue; // group already emitted
        final group = widget.groups.firstWhere((g) => g.id == s.groupId,
            orElse: () => WorkspaceGroup(
                id: s.groupId!, name: '', color: GroupColor.grey));
        final members =
            widget.sessions.where((m) => m.groupId == s.groupId).toList();
        widgets.add(_TabGroup(
          group: group,
          members: members,
          activeId: widget.activeId,
          notifier: widget.notifier,
          groups: widget.groups,
          tabKey: _keyFor,
          color: groupColor(group.color, scheme),
        ));
      } else {
        widgets.add(KeyedSubtree(
          key: _keyFor(s.id),
          child: _TabContextMenu(
            session: s,
            notifier: widget.notifier,
            groups: widget.groups,
            child: _Tab(
              label: _tabLabel(context, s),
              active: s.id == widget.activeId,
              onTap: () => widget.notifier.focus(s.id),
              onClose: () => widget.notifier.close(s.id),
              closeTooltip: l10n.workspaceCloseTab,
            ),
          ),
        ));
      }
    }
    return widgets;
  }

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
          children: _buildRow(context, l10n),
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
        // Shrunk to the icon's own bounds: a larger button (even
        // VisualDensity.compact) steals enough width to push the strip into
        // overflow at narrow panel widths. Small target is fine on desktop.
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

class _TabGroup extends StatelessWidget {
  final WorkspaceGroup group;
  final List<WorkspaceSession> members;
  final String? activeId;
  final WorkspaceNotifier notifier;
  final List<WorkspaceGroup> groups;
  final GlobalKey Function(String id) tabKey;
  final Color color;
  const _TabGroup(
      {required this.group,
      required this.members,
      required this.activeId,
      required this.notifier,
      required this.groups,
      required this.tabKey,
      required this.color});

  Future<void> _headerMenu(BuildContext context, Offset pos) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy, overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: [
        PopupMenuItem(value: 'rename', child: Text(l10n.workspaceRenameGroup)),
        for (final c in GroupColor.values)
          PopupMenuItem(
            value: 'color:${c.name}',
            child: Row(children: [
              Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: groupColor(c, Theme.of(context).colorScheme),
                      shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(c.name),
            ]),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'ungroup', child: Text(l10n.workspaceUngroup)),
        PopupMenuItem(value: 'close', child: Text(l10n.workspaceCloseGroup)),
      ],
    );
    if (value == null) return;
    if (value == 'rename') {
      if (!context.mounted) return;
      final name = await _promptName(context, group.name);
      if (name != null && name.isNotEmpty) notifier.renameGroup(group.id, name);
    } else if (value.startsWith('color:')) {
      final c = GroupColor.values.firstWhere((g) => g.name == value.substring(6));
      notifier.recolorGroup(group.id, c);
    } else if (value == 'ungroup') {
      notifier.ungroup(group.id);
    } else if (value == 'close') {
      notifier.closeGroup(group.id);
    }
  }

  Future<String?> _promptName(BuildContext context, String initial) {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.workspaceRenameGroupTitle),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: Text(l10n.commonOk)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onSecondaryTapUp: (d) => _headerMenu(context, d.globalPosition),
          onTap: () => _headerMenu(
              context,
              (context.findRenderObject() as RenderBox)
                  .localToGlobal(const Offset(0, 30))),
          child: Container(
            key: const ValueKey('group-header'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            height: 26,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(6)),
            alignment: Alignment.center,
            child: Text(group.name,
                style: TextStyle(
                    color: scheme.onPrimary, fontWeight: FontWeight.w600, fontSize: 12)),
          ),
        ),
        for (final s in members)
          KeyedSubtree(
            key: tabKey(s.id),
            child: _TabContextMenu(
              session: s,
              notifier: notifier,
              groups: groups,
              child: _Tab(
                label: _tabLabel(context, s),
                active: s.id == activeId,
                onTap: () => notifier.focus(s.id),
                onClose: () => notifier.close(s.id),
                closeTooltip: AppLocalizations.of(context).workspaceCloseTab,
              ),
            ),
          ),
      ]),
    );
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
