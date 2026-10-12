import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';

ProjectAwareInstance _fakeVm() => ProjectAwareInstance(
      projectId: 'my-project-id',
      instance: GcpInstance(
        name: 'instancia-de-produccion-backup-01',
        status: 'RUNNING',
        zone: 'us-central1-a',
        machineType: 'e2-standard-4',
        cpuCount: 4,
        memoryMb: 16384,
        diskGb: 100,
        labels: const [],
        osLoginEnabled: false,
        isWindows: false,
      ),
    );

Future<void> _pumpOverview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OverviewTab(target: _fakeVm())),
      ),
    ),
  );
  // Providers that reach the Rust bridge throw here (the native lib is not
  // linked into `flutter test`); the frame still lays out. Drain those
  // non-fatal exceptions so they don't fail this test — headers/buttons use
  // the passed-in `target` + l10n and render regardless.
  await tester.pump(const Duration(milliseconds: 100));
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Overview actions render under 3 category headers',
      (tester) async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpOverview(tester);

    // The 3 category headers are present.
    expect(find.text(en.dashboardActionsGroupAccess), findsOneWidget);
    expect(find.text(en.dashboardActionsGroupPower), findsOneWidget);
    expect(find.text(en.dashboardActionsGroupTools), findsOneWidget);

    // A representative button from each group still renders.
    expect(find.text(en.dashboardConnectSshButton), findsWidgets); // Access
    expect(find.text(en.dashboardStartInstanceButton), findsWidgets); // Power
    expect(find.text(en.dashboardMenuDoctor), findsWidgets); // Tools
  });
}
