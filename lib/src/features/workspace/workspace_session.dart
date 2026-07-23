import '../gcloud_provider.dart';

enum SessionType { overview, ssh, sftp }

class WorkspaceSession {
  final String id;
  final SessionType type;
  final ProjectAwareInstance target;

  const WorkspaceSession({
    required this.id,
    required this.type,
    required this.target,
  });

  String get vmKey => target.uniqueKey;
}
