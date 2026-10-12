import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/tunnel_manager_dialog.dart';

/// The tunnel manager says which engine holds each entry. Two diagnoses went
/// down the wrong path because a native tunnel and a gcloud one looked
/// identical here.
void main() {
  group('tunnelEngineLabel', () {
    // The same words Settings uses for the choice the user made, so the tag
    // answers "which of my two options is carrying this?".
    test('names both engines in English', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(tunnelEngineLabel(l10n, 'native'), 'Native');
      expect(tunnelEngineLabel(l10n, 'gcloud'), 'gcloud');
    });

    test('names both engines in Spanish', () {
      final l10n = lookupAppLocalizations(const Locale('es'));
      expect(tunnelEngineLabel(l10n, 'native'), 'Nativo');
      expect(tunnelEngineLabel(l10n, 'gcloud'), 'gcloud');
    });

    // No engine — a failed start holds nothing — and an engine this build
    // does not know both mean no tag, never a raw identifier on screen.
    test('an unknown or missing engine has no label', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(tunnelEngineLabel(l10n, null), isNull);
      expect(tunnelEngineLabel(l10n, 'wat'), isNull);
    });
  });

  group('tunnel manager row', () {
    Future<void> pumpManager(WidgetTester tester, Map<String, TunnelState> rows) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final sorted = rows.entries.toList();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tunnelStatsProvider.overrideWithValue(TunnelStats(
              totalTunnels: sorted.length,
              healthyCount: sorted.length,
              allTunnels: sorted,
            )),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: TunnelManagerDialog()),
          ),
        ),
      );
    }

    TunnelState connected(String? engine) => TunnelState(
          status: 'connected',
          port: 40000,
          remotePort: 3389,
          engine: engine,
        );

    testWidgets('each row shows the engine holding it', (tester) async {
      await pumpManager(tester, {
        'vm-a:3389': connected('native'),
        'sshfwd:vm-b:8080': connected('gcloud'),
      });

      expect(find.text('Native'), findsOneWidget);
      expect(find.text('gcloud'), findsOneWidget);
      expect(find.byTooltip('Engine used for this connection'), findsNWidgets(2));
    });

    // A start that failed holds nothing, but the engine that tried is the
    // first thing a diagnosis needs — the row in error names it too.
    testWidgets('a row whose start failed names the engine that failed', (tester) async {
      await pumpManager(tester, {
        'vm-a:3389': const TunnelState(
          status: 'error',
          remotePort: 3389,
          errorCode: 'firewall_blocked',
          engine: 'gcloud',
        ),
      });

      expect(find.text('gcloud'), findsOneWidget);
      expect(find.byTooltip('Engine used for this connection'), findsOneWidget);
    });

    testWidgets('a row with no engine shows no engine tag', (tester) async {
      await pumpManager(tester, {'vm-a:3389': connected(null)});

      expect(find.text('Native'), findsNothing);
      expect(find.text('gcloud'), findsNothing);
      expect(find.byTooltip('Engine used for this connection'), findsNothing);
    });
  });
}
