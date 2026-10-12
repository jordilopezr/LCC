import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

void main() {
  test('makeSshForwardKey is prefixed', () {
    expect(makeSshForwardKey('vm1', 8443), 'sshfwd:vm1:8443');
  });
  test('isSshForwardKey distinguishes', () {
    expect(isSshForwardKey('sshfwd:vm1:8443'), isTrue);
    expect(isSshForwardKey('vm1:8443'), isFalse);
  });
  test('parseTunnelKey strips the sshfwd prefix', () {
    expect(parseTunnelKey('sshfwd:vm1:8443'), ('vm1', 8443));
    expect(parseTunnelKey('vm1:8443'), ('vm1', 8443));
  });
  test('an instance literally named sshfwd is not misdetected', () {
    // IAP tunnel for instance "sshfwd" -> key "sshfwd:8443" (2 parts).
    expect(isSshForwardKey('sshfwd:8443'), isFalse);
    expect(parseTunnelKey('sshfwd:8443'), ('sshfwd', 8443));
    // SSH forward for that same instance -> "sshfwd:sshfwd:8443" (3 parts).
    expect(isSshForwardKey('sshfwd:sshfwd:8443'), isTrue);
    expect(parseTunnelKey('sshfwd:sshfwd:8443'), ('sshfwd', 8443));
  });
}
