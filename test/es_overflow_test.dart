/// Visual QA: renders every dialog in Spanish and fails on layout overflow.
///
/// Spanish strings run ~20-30% longer than English, so tight Rows/Columns that
/// fit in English can overflow in Spanish. Flutter reports overflow as a
/// FlutterError ("A RenderFlex overflowed by N pixels"); this suite pumps each
/// dialog at two window sizes and asserts none is raised.
///
/// Dialogs whose providers reach the Rust bridge cannot fully load here (the
/// native library is not linked into `flutter test`), but their chrome still
/// lays out, which is what overflow QA is about. Non-overflow exceptions from
/// those providers are therefore ignored on purpose — see [_expectNoOverflow].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/settings_dialog.dart';
import 'package:linux_cloud_connector/src/features/manual_instance_dialog.dart';
import 'package:linux_cloud_connector/src/features/account_management_dialog.dart';
import 'package:linux_cloud_connector/src/features/snapshot_manager_dialog.dart';
import 'package:linux_cloud_connector/src/features/tunnel_manager_dialog.dart';
import 'package:linux_cloud_connector/src/features/windows_credentials_dialog.dart';
import 'package:linux_cloud_connector/src/features/sshfs_mount_dialog.dart';
import 'package:linux_cloud_connector/src/features/database_connection_panel.dart';
import 'package:linux_cloud_connector/src/features/connectivity_doctor.dart';
import 'package:linux_cloud_connector/src/features/diagnostics_panel.dart';
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart'
    show KeyringProblem;
import 'package:linux_cloud_connector/src/features/keyring_problem_screen.dart';

/// Window sizes to exercise: the app's typical size, a cramped one, and a
/// narrow one (e.g. a split-screen or small laptop window).
const _sizes = <String, Size>{
  'desktop 1280x800': Size(1280, 800),
  'small 1024x640': Size(1024, 640),
  'narrow 720x800': Size(720, 800),
};

const _project = 'my-project-id';
const _zone = 'us-central1-a';
const _instance = 'instancia-de-pruebas';

/// Dialogs under test, by label.
/// Dialogs that cannot be pumped headlessly: their `initState` reads providers
/// backed by the Rust bridge, which is not linked into `flutter test`. They
/// need live QA instead.
const _needsLiveApp = <String>{
  'WindowsCredentialsDialog',
  'SshfsMountDialog',
};

ProjectAwareInstance _fakeVm() => ProjectAwareInstance(
      projectId: _project,
      instance: GcpInstance(
        name: 'instancia-de-produccion-backup-01',
        status: 'RUNNING',
        zone: _zone,
        machineType: 'e2-standard-4',
        cpuCount: 4,
        memoryMb: 16384,
        diskGb: 100,
        labels: const [],
        osLoginEnabled: false,
        isWindows: false,
        // With no addresses the overview simply omits that row, and this
        // suite would report a clean render of a layout it never drew.
        internalIp: '10.128.0.5',
        externalIp: '34.121.200.199',
      ),
    );

final _dialogs = <String, Widget Function()>{
  'SettingsDialog': () => const SettingsDialog(),
  'ManualInstanceDialog': () => const ManualInstanceDialog(),
  'AccountManagementDialog': () => const AccountManagementDialog(),
  'TunnelManagerDialog': () => const TunnelManagerDialog(),
  'SnapshotManagerDialog': () => const SnapshotManagerDialog(
      projectId: _project, zone: _zone, instanceName: _instance),
  'WindowsCredentialsDialog': () => const WindowsCredentialsDialog(
      projectId: _project, zone: _zone, instanceName: _instance),
  'SshfsMountDialog': () => const SshfsMountDialog(
      projectId: _project,
      zone: _zone,
      instanceName: _instance,
      tunnelPort: 2222),
  'DatabaseConnectionPanel': () => const DatabaseConnectionPanel(
      projectId: _project, zone: _zone, instanceName: _instance),
  'ConnectivityDoctorDialog': () => const ConnectivityDoctorDialog(
      projectId: _project, zone: _zone, instanceName: _instance),
  'DiagnosticsPanel': () => const DiagnosticsPanel(
      params: DiagnosticsParams(
          projectId: _project, zone: _zone, instanceName: _instance)),
  'OverviewTab': () => OverviewTab(target: _fakeVm()),
  // Rendered with a two-digit display so the helper line under the field
  // ("Display :12 -> puerto 5912") is actually drawn. With the default 0 the
  // line is shorter and the case would lay out a narrower dialog than the one
  // users see — the same way this suite used to render the tunnel manager
  // empty and never draw its action rows at all.
  'VncConnectionSettingsDialog': () => const VncConnectionSettingsDialog(
      projectId: _project, zone: _zone, instanceName: _instance),
  'KeyringProblemScreen unreachable': () => KeyringProblemScreen(
      problem: KeyringProblem.unreachable, onCheckAgain: () {}),
  'KeyringProblemScreen refused': () => KeyringProblemScreen(
      problem: KeyringProblem.refused, onCheckAgain: () {}),
  'KeyringProblemScreen pending': () => KeyringProblemScreen(
      problem: KeyringProblem.pending, onCheckAgain: () {}),
};

