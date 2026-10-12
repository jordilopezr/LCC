import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'transfer_queue_provider.dart';

class TransferQueueDrawer extends ConsumerWidget {
  final NotifierProvider<TransferQueueNotifier, TransferQueueState> queueProvider;
  const TransferQueueDrawer({super.key, required this.queueProvider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final items = ref.watch(queueProvider).items;
    final notifier = ref.read(queueProvider.notifier);
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant, width: 2)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const SizedBox(width: 10),
          Text(l10n.sftpQueueTitle,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton(
            onPressed: notifier.clearCompleted,
            child: Text(l10n.sftpQueueClearCompleted),
          ),
        ]),
        Expanded(
          child: ListView(
            children: [for (final i in items) _row(context, l10n, notifier, i)],
          ),
        ),
      ]),
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n,
      TransferQueueNotifier notifier, TransferItem i) {
    final pct = i.sizeBytes > 0 ? (i.transferred / i.sizeBytes).clamp(0.0, 1.0) : 0.0;
    final dirIcon = i.direction == TransferDirection.upload
        ? Icons.upload
        : Icons.download;
    String status;
    Color? color;
    switch (i.status) {
      case TransferStatus.queued:
        status = l10n.sftpQueueWaiting;
      case TransferStatus.active:
        status = '${(pct * 100).round()}%';
      case TransferStatus.done:
        status = l10n.sftpQueueDone;
        color = Colors.green;
      case TransferStatus.failed:
        status = l10n.sftpQueueFailed;
        color = Colors.red;
      case TransferStatus.cancelled:
        status = l10n.sftpQueueCancelled;
        color = Colors.orange;
    }
    final canCancel = i.status == TransferStatus.queued || i.status == TransferStatus.active;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Row(children: [
        Icon(dirIcon, size: 16),
        const SizedBox(width: 8),
        SizedBox(
            width: 150,
            child: Text(i.remotePath.split('/').last,
                overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 10),
        Expanded(
            child: LinearProgressIndicator(
                value: i.status == TransferStatus.active ? pct : (i.status == TransferStatus.done ? 1.0 : 0.0))),
        const SizedBox(width: 10),
        SizedBox(width: 60, child: Text(status, textAlign: TextAlign.right, style: TextStyle(color: color))),
        IconButton(
          icon: Icon(canCancel ? Icons.close : Icons.refresh, size: 16),
          tooltip: canCancel ? l10n.sftpQueueCancel : l10n.sftpQueueRetry,
          onPressed: () => canCancel ? notifier.cancel(i.id) : notifier.retry(i.id),
        ),
      ]),
    );
  }
}
