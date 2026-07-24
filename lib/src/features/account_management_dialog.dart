import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'gcloud_provider.dart';

/// Maps a semantic [GcpErrorType] to a localized message. Returns null when
/// there is no classified type, so callers fall back to the raw error text.
String? _gcpErrorMessage(AppLocalizations l10n, GcpErrorType? type) {
  switch (type) {
    case GcpErrorType.permissionDenied:
      return l10n.commonGcpErrorPermissionDenied;
    case GcpErrorType.notFound:
      return l10n.commonGcpErrorNotFound;
    case GcpErrorType.unauthenticated:
      return l10n.commonGcpErrorUnauthenticated;
    case GcpErrorType.quotaExceeded:
      return l10n.commonGcpErrorQuotaExceeded;
    case GcpErrorType.network:
      return l10n.commonGcpErrorNetwork;
    case GcpErrorType.unknown:
      return l10n.commonGcpErrorUnknown;
    case null:
      return null;
  }
}

/// Shows the Account Management Dialog
void showAccountManagementDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => const AccountManagementDialog(),
  );
}

class AccountManagementDialog extends ConsumerWidget {
  const AccountManagementDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final accountState = ref.watch(accountProvider);
    final connections = ref.watch(activeConnectionsProvider);
    final hasActiveTunnels = connections.values.any((t) => t.status == 'connected');

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.account_circle, size: 28),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.accountManageTitle)),
          if (accountState.isLoading)
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (accountState.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _gcpErrorMessage(l10n, accountState.errorType) ?? accountState.error!,
                          style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (hasActiveTunnels)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amber.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.accountActiveTunnelsWarning,
                          style: TextStyle(fontSize: 12, color: Colors.amber.shade800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (accountState.accounts.isEmpty && !accountState.isLoading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.accountNoneFound),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: accountState.accounts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final account = accountState.accounts[index];
                    final isActive = account.status == 'ACTIVE';

                    return ListTile(
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: isActive ? Colors.green.shade100 : Colors.grey.shade200,
                        child: Icon(
                          Icons.account_circle,
                          color: isActive ? Colors.green.shade700 : Colors.grey.shade500,
                          size: 24,
                        ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              account.account,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isActive)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                l10n.accountActiveBadge,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green.shade800),
                              ),
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isActive)
                            TextButton.icon(
                              icon: const Icon(Icons.swap_horiz, size: 16),
                              label: Text(l10n.accountSwitchButton, style: const TextStyle(fontSize: 12)),
                              onPressed: accountState.isLoading
                                  ? null
                                  : () async {
                                      await ref.read(accountProvider.notifier).switchAccount(account.account);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text(l10n.accountSwitchedTo(account.account))),
                                        );
                                      }
                                    },
                            ),
                          IconButton(
                            icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
                            tooltip: l10n.accountRemoveTooltip,
                            onPressed: accountState.isLoading
                                ? null
                                : () => _confirmRemoveAccount(context, ref, l10n, account.account, isActive),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.person_add, size: 18),
          label: Text(l10n.accountAddButton),
          onPressed: accountState.isLoading
              ? null
              : () async {
                  await ref.read(accountProvider.notifier).addAccount();
                },
        ),
        TextButton.icon(
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(l10n.commonRefresh),
          onPressed: accountState.isLoading
              ? null
              : () async {
                  await ref.read(accountProvider.notifier).refresh();
                },
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  void _confirmRemoveAccount(BuildContext context, WidgetRef ref, AppLocalizations l10n, String email, bool isActive) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.accountRemoveTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.accountRemoveConfirm(email)),
            const SizedBox(height: 8),
            if (isActive)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.accountActiveAccountWarning,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(accountProvider.notifier).removeAccount(email);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.accountRemovedSnackbar(email))),
                );
              }
            },
            child: Text(l10n.commonRemove, style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
  }
}
