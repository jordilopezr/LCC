// Smoke test for the app root: verifies the localized MaterialApp builds
// and renders the dashboard without crashing.
//
// This replaces the stale Flutter counter-app boilerplate that always
// failed (the app has no counter).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/main.dart';

void main() {
  testWidgets('app root builds a localized MaterialApp and shows the dashboard', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    // Use a desktop-sized surface: this is a Linux desktop app and the
    // default test surface (800x600) is too small for the app bar, which
    // would otherwise overflow and fail the test for reasons unrelated to
    // localization.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pump();

    final materialAppFinder = find.byType(MaterialApp);
    expect(materialAppFinder, findsOneWidget);

    final materialApp = tester.widget<MaterialApp>(materialAppFinder);
    final supportedLanguages = materialApp.supportedLocales
        .map((l) => l.languageCode)
        .toSet();
    expect(supportedLanguages, containsAll(<String>{'en', 'es'}));

    // The dashboard scaffold should be present (async provider states are
    // handled gracefully via loading/error branches).
    expect(find.byType(Scaffold), findsWidgets);
  });
}
