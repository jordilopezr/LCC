import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/rdp_client.dart';
import 'package:linux_cloud_connector/src/features/settings_provider.dart';

void main() {
  group('parseRdpClientName', () {
    test('the clients this build offers round-trip', () {
      expect(parseRdpClientName('remmina'), RdpClientType.remmina);
      expect(parseRdpClientName('freerdp'), RdpClientType.freeRdp);
      expect(parseRdpClientName('krdc'), RdpClientType.krdc);
      expect(parseRdpClientName('gnome_connections'), RdpClientType.gnomeConnections);
    });

    // 'mstsc' sits in the SharedPreferences of anyone who picked Windows
    // Remote Desktop before it was removed. Reading it must not throw and must
    // not leave the app with no client: it lands on the default.
    test('a preference for the removed Windows client falls back to Remmina', () {
      expect(parseRdpClientName('mstsc'), RdpClientType.remmina);
    });

    test('any unknown name falls back rather than throwing', () {
      expect(parseRdpClientName(''), RdpClientType.remmina);
      expect(parseRdpClientName('some_client_from_the_future'), RdpClientType.remmina);
    });
  });
}
