// Sprint 16: VM Snapshot Manager — Riverpod provider

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/snapshots.dart';

export '../bridge/api.dart/snapshots.dart' show GcpSnapshot;

class SnapshotNotifier extends AsyncNotifier<List<GcpSnapshot>> {
  String? _projectId;
  String? _zone;
  String? _instanceName;

  void setInstance(String projectId, String zone, String instanceName) {
    _projectId = projectId;
    _zone = zone;
    _instanceName = instanceName;
    ref.invalidateSelf();
  }

  @override
  Future<List<GcpSnapshot>> build() async {
    if (_projectId == null || _zone == null || _instanceName == null) return [];
    return listSnapshots(
      projectId: _projectId!,
      zone: _zone!,
      instanceName: _instanceName!,
    );
  }

  Future<void> createSnapshotForInstance(
      String snapshotName, String description) async {
    await createSnapshot(
      projectId: _projectId!,
      zone: _zone!,
      instanceName: _instanceName!,
      snapshotName: snapshotName,
      description: description,
    );
    ref.invalidateSelf();
  }

  Future<void> deleteSnapshotByName(String snapshotName) async {
    await deleteSnapshot(
      projectId: _projectId!,
      snapshotName: snapshotName,
    );
    ref.invalidateSelf();
  }

  Future<void> createDiskFromSnapshotByName(
      String snapshotName, String newDiskName) async {
    await createDiskFromSnapshot(
      projectId: _projectId!,
      zone: _zone!,
      snapshotName: snapshotName,
      newDiskName: newDiskName,
    );
    // Does not invalidate — list of snapshots is unchanged
  }
}

final snapshotProvider =
    AsyncNotifierProvider<SnapshotNotifier, List<GcpSnapshot>>(
        SnapshotNotifier.new);
