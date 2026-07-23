import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_session.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_provider.dart';

// Records disconnect() calls so we can assert the ref-count behavior without
// touching the Rust bridge.
class _FakeConnections extends ConnectionsNotifier {
  final List<(String, int)> disconnects = [];
  @override
  Map<String, TunnelState> build() => {};
  @override
  Future<void> disconnect(String instanceName, int remotePort) async {
    disconnects.add((instanceName, remotePort));
  }
}

ProjectAwareInstance _vm(String name) => ProjectAwareInstance(
      projectId: 'p',
      instance: GcpInstance(
        name: name, status: 'RUNNING', zone: 'z', machineType: 'm',
        cpuCount: 1, memoryMb: 1, diskGb: 1, labels: const [],
        osLoginEnabled: false, isWindows: false,
      ),
    );

void main() {
  late ProviderContainer container;
  late _FakeConnections fake;

  setUp(() {
    fake = _FakeConnections();
    container = ProviderContainer(overrides: [
      activeConnectionsProvider.overrideWith(() => fake),
    ]);
    addTearDown(container.dispose);
  });

  WorkspaceNotifier wn() => container.read(workspaceProvider.notifier);
  WorkspaceState ws() => container.read(workspaceProvider);

  test('openOverview dedups per VM; openSsh always adds', () {
    final a = _vm('vm1');
    wn().openOverview(a);
    wn().openOverview(a); // same VM → focus, no new tab
    expect(ws().sessions.where((s) => s.type == SessionType.overview).length, 1);
    wn().openSsh(a);
    wn().openSsh(a); // second SSH to same VM → new tab
    expect(ws().sessions.where((s) => s.type == SessionType.ssh).length, 2);
  });

  test('active id follows the most recently opened/focused tab', () {
    final a = _vm('vm1');
    final ov = wn().openOverview(a);
    final ssh = wn().openSsh(a);
    expect(ws().activeId, ssh);
    wn().focus(ov);
    expect(ws().activeId, ov);
  });

  test('tunnel closes only when the last SSH/SFTP session for a VM closes', () {
    final a = _vm('vm1');
    final s1 = wn().openSsh(a);
    final s2 = wn().openSsh(a);
    final f1 = wn().openSftp(a);
    wn().close(s1);
    wn().close(f1);
    expect(fake.disconnects, isEmpty); // still one SSH alive
    wn().close(s2);
    expect(fake.disconnects, [('vm1', 22)]); // last one → tunnel closed
  });

  test('overview close never touches the tunnel', () {
    final a = _vm('vm1');
    final ov = wn().openOverview(a);
    wn().close(ov);
    expect(fake.disconnects, isEmpty);
  });

  test('closing the active tab focuses a neighbor', () {
    final a = _vm('vm1');
    final s1 = wn().openSsh(a);
    final s2 = wn().openSsh(a);
    expect(ws().activeId, s2);
    wn().close(s2);
    expect(ws().activeId, s1);
  });

  test('hasLiveSessions ignores overview', () {
    final a = _vm('vm1');
    wn().openOverview(a);
    expect(wn().hasLiveSessions, false);
    wn().openSsh(a);
    expect(wn().hasLiveSessions, true);
  });
}
