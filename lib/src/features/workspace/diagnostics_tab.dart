import 'package:flutter/material.dart';
import '../diagnostics_panel.dart';
import 'workspace_session.dart';

/// Workspace tab that hosts the Diagnostics panel for a VM. Holds no tunnel;
/// its sub-tab state persists across tab switches via the panel's IndexedStack.
class DiagnosticsTab extends StatelessWidget {
  final WorkspaceSession session;
  const DiagnosticsTab({super.key, required this.session});

  @override
  Widget build(BuildContext context) => DiagnosticsView(
        params: DiagnosticsParams(
          projectId: session.target.projectId,
          zone: session.target.zone,
          instanceName: session.target.name,
        ),
      );
}
