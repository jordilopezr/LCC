// The VNC display remembered per VM must survive being touched before the
// stored map has been read.
//
// `VncDisplayNotifier.build()` returns `{}` and reads the preferences without
// waiting. Measured on 2026-10-01: with `{vm-a: 1, vm-b: 2}` on disk, a
// `setDisplay` that arrived before that read landed wrote `{vm-c: 0}` over the
// whole map — vm-a and vm-b were gone from disk. The right-click menu did
// exactly that (first touch of the provider, then `launchVNC`, which saves the
// display it was given). And the Overview dialog prefilled its field from the
// same not-yet-read map, so it could show 0 for a VM saved on :1 and have the
// user confirm the 0.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/settings_provider.dart';
import 'package:linux_cloud_connector/src/features/vnc_display.dart';
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';

const _prefsKey = 'vnc_displays';

Future<Map<String, int>> _onDisk() async =>
    decodeVncDisplays((await SharedPreferences.getInstance()).getString(_prefsKey));

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VncDisplayNotifier', () {
    setUp(() => SharedPreferences.setMockInitialValues({
          _prefsKey: encodeVncDisplays({'p:z:vm-a': 1, 'p:z:vm-b': 2}),
        }));

    test('a display saved before the stored ones are read does not erase them',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      c.read(vncDisplayProvider); // first touch, as the right-click menu does
      await c.read(vncDisplayProvider.notifier).setDisplay('p:z:vm-c', 0);

      expect(await _onDisk(), {'p:z:vm-a': 1, 'p:z:vm-b': 2, 'p:z:vm-c': 0});
      expect(c.read(vncDisplayProvider),
          {'p:z:vm-a': 1, 'p:z:vm-b': 2, 'p:z:vm-c': 0});
    });

    test('displayFor waits for the stored displays instead of answering 0',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(await c.read(vncDisplayProvider.notifier).displayFor('p:z:vm-b'), 2);
    });
  });

  // The right-click menu: it used to call launchVNC with no display, so it
  // tunnelled 5900 and saved 0 over the display the user had set.
  test('the context menu launches on the display remembered for that VM',
      () async {
    final key = vncVmKey('proj', 'zone', 'vm');
    SharedPreferences.setMockInitialValues({
      _prefsKey: encodeVncDisplays({key: 1, 'p:z:other': 3}),
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final (_, port) = await c
        .read(activeConnectionsProvider.notifier)
        .launchVncRemembered('proj', 'zone', 'vm');

    expect(port, 5901, reason: 'display :1 is port 5901, not the old 5900');
    expect(await _onDisk(), {key: 1, 'p:z:other': 3},
        reason: 'launching from the menu must not rewrite what was saved');
  });

  // The third route: the dialog's field is filled in initState, the instant
  // it opens — before the stored map may have been read.
  testWidgets('the VNC dialog shows the display saved for this VM, not 0',
      (tester) async {
    final vm = _fakeVm();
    SharedPreferences.setMockInitialValues({
      _prefsKey: encodeVncDisplays({vncVmKey(vm.projectId, vm.zone, vm.name): 1}),
    });
    final en = await AppLocalizations.delegate.load(const Locale('en'));

    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OverviewTab(target: vm)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    for (var e = tester.takeException(); e != null; e = tester.takeException()) {}

    final vncButton = find.text(en.dashboardConnectVncButton);
    await tester.ensureVisible(vncButton);
    await tester.tap(vncButton);
    await tester.pumpAndSettle();

    bool fieldShows(String text) => tester
        .widgetList<EditableText>(find.byType(EditableText))
        .any((e) => e.controller.text == text);
    expect(fieldShows('1'), isTrue,
        reason: 'the field must show the display saved for this VM');
  });
}
