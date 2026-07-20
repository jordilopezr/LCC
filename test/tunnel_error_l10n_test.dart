import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/tunnel_manager_dialog.dart';

/// Every code produced by Rust's TunnelError::code() must map to a message.
const _codes = <String>[
  'not_authenticated',
  'permission_denied',
  'instance_not_found',
  'instance_not_running',
  'firewall_blocked',
  'relay_unreachable',
  'protocol_error',
  'local_port_unavailable',
];

void main() {
  for (final locale in const [Locale('en'), Locale('es')]) {
    testWidgets('every tunnel error code maps to a message in $locale',
        (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) {
          l10n = AppLocalizations.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();

      for (final code in _codes) {
        final message = tunnelErrorMessage(l10n, code);
        expect(message, isNotEmpty, reason: 'no message for $code');
        expect(message, isNot(code), reason: '$code fell through to the raw code');
      }
      // An unknown code must not crash; it falls back to the generic message.
      expect(tunnelErrorMessage(l10n, 'something_new'),
          equals(l10n.tunnelErrorUnknown));
    });
  }
}
