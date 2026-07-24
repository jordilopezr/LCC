import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('app localizations resolve for en and es', (tester) async {
    for (final locale in const [Locale('en'), Locale('es')]) {
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Text(AppLocalizations.of(context).appTitle),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Lightweight Cloud Connector'), findsOneWidget);
    }
  });
}
