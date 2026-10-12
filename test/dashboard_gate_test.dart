import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart';
import 'package:linux_cloud_connector/src/features/dashboard_gate.dart';

AuthStatus _native({required bool authenticated, KeyringProblem? problem}) =>
    AuthStatus(
      gcloudInstalled: false,
      authenticated: authenticated,
      gcloudRequired: false,
      keyringProblem: problem,
    );

void main() {
  group('statusMapFor', () {
    test('each keyring problem survives the trip through the map', () {
      for (final problem in [...KeyringProblem.values, null]) {
        final map =
            statusMapFor(_native(authenticated: false, problem: problem));
        expect(keyringProblemIn(map), problem, reason: '$problem');
      }
    });

    test('keeps the keys the dashboard already reads', () {
      final map = statusMapFor(_native(authenticated: true));
      expect(map['authenticated'], isTrue);
      expect(map['installed'], isFalse);
      expect(map['gcloudRequired'], isFalse);
    });
  });

  group('dashboardGateFor', () {
    // With the keyring out of reach, authenticated is false too. If the
    // sign-in branch came first, the user would be sent to sign in again —
    // which could not store the credential either, while their session is
    // still saved.
    test('a keyring problem comes before signing in', () {
      for (final key in ['keyringUnreachable', 'keyringRefused', 'keyringPending']) {
        expect(
          dashboardGateFor({'authenticated': false, key: true}),
          DashboardGate.keyring,
          reason: key,
        );
      }
    });

    test('an entry gone from the keyring asks to sign in', () {
      expect(dashboardGateFor({'authenticated': false}), DashboardGate.signIn);
    });

    test('a missing gcloud on the gcloud route comes first', () {
      expect(
        dashboardGateFor({
          'gcloudRequired': true,
          'installed': false,
          'authenticated': false,
          'keyringRefused': true,
        }),
        DashboardGate.gcloudRequired,
      );
    });

    test('a readable session is ready', () {
      expect(dashboardGateFor({'authenticated': true}), DashboardGate.ready);
    });
  });
}
