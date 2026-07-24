import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../gcloud_provider.dart';
import 'workspace_group.dart';
import 'workspace_session.dart';

class WorkspaceState {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final List<WorkspaceGroup> groups;
  const WorkspaceState(
      {this.sessions = const [], this.activeId, this.groups = const []});

  WorkspaceState copyWith(
          {List<WorkspaceSession>? sessions,
          String? activeId,
          List<WorkspaceGroup>? groups}) =>
      WorkspaceState(
        sessions: sessions ?? this.sessions,
        activeId: activeId ?? this.activeId,
        groups: groups ?? this.groups,
      );

  WorkspaceSession? get activeSession {
    for (final s in sessions) {
      if (s.id == activeId) return s;
    }
    return null;
  }
}

final workspaceProvider =
    NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  int _counter = 0;
  int _groupCounter = 0;
  final Map<String, int> _tunnelRefs = {};

  @override
  WorkspaceState build() => const WorkspaceState();

  String _newId() => 'session-${_counter++}';
  String _newGroupId() => 'group-${_groupCounter++}';

  WorkspaceSession? _find(bool Function(WorkspaceSession) test) {
    for (final s in state.sessions) {
      if (test(s)) return s;
    }
    return null;
  }

  String _add(WorkspaceSession session, {bool holdsTunnel = false}) {
    if (holdsTunnel) {
      _tunnelRefs[session.vmKey] = (_tunnelRefs[session.vmKey] ?? 0) + 1;
    }
    state = state.copyWith(
      sessions: [...state.sessions, session],
      activeId: session.id,
    );
    return session.id;
  }

  String openOverview(ProjectAwareInstance vm) {
    final existing = _find(
        (s) => s.type == SessionType.overview && s.vmKey == vm.uniqueKey);
    if (existing != null) {
      focus(existing.id);
      return existing.id;
    }
    return _add(WorkspaceSession(
        id: _newId(), type: SessionType.overview, target: vm));
  }

  String openSsh(ProjectAwareInstance vm) => _add(
        WorkspaceSession(id: _newId(), type: SessionType.ssh, target: vm),
        holdsTunnel: true,
      );

  String openSftp(ProjectAwareInstance vm) {
    final existing =
        _find((s) => s.type == SessionType.sftp && s.vmKey == vm.uniqueKey);
    if (existing != null) {
      focus(existing.id);
      return existing.id;
    }
    return _add(
      WorkspaceSession(id: _newId(), type: SessionType.sftp, target: vm),
      holdsTunnel: true,
    );
  }

  void focus(String id) => state = state.copyWith(activeId: id);

  void close(String id) {
    final idx = state.sessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final session = state.sessions[idx];
    final remaining = [...state.sessions]..removeAt(idx);

    // Ref-count: release the VM's tunnel when its last live session goes away.
    if (session.type != SessionType.overview) {
      final key = session.vmKey;
      final left = (_tunnelRefs[key] ?? 1) - 1;
      if (left <= 0) {
        _tunnelRefs.remove(key);
        ref.read(activeConnectionsProvider.notifier)
            .disconnect(session.target.name, 22)
            .catchError((_) {});
      } else {
        _tunnelRefs[key] = left;
      }
    }

    // Keep a sensible active tab: neighbor of the closed one.
    String? nextActive = state.activeId;
    if (state.activeId == id) {
      if (remaining.isEmpty) {
        nextActive = null;
      } else {
        nextActive = remaining[idx > 0 ? idx - 1 : 0].id;
      }
    }
    state = WorkspaceState(
      sessions: remaining,
      activeId: nextActive,
      groups: _prunedGroups(remaining, state.groups),
    );
  }

  void reorderSession(String movedId, String targetId) {
    if (movedId == targetId) return;
    final list = [...state.sessions];
    final from = list.indexWhere((s) => s.id == movedId);
    if (from < 0) return;
    final moved = list.removeAt(from);
    final to = list.indexWhere((s) => s.id == targetId);
    list.insert(to < 0 ? list.length : to, moved);
    state = state.copyWith(sessions: _canonicalOrder(list));
  }

  /// Canonical visual order: pinned first (relative order preserved), then
  /// unpinned with same-group sessions clustered at the group's first
  /// appearance. Idempotent; preserves valid intra-zone reorders.
  List<WorkspaceSession> _canonicalOrder(List<WorkspaceSession> input) {
    final pinned = input.where((s) => s.pinned).toList();
    final unpinned = input.where((s) => !s.pinned).toList();
    final result = <WorkspaceSession>[...pinned];
    final emitted = <String>{};
    for (final s in unpinned) {
      if (s.groupId == null) {
        result.add(s);
        continue;
      }
      if (emitted.add(s.groupId!)) {
        result.addAll(unpinned.where((u) => u.groupId == s.groupId));
      }
    }
    return result;
  }

  void togglePin(String id) {
    final list = [
      for (final s in state.sessions)
        if (s.id == id)
          s.copyWith(pinned: !s.pinned, clearGroup: !s.pinned)
        else
          s,
    ];
    // Pinning clears the session's group, which may have emptied it.
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: _prunedGroups(list, state.groups),
    );
  }

  void closeOthers(String id) {
    final victims = state.sessions
        .where((s) => s.id != id && !s.pinned)
        .map((s) => s.id)
        .toList();
    for (final v in victims) {
      close(v);
    }
  }

  void closeToRight(String id) {
    final idx = state.sessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final victims = state.sessions
        .sublist(idx + 1)
        .where((s) => !s.pinned)
        .map((s) => s.id)
        .toList();
    for (final v in victims) {
      close(v);
    }
  }

  GroupColor _nextColor() {
    final used = state.groups.map((g) => g.color).toSet();
    for (final c in GroupColor.values) {
      if (!used.contains(c)) return c;
    }
    return GroupColor.values[state.groups.length % GroupColor.values.length];
  }

  /// Drops groups that no longer have any member session.
  List<WorkspaceGroup> _prunedGroups(List<WorkspaceSession> sessions,
      List<WorkspaceGroup> groups) {
    final live = sessions.map((s) => s.groupId).whereType<String>().toSet();
    return groups.where((g) => live.contains(g.id)).toList();
  }

  String newGroupFromSession(String id) {
    final session = _find((s) => s.id == id);
    if (session == null) return '';
    final group = WorkspaceGroup(
        id: _newGroupId(), name: session.target.name, color: _nextColor());
    final list = [
      for (final s in state.sessions)
        if (s.id == id) s.copyWith(pinned: false, groupId: group.id) else s,
    ];
    // Moving the session into a new group may have emptied its old one.
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: _prunedGroups(list, [...state.groups, group]),
    );
    return group.id;
  }

  void groupByVm(String vmKey) {
    final members =
        state.sessions.where((s) => !s.pinned && s.vmKey == vmKey).toList();
    if (members.isEmpty) return;
    final group = WorkspaceGroup(
        id: _newGroupId(), name: members.first.target.name, color: _nextColor());
    final memberIds = members.map((s) => s.id).toSet();
    final list = [
      for (final s in state.sessions)
        if (memberIds.contains(s.id)) s.copyWith(groupId: group.id) else s,
    ];
    // Members pulled into the new group may have emptied their old ones.
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: _prunedGroups(list, [...state.groups, group]),
    );
  }

  void addToGroup(String sessionId, String groupId) {
    final list = [
      for (final s in state.sessions)
        if (s.id == sessionId) s.copyWith(pinned: false, groupId: groupId) else s,
    ];
    // Moving the session out of its previous group may have emptied it.
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: _prunedGroups(list, state.groups),
    );
  }

  void removeFromGroup(String sessionId) {
    final list = [
      for (final s in state.sessions)
        if (s.id == sessionId) s.copyWith(clearGroup: true) else s,
    ];
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: _prunedGroups(list, state.groups),
    );
  }

  void renameGroup(String groupId, String name) {
    state = state.copyWith(
      groups: [
        for (final g in state.groups)
          if (g.id == groupId) g.copyWith(name: name) else g,
      ],
    );
  }

  void recolorGroup(String groupId, GroupColor color) {
    state = state.copyWith(
      groups: [
        for (final g in state.groups)
          if (g.id == groupId) g.copyWith(color: color) else g,
      ],
    );
  }

  void ungroup(String groupId) {
    final list = [
      for (final s in state.sessions)
        if (s.groupId == groupId) s.copyWith(clearGroup: true) else s,
    ];
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: state.groups.where((g) => g.id != groupId).toList(),
    );
  }

  void closeGroup(String groupId) {
    final victims = state.sessions
        .where((s) => s.groupId == groupId)
        .map((s) => s.id)
        .toList();
    for (final v in victims) {
      close(v);
    }
  }

  bool get hasLiveSessions =>
      state.sessions.any((s) => s.type != SessionType.overview);
}
