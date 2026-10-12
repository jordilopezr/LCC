import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

void main() {
  TunnelState at(String status) => TunnelState(status: status, remotePort: 3389, engine: null);

  group('activeTunnelCount', () {
    // What the close warning is really asking: how much of the user's work
    // would this close interrupt. A tunnel in error carries nothing.
    test('counts only the tunnels that are carrying something', () {
      final count = activeTunnelCount({
        'vm1:3389': at('connected'),
        'sshfwd:vm1:8443': at('connected'),
        'vm2:22': at('error'),
        'vm3:22': at('reconnecting'),
        'vm4:22': at('connecting'),
      });

      expect(count, 2);
    });

    test('no tunnels at all is zero, not a crash', () {
      expect(activeTunnelCount(const {}), 0);
    });
  });

  group('closeWarning', () {
    // Three shapes, because a single combined number would hide what the user
    // is about to lose — a terminal tab and an RDP tunnel are not the same
    // thing to lose.
    test('no work in progress means no warning at all', () {
      expect(closeWarning(sessions: 0, tunnels: 0), CloseWarning.none);
    });

    test('sessions alone keep the wording they always had', () {
      expect(closeWarning(sessions: 2, tunnels: 0), CloseWarning.sessionsOnly);
    });

    // The case this whole change exists for: tunnels open, no session tabs.
    // Until now it closed silently, and since forwards started dying with the
    // app that silence costs the user a live RDP session.
    test('tunnels alone now warn, where they used to close in silence', () {
      expect(closeWarning(sessions: 0, tunnels: 1), CloseWarning.tunnelsOnly);
    });

    test('both together say both', () {
      expect(closeWarning(sessions: 1, tunnels: 1), CloseWarning.both);
    });
  });
}
