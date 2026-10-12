import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart';
import 'package:linux_cloud_connector/src/features/keyring_problem_screen.dart';

Future<void> _pump(WidgetTester tester, KeyringProblem problem,
    {VoidCallback? onCheckAgain}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: KeyringProblemScreen(
          problem: problem, onCheckAgain: onCheckAgain ?? () {}),
    ),
  ));
}

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join('\n');

void main() {
  testWidgets('unreachable names the missing service', (tester) async {
    await _pump(tester, KeyringProblem.unreachable);
    expect(_allText(tester), contains('Secret Service'));
  });

  // Measured: a locked keyring whose prompt was dismissed has a Secret Service
  // running. Telling the user to start one would be false.
  testWidgets('refused says locked or cancelled, and never blames the service',
      (tester) async {
    await _pump(tester, KeyringProblem.refused);
    final text = _allText(tester);
    expect(text, contains('locked'));
    expect(text, contains('cancelled'));
    expect(text, isNot(contains('Secret Service')));
  });

  testWidgets('pending says it is waiting and where the dialog may be',
      (tester) async {
    await _pump(tester, KeyringProblem.pending);
    final text = _allText(tester);
    expect(text, contains('Waiting for you to unlock'));
    expect(text, contains('behind this window'));
  });

  testWidgets('every case says the session is still saved', (tester) async {
    for (final problem in KeyringProblem.values) {
      await _pump(tester, problem);
      expect(_allText(tester), contains('still saved'), reason: '$problem');
    }
  });

  testWidgets('Check Again calls back once per press', (tester) async {
    var presses = 0;
    await _pump(tester, KeyringProblem.pending, onCheckAgain: () => presses++);
    await tester.tap(find.text('Check Again'));
    expect(presses, 1);
  });
}
