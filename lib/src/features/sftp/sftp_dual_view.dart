import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../../bridge/api.dart/api.dart';
import '../sftp_browser.dart';
import 'local_pane.dart';
import 'transfer_enqueue.dart';
import 'transfer_queue_provider.dart';
import 'transfer_queue_drawer.dart';

class SftpDualView extends ConsumerStatefulWidget {
  final String host;
  final int port;
  final String username;

  /// The key file already proven to authenticate as [username] on this VM,
  /// from [SshAccessGranted.keyPath]. Passed down to every SFTP call so the
  /// session presents that one credential instead of re-walking the
  /// candidate ladder — which offers LCC's own key last, and can run out of
  /// the server's `MaxAuthTries` budget before reaching it. Null when the
  /// SSH agent authenticated.
  final String? identityFile;
  final String instanceName;
  const SftpDualView({
    super.key,
    required this.host,
    required this.port,
    required this.username,
    required this.instanceName,
    this.identityFile,
  });

  @override
  ConsumerState<SftpDualView> createState() => SftpDualViewState();
}

class SftpDualViewState extends ConsumerState<SftpDualView> {
  bool _dual = true;
  late final NotifierProvider<TransferQueueNotifier, TransferQueueState> _queue;
  // Captured while `ref` is still valid (initState) so dispose() can cancel
  // active transfers without touching `ref` — by the time State.dispose()
  // runs, the element is already defunct and `ref.read`/`ref.watch` throw
  // (Riverpod asserts `context.mounted`, which StatefulElement.unmount()
  // clears *before* calling dispose()). `_queueNotifier` itself isn't
  // BuildContext-bound, so holding a direct reference sidesteps that; the
  // notifier's `state` is protected, so `_queueItems` mirrors it via a
  // manual listener (manual listeners are closed *after* dispose() runs,
  // per ConsumerStatefulElement.unmount(), so it's still live to update).
  late final TransferQueueNotifier _queueNotifier;
  List<TransferItem> _queueItems = const [];

  @override
  void initState() {
    super.initState();
    _queue = createTransferQueueProvider(
        host: widget.host,
        port: widget.port,
        username: widget.username,
        identityFile: widget.identityFile);
    _queueNotifier = ref.read(_queue.notifier);
    _queueItems = ref.read(_queue).items;
    ref.listenManual(_queue, (previous, next) => _queueItems = next.items);
  }

  /// Exposed so the SftpTab can check for live transfers on close.
  NotifierProvider<TransferQueueNotifier, TransferQueueState> get queueProvider => _queue;

  @override
  void dispose() {
    for (final i in _queueItems) {
      if (i.status == TransferStatus.active) _queueNotifier.cancel(i.id);
    }
    super.dispose();
  }

  /// Resolves a cross-pane drop (files already enumerated by the pane that
  /// owns them) into queue items and enqueues them: lists the destination to
  /// find name collisions, asks the batch conflict question if any exist
  /// (cancelling here is a true no-op — nothing is created or enqueued),
  /// pre-creates every ancestor destination subdirectory for folder drops
  /// (parent before child, via [destSubdirs]), then hands the resolved list
  /// to [buildTransferItems].
  Future<void> _handleDrop({
    required TransferDirection direction,
    required List<SourceFile> files,
    required String destDir,
  }) async {
    if (files.isEmpty) return;
    // Existing names in the destination (one listing per drop).
    Set<String> existing;
    if (direction == TransferDirection.upload) {
      final entries = await sftpListDir(
          host: widget.host, port: widget.port, username: widget.username,
          identityFile: widget.identityFile, remotePath: destDir);
      existing = entries.map((e) => e.name).toSet();
    } else {
      existing = Directory(destDir).existsSync()
          ? Directory(destDir).listSync().map((e) => p.basename(e.path)).toSet()
          : <String>{};
    }
    final topNames = files.map((f) => f.topName).toSet();
    final collisions = topNames.intersection(existing);
    var choice = ConflictChoice.overwriteAll;
    if (collisions.isNotEmpty && mounted) {
      choice = await _askConflict(collisions.length) ?? ConflictChoice.cancel;
    }
    // Cancel must be a true no-op: skip subdir creation entirely rather than
    // round-tripping mkdir for a drop that's about to be discarded.
    if (choice == ConflictChoice.cancel) return;
    // Pre-create every ancestor destination subdirectory (parent→child) for
    // folder drops — mkdir on both sides is non-recursive, so a deep tree
    // needs each ancestor level created, not just each file's immediate
    // parent (see destSubdirs).
    for (final sub in destSubdirs(files)) {
      final full = '$destDir/$sub';
      if (direction == TransferDirection.upload) {
        try {
          await sftpMkdir(
              host: widget.host,
              port: widget.port,
              username: widget.username,
              identityFile: widget.identityFile,
              remotePath: full);
        } catch (_) {/* already exists */}
      } else {
        await Directory(full).create(recursive: true);
      }
    }
    final items = buildTransferItems(
        files: files, direction: direction, destDir: destDir,
        existingNames: existing, choice: choice);
    if (!mounted) return;
    if (items.isNotEmpty) ref.read(_queue.notifier).enqueue(items);
  }

  Future<ConflictChoice?> _askConflict(int count) {
    final l10n = AppLocalizations.of(context);
    return showDialog<ConflictChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.sftpConflictTitle),
        content: Text(l10n.sftpConflictBody(count)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, ConflictChoice.cancel),
              child: Text(l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, ConflictChoice.skipExisting),
              child: Text(l10n.sftpConflictSkip)),
          TextButton(
              onPressed: () => Navigator.pop(context, ConflictChoice.overwriteAll),
              child: Text(l10n.sftpConflictOverwrite)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final remote = SftpBrowserBody(
      host: widget.host,
      port: widget.port,
      username: widget.username,
      identityFile: widget.identityFile,
      instanceName: widget.instanceName,
      onDropUpload: (resolveFiles, destDir) async {
        final files = await resolveFiles();
        await _handleDrop(
            direction: TransferDirection.upload, files: files, destDir: destDir);
      },
    );
    return Column(children: [
      Row(children: [
        const SizedBox(width: 8),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(l10n.sftpViewDual)),
            ButtonSegment(value: false, label: Text(l10n.sftpViewClassic)),
          ],
          selected: {_dual},
          onSelectionChanged: (s) => setState(() => _dual = s.first),
          showSelectedIcon: false,
        ),
        const Spacer(),
      ]),
      const Divider(height: 1),
      Expanded(
        child: _dual
            ? Row(children: [
                Expanded(
                  child: LocalPane(
                    onDrop: (resolveFiles, destDir) async {
                      final files = await resolveFiles();
                      await _handleDrop(
                          direction: TransferDirection.download,
                          files: files,
                          destDir: destDir);
                    },
                  ),
                ),
                const VerticalDivider(width: 2, thickness: 2),
                Expanded(child: remote),
              ])
            : remote,
      ),
      TransferQueueDrawer(queueProvider: _queue),
    ]);
  }
}
