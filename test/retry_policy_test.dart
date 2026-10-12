import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/app_error.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

// The error Rust returned when Google rejected the stored session, verbatim
// from the QA of 2026-10-01: projectsProvider retried it 8 times before the
// app was closed, and every retry was rejected the same way.
final _sessionRejected = Exception(
    'Your Google Cloud session needs to be renewed: sign in again. (invalid_grant)');

// A failure that can clear up on its own, and is the reason retries exist.
final _networkBlip = Exception('error sending request: connection timed out');

void main() {
  group('retryUnlessSignedOut', () {
    test('a session Google rejected is not retried', () {
      expect(retryUnlessSignedOut(0, _sessionRejected), isNull);
    });

    test("anything else keeps Riverpod's backoff, cap and retry limit", () {
      expect(retryUnlessSignedOut(0, _networkBlip),
          const Duration(milliseconds: 200));
      expect(retryUnlessSignedOut(1, _networkBlip),
          const Duration(milliseconds: 400));
      expect(retryUnlessSignedOut(9, _networkBlip),
          const Duration(milliseconds: 6400));
      expect(retryUnlessSignedOut(10, _networkBlip), isNull);
    });
  });

  // The providers that call Google with the stored session. A helper nobody
  // wires in changes nothing, so the wiring is asserted on the providers.
  group('wiring', () {
    test('projectsProvider does not retry a rejected session', () {
      final retry = projectsProvider.retry;
      expect(retry, isNotNull);
      expect(retry!(0, _sessionRejected), isNull);
      expect(retry(0, _networkBlip), const Duration(milliseconds: 200));
    });

    test('instancesProvider does not retry a rejected session', () {
      final retry = instancesProvider.retry;
      expect(retry, isNotNull);
      expect(retry!(0, _sessionRejected), isNull);
      expect(retry(0, _networkBlip), const Duration(milliseconds: 200));
    });
  });
}
