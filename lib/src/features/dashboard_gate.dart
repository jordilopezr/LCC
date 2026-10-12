import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart'
    show AuthStatus, KeyringProblem;

/// What the dashboard body shows, decided from [gcloudStatusProvider]'s map.
enum DashboardGate { gcloudRequired, keyring, signIn, ready }

/// The auth status as the flat map the dashboard reads. The keyring problem
/// travels as three booleans so the map keeps its `Map<String, bool>` shape.
Map<String, bool> statusMapFor(AuthStatus status) {
  final problem = status.keyringProblem;
  return {
    'installed': status.gcloudInstalled,
    'authenticated': status.authenticated,
    'gcloudRequired': status.gcloudRequired,
    'keyringUnreachable': problem == KeyringProblem.unreachable,
    'keyringRefused': problem == KeyringProblem.refused,
    'keyringPending': problem == KeyringProblem.pending,
  };
}

/// The keyring problem carried by [statusMapFor]'s map, if any.
KeyringProblem? keyringProblemIn(Map<String, bool> status) {
  if (status['keyringUnreachable'] == true) return KeyringProblem.unreachable;
  if (status['keyringRefused'] == true) return KeyringProblem.refused;
  if (status['keyringPending'] == true) return KeyringProblem.pending;
  return null;
}

/// Which screen the dashboard shows. The order is the point: a keyring
/// problem comes before "sign in", because with the keyring out of reach
/// `authenticated` is false as well, and signing in again could not store the
/// credential either — the session is still saved.
DashboardGate dashboardGateFor(Map<String, bool> status) {
  if (status['gcloudRequired'] == true && status['installed'] != true) {
    return DashboardGate.gcloudRequired;
  }
  if (keyringProblemIn(status) != null) return DashboardGate.keyring;
  if (status['authenticated'] != true) return DashboardGate.signIn;
  return DashboardGate.ready;
}
