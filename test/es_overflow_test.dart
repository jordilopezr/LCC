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

/// Window sizes to exercise: the app's typical size and a cramped one.
const _sizes = <String, Size>{
  'desktop 1280x800': Size(1280, 800),
  'small 1024x640': Size(1024, 640),
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
};

Future<void> _pumpInSpanish(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
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
}

/// Fails only on layout overflow; tolerates bridge/plugin errors that cannot
/// work in a widget test.
void _expectNoOverflow(WidgetTester tester, String label) {
  final overflows = <String>[];
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {
    final text = e.toString();
    if (text.contains('overflowed')) overflows.add(text.split('\n').first);
  }
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
    });
  }
}
