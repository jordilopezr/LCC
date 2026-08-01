import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

void main() {
  group('classifyGcpError', () {
    test('session-expired reauth message -> unauthenticated', () {
      final e = Exception(
          'Authentication failed: your Google Cloud session has expired or '
          'requires reauthentication. Run: gcloud auth login');
      expect(classifyGcpError(e), GcpErrorType.unauthenticated);
    });

    test('invalid_rapt -> unauthenticated', () {
      expect(classifyGcpError(Exception('reauth failed: invalid_rapt')),
          GcpErrorType.unauthenticated);
    });

    test('No active GCP account -> unauthenticated', () {
      expect(classifyGcpError(Exception('No active GCP account. Please run ...')),
          GcpErrorType.unauthenticated);
    });

    test('UNAUTHENTICATED still classified -> unauthenticated', () {
      expect(classifyGcpError(Exception('UNAUTHENTICATED')),
          GcpErrorType.unauthenticated);
    });

    test('PERMISSION_DENIED -> permissionDenied', () {
      expect(classifyGcpError(Exception('PERMISSION_DENIED')),
          GcpErrorType.permissionDenied);
    });

    test('unrelated message -> unknown', () {
      expect(classifyGcpError(Exception('disk full')), GcpErrorType.unknown);
    });
  });
}
