import 'package:flutter/material.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/ssh_access.dart';
import '../services/storage_service.dart';

/// Outcome of [ensureSshAccess].
///
/// Three states, not a nullable `String`: a null username used to conflate
/// "the user pressed Not now" with "the calling context died mid-probe"
/// (the probe opens a real tunnel and can take several seconds). Those need
/// different handling — a refusal is remembered and shown to the user, an
/// abandoned call is neither.
sealed class SshAccessOutcome {
  const SshAccessOutcome();
}

/// Access works (or was just provisioned). Log in as [username], presenting
/// [keyPath].
///
/// [keyPath] is the whole reason this class is not just a username. LCC's own
/// key lives in the app's data directory, deliberately **not** in `~/.ssh`, so
/// `ssh(1)` cannot find it by name and libssh2's candidate ladder offers it
/// last — after `sshd`'s default `MaxAuthTries` of 6 may already be spent on
/// the user's agent identities and `~/.ssh` files. Carrying the key that was
/// *proven* to work is what stops a session failing moments after LCC told
/// the user it had authorised one.
///
/// Null when the SSH agent authenticated: there is then no file to present,
/// and every entry point should keep using the agent exactly as before.
class SshAccessGranted extends SshAccessOutcome {
  final String username;
  final String? keyPath;
  const SshAccessGranted(this.username, {this.keyPath});
}

/// The user explicitly declined via the consent dialog. Recorded in
/// [StorageService] so this project is not asked again.
class SshAccessRefused extends SshAccessOutcome {
  const SshAccessRefused();
}

/// Could not be resolved because the [BuildContext] that triggered the
/// connection was gone before consent could be asked or acted on. Not a
/// user answer: nothing is recorded, and callers should show no error (or a
/// neutral one) rather than "not authorised".
class SshAccessAbandoned extends SshAccessOutcome {
  const SshAccessAbandoned();
}

/// Make sure SSH access to [instance] works, asking for consent the first time
/// LCC needs to write a key into [projectId].
///
/// Takes no `ref`: the brief's draft signature included a `WidgetRef` for
/// symmetry with other dialog helpers, but the body never reads providers
/// through it, and one of the three call sites (`_connectSshForward` in
/// `gcloud_provider.dart`, a `Notifier`) only has a `Ref`, which is not a
/// `WidgetRef` and not assignable to one. Since the parameter was unused,
/// dropping it is the fix that keeps a single signature for all three sites
/// rather than special-casing the notifier caller.
Future<SshAccessOutcome> ensureSshAccess(
  BuildContext context, {
  required String projectId,
  required String zone,
  required String instance,
}) {
  // Single-flight per VM. The workspace panel is an IndexedStack, so every
  // session tab's initState boots eagerly: opening a VM with an SSH tab and
  // an SFTP tab starts two probes at once, and the probe takes seconds
  // (it opens a real tunnel). Without this the user gets two stacked consent
  // dialogs for one decision and two `setMetadata` writes racing on the same
  // metadata fingerprint — the loser coming back as a 412. A second caller
  // awaits the first's answer instead.
  final key = '$projectId/$zone/$instance';
  final existing = _inFlight[key];
  if (existing != null) return existing;

  final future =
      _ensureSshAccess(context, projectId: projectId, zone: zone, instance: instance);
  _inFlight[key] = future;
  // `ignore()` on the derived future only: an `ensureSshAccess` that throws
  // is still reported to the caller through `future` itself, but the
  // book-keeping continuation must not become a second, unhandled copy of
  // that same error.
  future.whenComplete(() {
    if (identical(_inFlight[key], future)) _inFlight.remove(key);
  }).ignore();
  return future;
}

/// In-flight [ensureSshAccess] calls, keyed by `project/zone/instance`.
final Map<String, Future<SshAccessOutcome>> _inFlight = {};

Future<SshAccessOutcome> _ensureSshAccess(
  BuildContext context, {
  required String projectId,
  required String zone,
  required String instance,
}) async {
  final state = await probeSshAccess(
      projectId: projectId, zone: zone, instanceName: instance);

  if (state is SshAccessState_Ready) {
    return SshAccessGranted(state.credential.username,
        keyPath: state.credential.keyPath);
  }
  final needs = state as SshAccessState_NeedsProvisioning;

  final storage = StorageService();
  final remembered = storage.getSshProvisionConsent(projectId);
  if (remembered == false) return const SshAccessRefused();

  if (remembered == null) {
    if (!context.mounted) return const SshAccessAbandoned();
    final allowed =
        await _askConsent(context, projectId, needs.keyFingerprint, needs.method);
    if (allowed == null) return const SshAccessAbandoned();
    await storage.setSshProvisionConsent(projectId, allowed);
    if (!allowed) return const SshAccessRefused();
  }

  final credential = await provisionSshAccess(
      projectId: projectId, zone: zone, instanceName: instance);
  return SshAccessGranted(credential.username, keyPath: credential.keyPath);
}

/// Asks the user. Returns true/false for an explicit answer, or null if the
/// dialog route was torn down without one — [barrierDismissible] is false so
/// that only doesn't happen from a stray tap or Esc, but the caller still
/// can't assume an explicit "Not now" in that case.
Future<bool?> _askConsent(BuildContext context, String projectId,
    String fingerprint, ProvisionMethod method) async {
  final l10n = AppLocalizations.of(context);
  // The two methods are not two wordings of one promise, they are two
  // different acts. `importSshPublicKey` is ACCOUNT-scoped: it authorises the
  // key on every OS Login VM the account can reach, in every project, and
  // stores it in no VM's metadata — so the instance-metadata text ("never to
  // the project, so no other VM is affected", "remove it from the VM's
  // metadata") is false on that path, in both halves. This is the dialog
  // that asks permission to modify someone's infrastructure; it has to
  // describe what it will actually do.
  final osLogin = method == ProvisionMethod.osLogin;
  final body =
      osLogin ? l10n.sshConsentBodyOsLogin(projectId) : l10n.sshConsentBodyInstance(projectId);
  final removal =
      osLogin ? l10n.sshConsentRemovalOsLogin : l10n.sshConsentRemovalInstance;
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sshConsentTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            const SizedBox(height: 12),
            SelectableText(
              l10n.sshConsentFingerprint(fingerprint),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Text(removal, style: Theme.of(dialogContext).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.sshConsentDeny),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.sshConsentAllow),
        ),
      ],
    ),
  );
}