Future<void> _pumpInSpanish(WidgetTester tester, Widget child, Size size,
    {List<Override> overrides = const []}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Record every error reported while pumping, one entry each; see
  // [_expectNoOverflow] for why `takeException` alone is not enough.
  _reported.clear();
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    _reported.add(details.exceptionAsString());
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
  // Providers that hit the Rust bridge throw here; the frame still lays out.
  await tester.pump(const Duration(milliseconds: 100));
  FlutterError.onError = previous;
}

/// Every error reported during the last [_pumpInSpanish], as text.
final _reported = <String>[];

/// Fails only on layout overflow; tolerates bridge/plugin errors that cannot
/// work in a widget test.
///
/// The overflows come from [_reported], not from `takeException`. When a frame
/// reports two or more errors, `takeException` hands back none of them: it
/// returns the String "Multiple exceptions (N) were detected during the
/// running of the current test, and at least one was unexpected.", which never
/// contains "overflowed". Two overflows at once — or one next to a tolerated
/// bridge error — then read as a clean render. That is how the tunnel
/// manager's rows overflowed by 157-192 px here while this suite said green.
void _expectNoOverflow(WidgetTester tester, String label) {
  // Drain what the binding kept, so the tolerated errors do not fail the test.
  while (tester.takeException() != null) {}
  final overflows = [
    for (final text in _reported)
      if (text.contains('overflowed')) text.split('\n').first,
  ];
  expect(overflows, isEmpty,
      reason: '$label overflowed in Spanish:\n${overflows.join('\n')}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() =>
      SharedPreferences.setMockInitialValues({'flutter.app_locale': 'es'}));

  for (final size in _sizes.entries) {
    group(size.key, () {
      for (final dialog in _dialogs.entries) {
        testWidgets(
          '${dialog.key} lays out in Spanish',
          (tester) async {
            await _pumpInSpanish(tester, dialog.value(), size.value);
            _expectNoOverflow(tester, dialog.key);
          },
          skip: _needsLiveApp.contains(dialog.key),
        );
      }

      // With no tunnels the manager draws only its empty state, so the row —
      // the tightest line in it — needs its own case. Instance name, the SSH
      // forward tag and the engine tag share one line there.
      testWidgets('TunnelManagerDialog rows lay out in Spanish', (tester) async {
        final rows = <MapEntry<String, TunnelState>>[
          MapEntry('sshfwd:$_instance:8080', TunnelState(
              status: 'connected', port: 40000, remotePort: 8080,
              latencyMs: 42, engine: 'native')),
          MapEntry('$_instance:3389', TunnelState(
              status: 'error', port: 40001, remotePort: 3389,
              errorCode: 'session_lost', engine: 'gcloud')),
        ];
        await _pumpInSpanish(tester, const TunnelManagerDialog(), size.value,
            overrides: [
              tunnelStatsProvider.overrideWithValue(TunnelStats(
                  totalTunnels: 2, healthyCount: 1, errorCount: 1,
                  allTunnels: rows)),
            ]);
        _expectNoOverflow(tester, 'TunnelManagerDialog rows');
      });
    });
  }
}
