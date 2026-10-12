import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../bridge/api.dart/api.dart';
import '../../bridge/api.dart/sftp.dart';

enum TransferDirection { upload, download }
enum TransferStatus { queued, active, done, failed, cancelled }

@immutable
class TransferItem {
  final int id;
  final String localPath;
  final String remotePath;
  final TransferDirection direction;
  final int sizeBytes;
  final TransferStatus status;
  final int transferred;
  final String? error;

  const TransferItem({
    required this.id,
    required this.localPath,
    required this.remotePath,
    required this.direction,
    required this.sizeBytes,
    required this.status,
    required this.transferred,
    this.error,
  });

  TransferItem copyWith({TransferStatus? status, int? transferred, String? error}) =>
      TransferItem(
        id: id,
        localPath: localPath,
        remotePath: remotePath,
        direction: direction,
        sizeBytes: sizeBytes,
        status: status ?? this.status,
        transferred: transferred ?? this.transferred,
        error: error ?? this.error,
      );
}

@immutable
class TransferQueueState {
  final List<TransferItem> items;
  const TransferQueueState({this.items = const []});
  TransferQueueState copyWith({List<TransferItem>? items}) =>
      TransferQueueState(items: items ?? this.items);
}

/// Per-SftpTab, in-memory, sequential transfer queue. Overridable seams
/// (`runTransfer`, `cancelTransfer`) let tests inject fakes without the bridge.
class TransferQueueNotifier extends Notifier<TransferQueueState> {
  String host = '';
  int port = 0;
  String username = '';

  /// The credential proven to work on this VM (see [SftpDualView]). Null when
  /// the SSH agent authenticated, in which case the Rust side falls back to
  /// the candidate ladder exactly as before.
  String? identityFile;
  bool _running = false;

  @override
  TransferQueueState build() => const TransferQueueState();

  @protected
  Stream<SftpProgress> runTransfer(TransferItem item) {
    switch (item.direction) {
      case TransferDirection.upload:
        return sftpUploadParallel(
          host: host, port: port, username: username, identityFile: identityFile,
          localPath: item.localPath, remotePath: item.remotePath,
          transferId: item.id,
        );
      case TransferDirection.download:
        return sftpDownloadParallel(
          host: host, port: port, username: username, identityFile: identityFile,
          remotePath: item.remotePath, localPath: item.localPath,
          transferId: item.id,
        );
    }
  }

  @protected
  Future<void> cancelTransfer(int transferId) =>
      sftpCancelTransfer(transferId: transferId);

  void _update(int id, TransferItem Function(TransferItem) f) {
    state = state.copyWith(items: [
      for (final i in state.items) if (i.id == id) f(i) else i,
    ]);
  }

  void enqueue(List<TransferItem> items) {
    state = state.copyWith(items: [...state.items, ...items]);
    _pump();
  }

  void cancel(int id) {
    final item = state.items.firstWhere((i) => i.id == id,
        orElse: () => throw StateError('no such transfer'));
    if (item.status == TransferStatus.queued) {
      _update(id, (i) => i.copyWith(status: TransferStatus.cancelled));
    } else if (item.status == TransferStatus.active) {
      // Mark cancelled up-front (deterministic), then flip the Rust token; the
      // running stream errors out and `_runOne`'s catch leaves it cancelled.
      _update(id, (i) => i.copyWith(status: TransferStatus.cancelled));
      cancelTransfer(id);
    }
  }

  void retry(int id) {
    final item = state.items.firstWhere((i) => i.id == id,
        orElse: () => throw StateError('no such transfer'));
    // Only a terminal (failed/cancelled) item can be re-queued; re-queuing an
    // active/queued/done item would clobber an in-flight transfer or restart
    // one that already finished.
    if (item.status != TransferStatus.failed && item.status != TransferStatus.cancelled) {
      return;
    }
    _update(id, (i) => i.copyWith(status: TransferStatus.queued, transferred: 0, error: null));
    _pump();
  }

  void clearCompleted() {
    state = state.copyWith(
        items: state.items.where((i) => i.status != TransferStatus.done).toList());
  }

  bool get hasActiveTransfers => state.items.any(
      (i) => i.status == TransferStatus.queued || i.status == TransferStatus.active);

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = state.items
            .where((i) => i.status == TransferStatus.queued)
            .cast<TransferItem?>()
            .firstWhere((i) => true, orElse: () => null);
        if (next == null) break;
        await _runOne(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _runOne(TransferItem item) async {
    _update(item.id, (i) => i.copyWith(status: TransferStatus.active));
    try {
      await for (final p in runTransfer(item)) {
        _update(item.id, (i) => i.copyWith(transferred: p.transferred.toInt()));
      }
      _update(item.id, (i) => i.copyWith(
          status: TransferStatus.done, transferred: i.sizeBytes));
    } catch (e) {
      // If the user cancelled, `cancel()` already set the status to cancelled;
      // leave it. Otherwise it's a real failure.
      final cur = state.items.firstWhere((i) => i.id == item.id);
      if (cur.status != TransferStatus.cancelled) {
        _update(item.id, (i) => i.copyWith(status: TransferStatus.failed, error: e.toString()));
      }
    }
  }
}

NotifierProvider<TransferQueueNotifier, TransferQueueState> createTransferQueueProvider({
  required String host,
  required int port,
  required String username,
  String? identityFile,
}) {
  return NotifierProvider<TransferQueueNotifier, TransferQueueState>(() {
    final n = TransferQueueNotifier();
    n.host = host;
    n.port = port;
    n.username = username;
    n.identityFile = identityFile;
    return n;
  });
}
