import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/frb_generated.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_panel.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

// A minimal stand-in proving the load-bearing invariant: switching the visible
// index of an IndexedStack must NOT dispose the hidden child (that is what keeps
// a live SSH session alive). WorkspacePanel must use IndexedStack, not TabBarView.
class _Probe extends StatefulWidget {
  const _Probe({super.key});
  @override
  State<_Probe> createState() => _ProbeState();
}
int _disposes = 0;
class _ProbeState extends State<_Probe> {
  @override
  void dispose() { _disposes++; super.dispose(); }
  @override
  Widget build(BuildContext context) => const SizedBox();
}

ProjectAwareInstance _vm(String name) => ProjectAwareInstance(
      projectId: 'p',
      instance: GcpInstance(
        name: name, status: 'RUNNING', zone: 'z', machineType: 'm',
        cpuCount: 1, memoryMb: 1, diskGb: 1, labels: const [],
        osLoginEnabled: false, isWindows: false,
      ),
    );

Widget _host(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SizedBox(width: 300, height: 200, child: WorkspacePanel())),
      ),
    );

void main() {
  // `_ScrollableTabs` overflow test opens real SSH sessions, and
  // WorkspacePanel's IndexedStack mounts every session's widget eagerly
  // (that's the point of the IndexedStack invariant proven below), so
  // SshTerminalTab.initState reaches into the Rust bridge via getUsername().
  // Initialize it against the debug .so built by `cargo build` so that call
  // succeeds instead of throwing "flutter_rust_bridge has not been
  // initialized" as an unawaited/async error.
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        'native/target/debug/libnative.so',
      ),
    );
  });

  testWidgets('IndexedStack keeps hidden children mounted across index change',
      (tester) async {
    _disposes = 0;
    var index = 0;
    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      return MaterialApp(
        home: Column(children: [
          TextButton(
            onPressed: () => setState(() => index = 1),
            child: const Text('switch'),
          ),
          Expanded(
            child: IndexedStack(index: index, children: const [
              _Probe(key: ValueKey('a')),
              SizedBox(key: ValueKey('b')),
            ]),
          ),
        ]),
      );
    }));
    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    expect(_disposes, 0); // the hidden _Probe was NOT disposed
  });

  testWidgets('overflow arrows appear only when tabs exceed width', (tester) async {
    // The 300x200 host below is sized to force the tab strip to overflow
    // with a handful of tabs; that same narrow width also makes the real
    // OverviewTab/ResourceChip content (unrelated to this task) report
    // RenderFlex overflow warnings, which the test framework otherwise
    // promotes to test failures. Swallow only those layout-overflow
    // FlutterErrors for the duration of this test; anything else still fails
    // the test normally.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final message = details.exception.toString();
      if (message.contains('A RenderFlex overflowed')) return;
      previousOnError?.call(details);
    };
    final c = ProviderContainer();
    try {
      final wn = c.read(workspaceProvider.notifier);
      // One tab: no overflow, no arrows.
      wn.openOverview(_vm('vm1'));
      await tester.pumpWidget(_host(c));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scroll-left')), findsNothing);
      // Many tabs in a 300px panel: overflow, arrows visible.
      for (var i = 2; i <= 12; i++) {
        wn.openSsh(_vm('vm$i'));
      }
      await tester.pumpWidget(_host(c));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scroll-left')), findsOneWidget);
      expect(find.byKey(const ValueKey('scroll-right')), findsOneWidget);
    } finally {
      // Dispose synchronously (not via addTearDown) so ConnectionsNotifier's
      // health-check Timer.periodic is cancelled before the framework's
      // end-of-test pending-timer invariant check runs. In finally so a failed
      // expect() surfaces its own error instead of a pending-timer error.
      c.dispose();
      FlutterError.onError = previousOnError;
    }
  });

  testWidgets('all-tabs menu lists every tab and focuses on select',
      (tester) async {
    // Same rationale as the overflow test above: the 300px host triggers
    // RenderFlex overflow warnings from the real OverviewTab content, so
    // swallow only those FlutterErrors for the duration of this test.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final message = details.exception.toString();
      if (message.contains('A RenderFlex overflowed')) return;
      previousOnError?.call(details);
    };
    final c = ProviderContainer();
    try {
      final wn = c.read(workspaceProvider.notifier);
      wn.openOverview(_vm('alpha'));
      final beta = wn.openSsh(_vm('beta'));
      await tester.pumpWidget(_host(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('all-tabs-menu')));
      await tester.pumpAndSettle();
      expect(find.text('beta · SSH'), findsWidgets);
      await tester.tap(find.text('beta · SSH').last);
      await tester.pumpAndSettle();
      expect(c.read(workspaceProvider).activeId, beta);
    } finally {
      // Dispose synchronously (not via addTearDown) so ConnectionsNotifier's
      // health-check Timer.periodic is cancelled before the framework's
      // end-of-test pending-timer invariant check runs. In finally so a
      // failed expect() surfaces its own error instead of a pending-timer
      // error.
      c.dispose();
      FlutterError.onError = previousOnError;
    }
  });

  testWidgets('pinned tab renders in the pinned zone, out of the scroll list',
      (tester) async {
    // Same rationale as the overflow/all-tabs tests above: the 300px host
    // triggers RenderFlex overflow warnings from the real OverviewTab
    // content, so swallow only those FlutterErrors for the duration of this
    // test.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final message = details.exception.toString();
      if (message.contains('A RenderFlex overflowed')) return;
      previousOnError?.call(details);
    };
    final c = ProviderContainer();
    try {
      final wn = c.read(workspaceProvider.notifier);
      final s = wn.openSsh(_vm('gamma'));
      wn.togglePin(s);
      await tester.pumpWidget(_host(c));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pinned-zone')), findsOneWidget);
      expect(find.byKey(ValueKey('pinned-tab-$s')), findsOneWidget);
    } finally {
      // Dispose synchronously (not via addTearDown) so ConnectionsNotifier's
      // health-check Timer.periodic is cancelled before the framework's
      // end-of-test pending-timer invariant check runs. In finally so a
      // failed expect() surfaces its own error instead of a pending-timer
      // error.
      c.dispose();
      FlutterError.onError = previousOnError;
    }
  });
}
