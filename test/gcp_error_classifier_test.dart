import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/app_error.dart';

void main() {
  group('classifyRustError', () {
    test('session-expired reauth message -> notAuthenticated', () {
      final e = Exception(
          'Authentication failed: your Google Cloud session has expired or '
          'requires reauthentication. Run: gcloud auth login');
      expect(classifyRustError(e), AppErrorCode.notAuthenticated);
    });

    test('invalid_rapt -> notAuthenticated', () {
      expect(classifyRustError(Exception('reauth failed: invalid_rapt')),
          AppErrorCode.notAuthenticated);
    });

    test('No active GCP account -> notAuthenticated', () {
      expect(classifyRustError(Exception('No active GCP account. Please run ...')),
          AppErrorCode.notAuthenticated);
    });

    test('UNAUTHENTICATED still classified -> notAuthenticated', () {
      expect(classifyRustError(Exception('UNAUTHENTICATED')),
          AppErrorCode.notAuthenticated);
    });

    test('PERMISSION_DENIED -> permissionDenied', () {
      expect(classifyRustError(Exception('PERMISSION_DENIED')),
          AppErrorCode.permissionDenied);
    });

    test('unrelated message -> unknown', () {
      expect(classifyRustError(Exception('disk full')), AppErrorCode.unknown);
    });
  });
}
