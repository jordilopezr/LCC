// An RDP tunnel that fails has to say so — the same defect a43b816 fixed for
// VNC. `launchRDP` returned void and did `return` when the tunnel did not come
// up, and the Overview button did not await it: a project whose firewall does
// not open 3389 would see exactly what the VNC user saw on 2026-10-01, which
// was nothing at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/rdp_client.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
import 'package:linux_cloud_connector/src/services/storage_service.dart';

ProjectAwareInstance _fakeVm() => const ProjectAwareInstance(
      projectId: 'my-project-id',
      instance: GcpInstance(
        name: 'windows-server',
        status: 'RUNNING',
        zone: 'us-central1-f',
        machineType: 'e2-standard-4',
        cpuCount: 4,
        memoryMb: 16384,
        diskGb: 100,
        labels: [],
        osLoginEnabled: false,
        isWindows: true,
      ),
    );

/// A tunnel that failed the way a closed firewall fails: IAP answered, but
/// could not reach the VM's port.
class _BackendUnreachableNotifier extends ConnectionsNotifier {
  @override
  Future<bool> launchRDP(String projectId, String zone, String instanceName,
      {RdpSettings? settings}) async {
    state = {
      ...state,
      makeTunnelKey(instanceName, 3389): const TunnelState(
        status: 'error',
        remotePort: 3389,
        error: '3389',
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

Future<void> _pressConnectRdp(WidgetTester tester, AppLocalizations en) async {
  final rdpButton = find.text(en.dashboardConnectRdpButton);
  expect(rdpButton, findsOneWidget);
  await tester.ensureVisible(rdpButton);
  await tester.tap(rdpButton);
  await tester.pumpAndSettle();
  // The RDP settings dialog; accept it as it comes.
  await tester.tap(find.text(en.commonConnect));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    // The RDP settings dialog reads saved credentials through it.
    await StorageService().init();
  });

  testWidgets('an RDP tunnel that fails is reported, not swallowed',
      (tester) async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpOverview(tester);

    await _pressConnectRdp(tester, en);

    // The tunnel cannot be built here (no native lib), which is the same shape
    // of failure as a port IAP cannot reach: the user must be told.
    expect(find.text(en.customTunnelFailedTitle), findsOneWidget,
        reason: 'pressing Connect on an RDP tunnel that fails must not be silent');
  });

  testWidgets('a port IAP cannot reach names 3389, without the VNC-only hint',
      (tester) async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpOverview(tester, overrides: [
      activeConnectionsProvider.overrideWith(_BackendUnreachableNotifier.new),
    ]);

    await _pressConnectRdp(tester, en);

    expect(find.text(en.tunnelErrorBackendUnreachable('3389')), findsOneWidget);
    // RDP listens on every interface; the localhost hint would point the user
    // away from the firewall, which is the real answer here.
    expect(find.text(en.customTunnelLocalhostHint), findsNothing);
  });
}
