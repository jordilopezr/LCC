import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import 'gcloud_provider.dart';

/// Non-modal banner shown at the top of the dashboard when the GCP session has
/// expired (project/instance listing failed with an auth/reauth error). Offers
/// a one-tap re-login that reuses `gcloud auth login`. Renders nothing when
/// there is no auth error.
class GcpSessionBanner extends ConsumerStatefulWidget {
  const GcpSessionBanner({super.key});

  @override
  ConsumerState<GcpSessionBanner> createState() => _GcpSessionBannerState();
}

class _GcpSessionBannerState extends ConsumerState<GcpSessionBanner> {
  bool _busy = false;

  bool _isAuthError(AsyncValue<dynamic> v) =>
      v.hasError && classifyGcpError(v.error) == GcpErrorType.unauthenticated;

  Future<void> _reauth() async {
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await reauthenticate();
      ref.invalidate(projectsProvider);
      ref.invalidate(instancesProvider);
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.sessionExpiredReauthOk)));
    } catch (_) {
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.sessionExpiredReauthFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final expired = _isAuthError(ref.watch(projectsProvider)) ||
        _isAuthError(ref.watch(instancesProvider));
    if (!expired) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.sessionExpiredBanner,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _busy ? null : _reauth,
              child: Text(_busy
                  ? l10n.sessionExpiredReauthenticating
                  : l10n.sessionExpiredReauth),
            ),
          ],
        ),
      ),
    );
  }
}
