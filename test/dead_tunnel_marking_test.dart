import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

void main() {
  final now = DateTime(2026, 9, 17, 12, 0);

  TunnelState connected() => TunnelState(
        status: 'connected',
        port: 8443,
        remotePort: 8443,
        createdAt: DateTime(2026, 9, 17, 11, 0),
        projectId: 'p',
        zone: 'z',
        engine: 'native',
      );

  group('markDeadTunnels', () {
    // The zombie, seen from the UI: Rust reaped the forward because its SSH
    // session died, and the tunnel manager kept showing it green because
    // nobody listened to the list of reaped keys.
    test('a reaped forward is marked with a code the UI can localize', () {
      final state = {'sshfwd:vm1:8443': connected()};

      final marked = markDeadTunnels(state, ['sshfwd:vm1:8443'], now);

      expect(marked['sshfwd:vm1:8443']!.status, 'error');
      expect(marked['sshfwd:vm1:8443']!.errorCode, 'session_lost');
      expect(marked['sshfwd:vm1:8443']!.lastHealthCheck, now);
    });

    // What the user needs to reconnect must survive being marked dead: the
    // ports it was using, and the project/zone the reconnect needs.
    test('marking keeps what a reconnect needs', () {
      final marked = markDeadTunnels({'sshfwd:vm1:8443': connected()}, ['sshfwd:vm1:8443'], now);
      final s = marked['sshfwd:vm1:8443']!;

      expect(s.port, 8443);
      expect(s.remotePort, 8443);
      expect(s.projectId, 'p');
      expect(s.zone, 'z');
      expect(s.createdAt, DateTime(2026, 9, 17, 11, 0));
    });

    // A dead row is the one somebody diagnoses, and the first question is
    // which engine it was running on. Dropping the engine here would blank the
    // tag at exactly that moment.
    test('marking keeps the engine that held the entry', () {
      final marked = markDeadTunnels({'sshfwd:vm1:8443': connected()}, ['sshfwd:vm1:8443'], now);

      expect(marked['sshfwd:vm1:8443']!.engine, 'native');
    });

    test('tunnels that are still alive are left exactly as they were', () {
      final alive = connected();
      final state = {'vm1:3389': alive, 'sshfwd:vm2:8443': connected()};

      final marked = markDeadTunnels(state, ['sshfwd:vm2:8443'], now);

      expect(identical(marked['vm1:3389'], alive), isTrue);
      expect(marked['vm1:3389']!.status, 'connected');
    });

    // Rust reaps by key and knows nothing about what the UI is showing. A key
    // the UI never had must not conjure an entry out of nowhere.
    test('a reaped key the UI does not know is ignored', () {
      final marked = markDeadTunnels({'vm1:3389': connected()}, ['sshfwd:ghost:22'], now);

      expect(marked.containsKey('sshfwd:ghost:22'), isFalse);
      expect(marked.length, 1);
    });

    // The reconnect flow stops the old tunnel in Rust itself, so its key can
    // show up in the reap list while the UI is mid-retry. Marking it 'error'
    // there would cancel a reconnection that is still running.
    test('a tunnel that is reconnecting is left to the reconnect flow', () {
      final retrying = TunnelState(status: 'reconnecting', remotePort: 3389, projectId: 'p', zone: 'z', engine: null);

      final marked = markDeadTunnels({'vm1:3389': retrying}, ['vm1:3389'], now);

      expect(marked['vm1:3389']!.status, 'reconnecting');
    });

    test('an empty reaped list changes nothing', () {
      final state = {'vm1:3389': connected()};
      expect(markDeadTunnels(state, const [], now), equals(state));
    });
  });
}
