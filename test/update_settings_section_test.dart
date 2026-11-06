import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/updates/github_releases.dart';
import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/features/updates/update_checker.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';
import 'package:linux_cloud_connector/src/features/updates/update_settings_section.dart';
import 'package:linux_cloud_connector/src/version.dart';
import 'package:shared_preferences/shared_preferences.dart';

PublishedRelease _release(String tag) => PublishedRelease(
      tag: tag,
      prerelease: tag.contains('-preview.'),
      htmlUrl: '${kReleasesPagePrefix}tag/$tag',
    );

final _now = DateTime.utc(2026, 11, 6, 12);
const _installedTag = 'v27H1-preview.20261105.56';
const _newerPreview = 'v27H1-preview.20261106.1';

/// Pumps the section alone, at the width the settings dialog gives it, with
/// GitHub answered by [fetch].
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required ReleasesFetcher fetch,
  Locale locale = const Locale('en'),
  bool disabledByPackager = false,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      updateCheckDisabledProvider.overrideWithValue(disabledByPackager),
      releasesFetcherProvider.overrideWithValue(fetch),
      installedVersionProvider
          .overrideWithValue(ReleaseVersion.tryParseTag(_installedTag)!),
      updateCheckClockProvider.overrideWithValue(() => _now),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 500, child: UpdateSettingsSection()),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
      tester.element(find.byType(UpdateSettingsSection)));
}

Future<ReleasesResponse> _offersNewerPreview({String? etag}) async =>
    ReleasesFetched([_release(_installedTag), _release(_newerPreview)], null);

Future<ReleasesResponse> _unreachable({String? etag}) async =>
    throw const SocketException('Network is unreachable');

Future<ReleasesResponse> _neverAsked({String? etag}) async =>
    fail('the section must not check on its own');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('defaults: checking on, installed channel, not checked yet',
      (tester) async {
    await _pump(tester, fetch: _neverAsked);

    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
    final selected = tester
        .widgetList<RadioListTile<ReleaseChannel>>(
            find.byType(RadioListTile<ReleaseChannel>))
        // ignore: deprecated_member_use
        .where((tile) => tile.value == tile.groupValue)
        .single;
    expect(selected.value, kChannel);
    expect(find.text('Not checked yet'), findsOneWidget);
  });

  testWidgets('the switch and the channel are stored', (tester) async {
    await _pump(tester, fetch: _neverAsked);

    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('Stable'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('update_check_enabled'), isFalse);
    expect(prefs.getString('update_channel'), 'stable');
  });

  testWidgets('check now shows the release found and when', (tester) async {
    await _pump(tester, fetch: _offersNewerPreview);

    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();

    expect(find.text('27H1 Preview (build 20261106.1) is available.'),
        findsOneWidget);
    expect(find.textContaining('Last checked: Nov 6, 2026'), findsOneWidget);
    expect(find.text('View on GitHub'), findsOneWidget);
  });

  testWidgets('a newer preview is not offered on the stable channel',
      (tester) async {
    await _pump(tester, fetch: _offersNewerPreview);

    await tester.tap(find.text('Stable'));
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();

    expect(find.text('You have the latest version.'), findsOneWidget);
    expect(find.text('View on GitHub'), findsNothing);
  });

  testWidgets('the button is disabled while a check is in flight',
      (tester) async {
    final answer = Completer<ReleasesResponse>();
    await _pump(tester, fetch: ({String? etag}) => answer.future);

    await tester.tap(find.text('Check now'));
    await tester.pump();
    expect(find.text('Checking…'), findsOneWidget);
    final button = find.ancestor(
        of: find.text('Check now'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);

    answer.complete(ReleasesFetched([_release(_installedTag)], null));
    await tester.pumpAndSettle();
    expect(find.text('You have the latest version.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
  });

  testWidgets('a failed check now is shown', (tester) async {
    await _pump(tester, fetch: _unreachable);

    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not reach GitHub'), findsOneWidget);
  });

  // Nobody asked for an automatic check: its failure stays out of sight.
  testWidgets('a failed automatic check is not shown', (tester) async {
    final container = await _pump(tester, fetch: _unreachable);

    await container.read(updateCheckerProvider.notifier).checkNow();
    await tester.pumpAndSettle();

    expect(container.read(updateCheckerProvider).lastError, isNotNull);
    expect(find.textContaining('Could not reach GitHub'), findsNothing);
    expect(find.text('Not checked yet'), findsOneWidget);
  });

  // The longest state the section has, in the longer language.
  testWidgets('an available update lays out in Spanish', (tester) async {
    tester.view.physicalSize = const Size(720, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester,
        fetch: _offersNewerPreview, locale: const Locale('es'));

    await tester.tap(find.text('Buscar ahora'));
    await tester.pumpAndSettle();

    expect(
        find.text('27H1 Preview (compilación 20261106.1) está disponible.'),
        findsOneWidget);
    expect(find.text('Ver en GitHub'), findsOneWidget);
  });

  testWidgets('a packaged installation only says where updates come from',
      (tester) async {
    await _pump(tester, fetch: _neverAsked, disabledByPackager: true);

    expect(find.textContaining('gets its updates from the package'),
        findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Check now'), findsNothing);
  });

  group('describeRelease', () {
    late AppLocalizations l10n;
    setUpAll(() async =>
        l10n = await AppLocalizations.delegate.load(const Locale('en')));

    String describe(String tag) =>
        describeRelease(l10n, ReleaseVersion.tryParseTag(tag)!);

    test('names each kind of release', () {
      expect(describe('v27H2-preview.20270310.4'),
          '27H2 Preview (build 20270310.4)');
      expect(describe('v27H1'), '27H1 Stable');
      expect(describe('v27H1u2'), '27H1 Stable, update 2');
    });
  });
}
