import '../gcloud_provider.dart';

enum SessionType { overview, ssh, sftp }

class WorkspaceSession {
  final String id;
  final SessionType type;
  final ProjectAwareInstance target;
  final bool pinned;
  final String? groupId;

  const WorkspaceSession({
    required this.id,
    required this.type,
    required this.target,
    this.pinned = false,
    this.groupId,
  });

  String get vmKey => target.uniqueKey;

  WorkspaceSession copyWith({bool? pinned, String? groupId, bool clearGroup = false}) =>
      WorkspaceSession(
        id: id,
        type: type,
        target: target,
        pinned: pinned ?? this.pinned,
        groupId: clearGroup ? null : (groupId ?? this.groupId),
      );
}
