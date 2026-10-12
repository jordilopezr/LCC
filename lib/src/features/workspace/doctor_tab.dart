import 'package:flutter/material.dart';
import '../connectivity_doctor.dart';
import 'workspace_session.dart';

/// Workspace tab that hosts the Connectivity Doctor for a VM. Holds no tunnel;
/// its report persists across tab switches via the panel's IndexedStack.
class DoctorTab extends StatelessWidget {
  final WorkspaceSession session;
  const DoctorTab({super.key, required this.session});

  @override
  Widget build(BuildContext context) => ConnectivityDoctorView(
        projectId: session.target.projectId,
        zone: session.target.zone,
        instanceName: session.target.name,
      );
}
