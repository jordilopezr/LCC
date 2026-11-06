import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/updates/github_releases.dart';
import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/features/updates/update_banner.dart';
import 'package:linux_cloud_connector/src/features/updates/update_checker.dart';
import 'package:linux_cloud_connector/src/features/updates/update_notice.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';
import 'package:linux_cloud_connector/src/version.dart';
import 'package:shared_preferences/shared_preferences.dart';

PublishedRelease _release(String tag) => PublishedRelease(
      tag: tag,
      prerelease: tag.contains('-preview.'),
      htmlUrl: '${kReleasesPagePrefix}tag/$tag',
    );

ReleaseVersion _v(String tag) => ReleaseVersion.tryParseTag(tag)!;

UpdateCheckResult _evaluate(String installed, List<String> tags,
        {ReleaseChannel? channel}) =>
    evaluateUpdate(
      installed: _v(installed),
      channel: channel ?? _v(installed).channel,
      releases: tags.map(_release),
    );

final _now = DateTime.utc(2026, 11, 6, 12);

/// Seeds the stored release list, as an earlier run would have left it, so
/// the checker has a result without asking GitHub.
void _seed(List<String> tags, {Map<String, Object> extra = const {}}) =>
    SharedPreferences.setMockInitialValues({
      'flutter.update_check_cache': encodeUpdateCheckCache(UpdateCheckCache(
          releases: tags.map(_release).toList(), etag: null, checkedAt: _now)),
      ...extra,
    });

Future<ReleasesResponse> _neverAsked({String? etag}) async =>
    fail('the result comes from the stored list');

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required String installed,
  List<String>? notified,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      releasesFetcherProvider.overrideWithValue(_neverAsked),
      installedVersionProvider.overrideWithValue(_v(installed)),
      updateCheckClockProvider.overrideWithValue(() => _now),
      updateDesktopNotifierProvider.overrideWithValue((notice, version) async {
        notified?.add(version);
      }),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Column(children: [child])),
    ),
  ));
  await tester.pumpAndSettle();
}

const _installed = 'v27H1-preview.20261105.56';
const _next = 'v27H1-preview.20261106.1';

