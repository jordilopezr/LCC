// A VNC tunnel that fails has to say so.
//
// The app already knows exactly what went wrong — `tunnelErrorBackendUnreachable`
// names the port and the 35.235.240.0/20 range IAP comes from — but on
// 2026-10-01 a VM whose project had no firewall rule for 5900 failed four
// times and the user saw nothing at all: `launchVNC` returned in silence and
// the button did not await it. The error was only visible by opening the
// tunnel manager, which is not where anyone looks after pressing Connect.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/vnc_display.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/vnc_client.dart';

ProjectAwareInstance _fakeVm() => const ProjectAwareInstance(
      projectId: 'my-project-id',
      instance: GcpInstance(
        name: 'application-server',
        status: 'RUNNING',
        zone: 'us-central1-f',
        machineType: 'e2-standard-4',
        cpuCount: 4,
        memoryMb: 16384,
        diskGb: 100,
        labels: [],
        osLoginEnabled: false,
        isWindows: false,
      ),
    );

/// A tunnel that failed the way the real one did: IAP answered, but could not
/// reach the VM's port. Used to check the user is told *that*, and not merely
/// told something.
class _BackendUnreachableNotifier extends ConnectionsNotifier {
  @override
  Future<bool> launchVNC(String projectId, String zone, String instanceName,
      {VncSettings? settings, int display = 0}) async {
    final key = makeTunnelKey(instanceName, vncPortForDisplay(display));
    state = {
      ...state,
      key: TunnelState(
        status: 'error',
        remotePort: vncPortForDisplay(display),
        error: '${vncPortForDisplay(display)}',
        errorCode: 'backend_unreachable',
        engine: null,
      ),
    };
    return false;
  }
}

Future<void> _pumpOverview(WidgetTester tester,
    {List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OverviewTab(target: _fakeVm())),
      ),
    ),
  );
  // Providers that reach the Rust bridge throw here (the native lib is not
  // linked into `flutter test`); the frame still lays out.
  await tester.pump(const Duration(milliseconds: 100));
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a VNC tunnel that fails is reported, not swallowed',
      (tester) async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpOverview(tester);

    final vncButton = find.text(en.dashboardConnectVncButton);
    expect(vncButton, findsOneWidget);
    await tester.ensureVisible(vncButton);
    await tester.tap(vncButton);
    await tester.pumpAndSettle();

    // The settings dialog opens on :0, the display this VM is remembered on.
    expect(find.text(en.appVncConnectionSettingsTitle), findsOneWidget);
    await tester.tap(find.text(en.commonConnect));
    await tester.pumpAndSettle();

    // The tunnel cannot be built here (no native lib), which is the same shape
    // of failure as a port IAP cannot reach: the user must be told.
    expect(find.text(en.customTunnelFailedTitle), findsOneWidget,
        reason: 'pressing Connect on a VNC tunnel that fails must not be silent');
  });

  testWidgets('a port IAP cannot reach names the port and the way out',
      (tester) async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpOverview(tester, overrides: [
      activeConnectionsProvider
          .overrideWith(_BackendUnreachableNotifier.new),
    ]);

    final vncButton = find.text(en.dashboardConnectVncButton);
    await tester.ensureVisible(vncButton);
    await tester.tap(vncButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.commonConnect));
    await tester.pumpAndSettle();

    // The firewall answer, naming the port and the range IAP comes from.
    expect(find.text(en.tunnelErrorBackendUnreachable('5900')), findsOneWidget);
    // And the other half: a viewer bound to 127.0.0.1 fails identically.
    expect(find.text(en.customTunnelLocalhostHint), findsOneWidget);
  });
}
