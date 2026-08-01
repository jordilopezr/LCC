import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/gcp_session_banner.dart';

Widget _wrap(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: GcpSessionBanner()),
      ),
    );

void main() {
  testWidgets('shows banner on auth error', (tester) async {
    await tester.pumpWidget(_wrap([
      projectsProvider.overrideWith((ref) => throw Exception(
          'Authentication failed: your Google Cloud session has expired or '
          'requires reauthentication.')),
      instancesProvider.overrideWith((ref) async => <GcpInstance>[]),
    ]));
    await tester.pump();
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('hidden when projects load fine', (tester) async {
    await tester.pumpWidget(_wrap([
      projectsProvider.overrideWith((ref) async => <GcpProject>[]),
      instancesProvider.overrideWith((ref) async => <GcpInstance>[]),
    ]));
    await tester.pump();
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(SizedBox), findsWidgets); // SizedBox.shrink()
  });
}
