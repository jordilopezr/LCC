import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/sftp/sftp_dual_view.dart';

Widget _host() => const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SftpDualView(
              host: 'localhost', port: 22, username: 'u', instanceName: 'vm'),
        ),
      ),
    );

void main() {
  testWidgets('dual view shows the local pane; classic toggle hides it', (tester) async {
    // Swallow RenderFlex overflow + let the remote pane fail to connect quietly.
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exception.toString().contains('A RenderFlex overflowed')) return;
      prev?.call(d);
    };
    try {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 50));
      // Dual by default: the local pane header is present.
      expect(find.byIcon(Icons.computer), findsWidgets);
      // Toggle to classic.
      await tester.tap(find.text('Classic'));
      await tester.pump();
      expect(find.byIcon(Icons.computer), findsNothing);
    } finally {
      FlutterError.onError = prev;
    }
  });
}