void main() {
  group('updateNoticeFor', () {
    test('nothing to say when up to date or not checked', () {
      expect(updateNoticeFor(result: null), isNull);
      expect(updateNoticeFor(result: _evaluate(_installed, [_installed])),
          isNull);
    });

    test('a newer build, until it is skipped; then the next one', () {
      final result = _evaluate(_installed, [_installed, _next]);
      final notice = updateNoticeFor(result: result)!;
      expect(notice.tag, _next);
      expect(notice.unsupported, isFalse);
      expect(notice.newerStable, isNull);

      expect(updateNoticeFor(result: result, skippedTag: _next), isNull);
      final later = _evaluate(
          _installed, [_installed, _next, 'v27H1-preview.20261107.1']);
      expect(updateNoticeFor(result: later, skippedTag: _next)!.tag,
          'v27H1-preview.20261107.1');
    });

    // The edition being tested shipped stable; previews moved on.
    test('a preview user hears of the stable that shipped', () {
      final notice = updateNoticeFor(
          result: _evaluate(_installed,
              [_installed, 'v27H1', 'v27H2-preview.20270110.1']))!;
      expect(notice.tag, 'v27H2-preview.20270110.1');
      expect(notice.newerStable!.release.tag, 'v27H1');
    });

    test('an unsupported stable cannot be skipped', () {
      final result = _evaluate('v27H1u3', ['v27H1u3', 'v27H2']);
      final notice = updateNoticeFor(result: result, skippedTag: 'v27H2')!;
      expect(notice.tag, 'v27H2');
      expect(notice.unsupported, isTrue);
    });

    // Patches come from the stable release, not from the newest preview.
    test('an unsupported stable on the preview channel is sent to stable', () {
      final notice = updateNoticeFor(
          result: _evaluate(
              'v27H1', ['v27H1', 'v27H2', 'v28H1-preview.20270705.2'],
              channel: ReleaseChannel.preview))!;
      expect(notice.tag, 'v27H2');
      expect(notice.unsupported, isTrue);
      expect(notice.newerStable, isNull);
    });
  });

  group('UpdateBanner', () {
    testWidgets('offers the release; later hides it for this run',
        (tester) async {
      _seed([_installed, _next]);
      await _pump(tester, const UpdateBanner(), installed: _installed);

      expect(
          find.text('A new version of LCC is available: '
              '27H1 Preview (build 20261106.1).'),
          findsOneWidget);
      expect(find.text('View on GitHub'), findsOneWidget);
      expect(find.text('Skip this version'), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialBanner), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_skipped_tag'), isNull);
    });

    testWidgets('skip hides it and is remembered', (tester) async {
      _seed([_installed, _next]);
      await _pump(tester, const UpdateBanner(), installed: _installed);

      await tester.tap(find.text('Skip this version'));
      await tester.pumpAndSettle();

      expect(find.byType(MaterialBanner), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_skipped_tag'), _next);
    });

    testWidgets('a skipped release is not shown on the next start',
        (tester) async {
      _seed([_installed, _next], extra: {'flutter.update_skipped_tag': _next});
      await _pump(tester, const UpdateBanner(), installed: _installed);

      expect(find.byType(MaterialBanner), findsNothing);
    });

    testWidgets('an unsupported edition gets the stronger notice',
        (tester) async {
      _seed(['v27H1u3', 'v27H2'],
          extra: {'flutter.update_skipped_tag': 'v27H2'});
      await _pump(tester, const UpdateBanner(), installed: 'v27H1u3');

      expect(
          find.text('27H1 no longer receives security patches. '
              'Update to 27H2 Stable to keep getting fixes.'),
          findsOneWidget);
      expect(find.text('Skip this version'), findsNothing);
      expect(find.text('Later'), findsOneWidget);
    });

    testWidgets('mentions the stable a preview user could switch to',
        (tester) async {
      _seed([_installed, 'v27H1', 'v27H2-preview.20270110.1']);
      await _pump(tester, const UpdateBanner(), installed: _installed);

      expect(
          find.text('27H1 Stable is out as well. '
              'Switch to the Stable channel in Settings to get it.'),
          findsOneWidget);
    });

    testWidgets('the desktop is told once per release', (tester) async {
      _seed([_installed, _next]);
      final notified = <String>[];
      await _pump(tester, const UpdateBanner(),
          installed: _installed, notified: notified);
      expect(notified, ['27H1 Preview (build 20261106.1)']);

      // Next start: the same release is not announced again.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const UpdateBanner(),
          installed: _installed, notified: notified);
      expect(notified, hasLength(1));
    });

    testWidgets('nothing is sent while up to date', (tester) async {
      _seed([_installed]);
      final notified = <String>[];
      await _pump(tester, const UpdateBanner(),
          installed: _installed, notified: notified);

      expect(find.byType(MaterialBanner), findsNothing);
      expect(notified, isEmpty);
    });

    // The widest banner, in the longer language, in a narrow window.
    testWidgets('lays out in Spanish', (tester) async {
      tester.view.physicalSize = const Size(720, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      _seed([_installed, 'v27H1', 'v27H2-preview.20270110.1']);
      await _pump(tester, const UpdateBanner(),
          installed: _installed, locale: const Locale('es'));

      expect(find.text('Omitir esta versión'), findsOneWidget);
      expect(find.text('Más tarde'), findsOneWidget);
    });
  });

  group('UpdateAboutStatus', () {
    testWidgets('nothing before any check', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester, const UpdateAboutStatus(), installed: _installed);

      expect(
          find.descendant(
              of: find.byType(UpdateAboutStatus), matching: find.byType(Text)),
          findsNothing);
    });

    testWidgets('up to date', (tester) async {
      _seed([_installed]);
      await _pump(tester, const UpdateAboutStatus(), installed: _installed);

      expect(find.text('You have the latest version.'), findsOneWidget);
    });

    // About answers the question even for a release the banner was told to
    // keep quiet about.
    testWidgets('a skipped release is still named', (tester) async {
      _seed([_installed, _next], extra: {'flutter.update_skipped_tag': _next});
      await _pump(tester, const UpdateAboutStatus(), installed: _installed);

      expect(find.text('27H1 Preview (build 20261106.1) is available.'),
          findsOneWidget);
      expect(find.text('View on GitHub'), findsOneWidget);
    });
  });
}
