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
  'backend_unreachable',
  'protocol_error',
  'local_port_unavailable',
  // Not from TunnelError::code(): raised by the UI when Rust reaps a tunnel
  // that had been working. See `markDeadTunnels`.
  'session_lost',
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
        // A missing `case` is invisible to the two checks above: the default
        // arm returns a perfectly good sentence that happens to say nothing.
        // A code listed here has its own message or it is not done.
        expect(message, isNot(l10n.tunnelErrorUnknown),
            reason: '$code fell through to the generic message');
      }
      // An unknown code must not crash; it falls back to the generic message.
      expect(tunnelErrorMessage(l10n, 'something_new'),
          equals(l10n.tunnelErrorUnknown));

      // The port-carrying codes must name the port. Passing only the detail —
      // which is all the Custom Tunnel dialog used to get — rendered a bare
      // "3000" through the generic wrapper: "Operation failed: 3000".
      for (final code in const ['backend_unreachable', 'local_port_unavailable']) {
        expect(tunnelErrorMessage(l10n, code, detail: '3000'), contains('3000'),
            reason: '$code did not name the port it was given');
      }

      // Detail that names no port (0 = no ephemeral port could be bound, or a
      // code that carries none) must degrade to the portless wording, never
      // print "0" or leak the raw payload.
      for (final detail in const [null, '', '0']) {
        final message =
            tunnelErrorMessage(l10n, 'local_port_unavailable', detail: detail);
        expect(message, equals(l10n.tunnelErrorLocalPortUnavailable),
            reason: 'detail "$detail" should not be treated as a port');
        expect(
            tunnelErrorDetailIsRedundant('local_port_unavailable', detail),
            isFalse,
            reason: 'detail "$detail" is not echoed by the message');
      }

      // A detail the message already contains must not be echoed underneath;
      // one that carries real diagnostics must survive.
      expect(tunnelErrorDetailIsRedundant('backend_unreachable', '3000'), isTrue);
      expect(tunnelErrorDetailIsRedundant('protocol_error', 'relay closed (4021)'),
          isFalse);
    });
  }
}
