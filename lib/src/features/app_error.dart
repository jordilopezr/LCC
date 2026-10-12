import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart' show TunnelFailure;
import 'tunnel_manager_dialog.dart' show tunnelErrorMessage;

/// Curated taxonomy of errors surfaced to the user from the Rust layer.
enum AppErrorCode {
  notAuthenticated,
  permissionDenied,
  notFound,
  network,
  quotaExceeded,
  gcloudNotInstalled,
  alreadyExists,
  invalidInput,
  cancelled,
  unknown,
}

/// Classify any thrown error into an [AppErrorCode]. Matches stable identifiers
/// (GCP API status codes are constants Google does not translate) and our own
/// anyhow messages. Ordered most-specific-first; falls back to [unknown].
AppErrorCode classifyRustError(dynamic e) {
  final msg = e.toString();
  final lower = msg.toLowerCase();

  // Our own message — check before generic auth/network matches.
  if (lower.contains('gcloud') &&
      (lower.contains('not installed') ||
          lower.contains('command not found') ||
          lower.contains('no such file'))) {
    return AppErrorCode.gcloudNotInstalled;
  }
  // Numeric HTTP codes are matched with word boundaries so a port or byte
  // count (e.g. "127.0.0.1:8403") cannot be mistaken for a status code.
  if (msg.contains('PERMISSION_DENIED') || RegExp(r'\b403\b').hasMatch(msg)) {
    return AppErrorCode.permissionDenied;
  }
  if (msg.contains('NOT_FOUND') ||
      RegExp(r'\b404\b').hasMatch(msg) ||
      lower.contains('not found')) {
    return AppErrorCode.notFound;
  }
  if (msg.contains('ALREADY_EXISTS') || lower.contains('already exists')) {
    return AppErrorCode.alreadyExists;
  }
  if (msg.contains('INVALID_ARGUMENT')) {
    return AppErrorCode.invalidInput;
  }
  if (msg.contains('UNAUTHENTICATED') || RegExp(r'\b401\b').hasMatch(msg)) {
    return AppErrorCode.notAuthenticated;
  }
  if (msg.contains('RESOURCE_EXHAUSTED') || lower.contains('quota')) {
    return AppErrorCode.quotaExceeded;
  }
  if (msg.contains('CANCELLED') ||
      lower.contains('cancelled') ||
      lower.contains('canceled')) {
    return AppErrorCode.cancelled;
  }
  if (msg.contains('UNAVAILABLE') ||
      lower.contains('network') ||
      lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('connect')) {
    return AppErrorCode.network;
  }
  // gcloud/ADC re-auth phrasing.
  if (lower.contains('requires reauthentication') ||
      lower.contains('session has expired') ||
      msg.contains('invalid_rapt') ||
      msg.contains('invalid_grant') ||
      msg.contains('No active GCP account')) {
    return AppErrorCode.notAuthenticated;
  }
  return AppErrorCode.unknown;
}

/// Riverpod `retry` for providers that call Google with the stored session.
///
/// A session Google rejected (`notAuthenticated`: invalid_grant, invalid_rapt,
/// an expired session, no active account) is rejected again on every retry,
/// so retrying only repeats the failure in the log and keeps the provider in
/// "loading" for half a minute before its error branch can show. Seen in the
/// QA of 2026-10-01: an invalid_grant was retried 8 times. Everything else
/// keeps Riverpod's own backoff, cap and retry limit, by delegating to it.
Duration? retryUnlessSignedOut(int retryCount, Object error) =>
    classifyRustError(error) == AppErrorCode.notAuthenticated
        ? null
        : ProviderContainer.defaultRetry(retryCount, error);

/// Render any error as a localized, user-facing message.
///
/// - `TunnelFailure` (typed) → the existing `tunnelError*` mapping.
/// - A known [AppErrorCode] → a clean localized message.
/// - `unknown` → when [standalone], a localized generic wrapper around the raw
///   detail; otherwise just the raw detail (for call sites that already supply
///   their own localized "what failed" prefix).
String localizedError(
  AppLocalizations l10n,
  dynamic e, {
  bool standalone = true,
}) {
  if (e is TunnelFailure) {
    return tunnelErrorMessage(l10n, e.code, detail: e.detail);
  }
  switch (classifyRustError(e)) {
    case AppErrorCode.notAuthenticated:
      return l10n.appErrorNotAuthenticated;
    case AppErrorCode.permissionDenied:
      return l10n.appErrorPermissionDenied;
    case AppErrorCode.notFound:
      return l10n.appErrorNotFound;
    case AppErrorCode.network:
      return l10n.appErrorNetwork;
    case AppErrorCode.quotaExceeded:
      return l10n.appErrorQuotaExceeded;
    case AppErrorCode.gcloudNotInstalled:
      return l10n.appErrorGcloudNotInstalled;
    case AppErrorCode.alreadyExists:
      return l10n.appErrorAlreadyExists;
    case AppErrorCode.invalidInput:
      return l10n.appErrorInvalidInput;
    case AppErrorCode.cancelled:
      return l10n.appErrorCancelled;
    case AppErrorCode.unknown:
      final detail = e.toString();
      return standalone ? l10n.appErrorGeneric(detail) : detail;
  }
}

/// Whether an error looks like "the IAP tunnel reached the VM but the target
/// port refused the connection" — the classic symptom of a service bound only
/// to 127.0.0.1 (unreachable via IAP). Drives the Custom Tunnel localhost hint.
///
/// [code] is the tunnel error code when one is available. It is checked first
/// because `backend_unreachable` states this outright, whereas the text probes
/// below only catch the cases where the relay's own words survived into the
/// message.
bool isBackendUnreachable(dynamic e, {String? code}) {
  if (code == 'backend_unreachable') return true;
  final s = e.toString().toLowerCase();
  return RegExp(r'\b4003\b').hasMatch(s) ||
      s.contains('failed to connect to backend') ||
      s.contains('connection refused');
}
