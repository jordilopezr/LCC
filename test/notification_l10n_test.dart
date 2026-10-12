import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notification keys render and interpolate in EN and ES', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final es = await AppLocalizations.delegate.load(const Locale('es'));

    // EN reproduces the current strings.
    expect(en.notifTunnelFailedTitle('vm1'), 'IAP Tunnel Failed: vm1');
    expect(en.notifTunnelFailedBody(8080, 'proj', 'z1'),
        'Port 8080 disconnected\nproj/z1');
    expect(en.notifTunnelReconnectingBody(22, 2, 5, 'proj'),
        'Port 22 - Attempt 2/5\nproj');
    expect(en.notifLifecycleSuccessTitle('start', 'vm1'),
        '✓ start completed: vm1');
    expect(en.notifClientFallbackTitle('RDP'), 'RDP Client Fallback');

    // ES interpolates the same values and differs from EN.
    expect(es.notifTunnelFailedTitle('vm1'), contains('vm1'));
    expect(es.notifTunnelFailedTitle('vm1'),
        isNot(en.notifTunnelFailedTitle('vm1')));
    expect(es.notifTunnelReconnectingBody(22, 2, 5, 'proj'), contains('2/5'));
    expect(es.notifClientFallbackBody('Remmina'), contains('Remmina'));
    expect(es.notifUnknownError, isNot(en.notifUnknownError));
  });
}
