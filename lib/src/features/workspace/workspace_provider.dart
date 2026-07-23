import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../gcloud_provider.dart';
import 'workspace_session.dart';

class WorkspaceState {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  const WorkspaceState({this.sessions = const [], this.activeId});

  WorkspaceState copyWith({List<WorkspaceSession>? sessions, String? activeId}) =>
      WorkspaceState(
        sessions: sessions ?? this.sessions,
        activeId: activeId ?? this.activeId,
      );
}

final workspaceProvider =
    NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  int _counter = 0;
  final Map<String, int> _tunnelRefs = {};

  @override
  WorkspaceState build() => const WorkspaceState();

  String _newId() => 'session-${_counter++}';

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
    state = WorkspaceState(sessions: remaining, activeId: nextActive);
  }

  void reorder(int oldIndex, int newIndex) {
    final list = [...state.sessions];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    state = state.copyWith(sessions: list);
  }

  bool get hasLiveSessions =>
      state.sessions.any((s) => s.type != SessionType.overview);
}
