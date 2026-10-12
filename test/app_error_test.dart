import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/api.dart'
    show TunnelFailure;
import 'package:linux_cloud_connector/src/features/app_error.dart';

void main() {
  group('classifyRustError', () {
    final cases = <String, AppErrorCode>{
      'PERMISSION_DENIED: caller lacks permission':
          AppErrorCode.permissionDenied,
      'Request failed: 403': AppErrorCode.permissionDenied,
      'NOT_FOUND: instance x': AppErrorCode.notFound,
      'HTTP 404': AppErrorCode.notFound,
      'UNAUTHENTICATED': AppErrorCode.notAuthenticated,
      'reauth required: invalid_grant': AppErrorCode.notAuthenticated,
      'Your session has expired': AppErrorCode.notAuthenticated,
      'No active GCP account': AppErrorCode.notAuthenticated,
      'The gcloud CLI is not installed': AppErrorCode.gcloudNotInstalled,
      'gcloud: no such file or directory': AppErrorCode.gcloudNotInstalled,
      'gcloud: command not found': AppErrorCode.gcloudNotInstalled,
      "gcloud error: ERROR: (gcloud.compute.instances.describe) the resource 'x' was not found":
          AppErrorCode.notFound,
      'RESOURCE_EXHAUSTED: quota exceeded': AppErrorCode.quotaExceeded,
      'ALREADY_EXISTS: snapshot name taken': AppErrorCode.alreadyExists,
      'INVALID_ARGUMENT: bad zone': AppErrorCode.invalidInput,
      'connection refused': AppErrorCode.network,
      'UNAVAILABLE: backend': AppErrorCode.network,
      'operation was CANCELLED': AppErrorCode.cancelled,
      'transfer canceled by user': AppErrorCode.cancelled,
      'some totally unmapped failure': AppErrorCode.unknown,
      // Negative cases: a port containing "403"/"404" must NOT be read as a
      // status code (word-boundary matching).
      'failed to bind 127.0.0.1:8403': AppErrorCode.unknown,
      'connection refused 10.0.0.1:8404': AppErrorCode.network,
    };
    cases.forEach((msg, expected) {
      test('"$msg" -> $expected', () {
        expect(classifyRustError(Exception(msg)), expected);
      });
    });
  });

  group('localizedError', () {
    late AppLocalizations en;
    setUpAll(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('TunnelFailure routes to tunnelError* mapping', () {
      final msg = localizedError(
        en,
        const TunnelFailure(code: 'permission_denied', engine: null),
      );
      expect(msg, en.tunnelErrorPermissionDenied);
    });

    test('known code -> clean localized message', () {
      expect(
        localizedError(en, Exception('PERMISSION_DENIED')),
        en.appErrorPermissionDenied,
      );
    });

    test('unknown standalone -> generic wrapper with detail', () {
      final msg = localizedError(en, Exception('weird boom'));
      expect(msg, contains('weird boom'));
      expect(msg, en.appErrorGeneric('Exception: weird boom'));
    });

    test('unknown non-standalone -> raw detail only', () {
      final msg = localizedError(
        en,
        Exception('weird boom'),
        standalone: false,
      );
      expect(msg, 'Exception: weird boom');
    });
  });

  group('isBackendUnreachable', () {
    test('true for backend-refused signals', () {
      expect(
        isBackendUnreachable(
          'gcloud tunnel failed: ... 4003. failed to connect to backend',
        ),
        isTrue,
      );
      expect(isBackendUnreachable('Connection refused'), isTrue);
    });
    test('false otherwise', () {
      expect(isBackendUnreachable('PERMISSION_DENIED'), isFalse);
      expect(isBackendUnreachable('some other error'), isFalse);
      expect(
          isBackendUnreachable(
              'gcloud tunnel timed out (port 34003 never listened): '),
          isFalse);
    });
  });
}
