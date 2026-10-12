import 'transfer_id.dart';
import 'transfer_queue_provider.dart';

enum ConflictChoice { overwriteAll, skipExisting, cancel }

/// One file to transfer, with its path relative to the dragged root (so folders
/// expand to their files while preserving subdirectory structure).
class SourceFile {
  final String path;         // absolute source path (local for upload, remote for download)
  final String relativePath; // path relative to the drop, e.g. "sub/b.txt"
  final int sizeBytes;
  const SourceFile({required this.path, required this.relativePath, required this.sizeBytes});

  String get topName => relativePath.split('/').first;
}

/// Turns a resolved drop (files already enumerated, destination listing known)
/// into queue items, applying the batch conflict choice. Pure + testable.
List<TransferItem> buildTransferItems({
  required List<SourceFile> files,
  required TransferDirection direction,
  required String destDir,
  required Set<String> existingNames,
  required ConflictChoice choice,
}) {
  if (choice == ConflictChoice.cancel) return const [];
  final out = <TransferItem>[];
  for (final f in files) {
    if (choice == ConflictChoice.skipExisting && existingNames.contains(f.topName)) {
      continue;
    }
    final dest = '$destDir/${f.relativePath}';
    out.add(TransferItem(
      id: nextTransferId(),
      localPath: direction == TransferDirection.upload ? f.path : dest,
      remotePath: direction == TransferDirection.upload ? dest : f.path,
      direction: direction,
      sizeBytes: f.sizeBytes,
      status: TransferStatus.queued,
      transferred: 0,
    ));
  }
  return out;
}

/// All destination subdirectories that must exist for these files, as paths
/// relative to the drop root, ordered parent→child (shortest first), deduped.
///
/// `mkdir` on both sides is non-recursive (a single-level `sftp.mkdir` on the
/// remote; `Directory.create` is the only recursive one, reserved for the
/// local side), so a deep drop — e.g. `com/example/app/Main.java` — needs
/// every ancestor prefix created in order, not just the file's immediate
/// parent: `['com', 'com/example', 'com/example/app']`. A root-level file
/// (no `/` in its relativePath) contributes nothing.
List<String> destSubdirs(List<SourceFile> files) {
  final out = <String>{};
  for (final f in files) {
    final parts = f.relativePath.split('/');
    for (var i = 1; i < parts.length; i++) {
      out.add(parts.sublist(0, i).join('/'));
    }
  }
  return out.toList()
    ..sort((a, b) {
      final byDepth = a.split('/').length.compareTo(b.split('/').length);
      return byDepth != 0 ? byDepth : a.compareTo(b);
    });
}

// --- Cross-pane drag-and-drop payload markers ------------------------------
//
// The local pane and the remote pane each drag `List<SourceFile>` (resolved
// lazily — see `resolve` — so hovering a row never triggers filesystem/SFTP
// work; only an actual drop does). Both panes would otherwise share the exact
// same closure type `Future<List<SourceFile>> Function()`, which would let a
// pane's own `DragTarget` accept a drag that originated from itself (Flutter's
// `DragTarget<T>` only checks `data is T`, not provenance). Wrapping each
// pane's payload in its own marker class makes the two directions distinct
// types, so a pane's `DragTarget` structurally can only accept drags that
// started in the *other* pane.
class LocalDragPayload {
  final Future<List<SourceFile>> Function() resolve;
  const LocalDragPayload(this.resolve);
}

class RemoteDragPayload {
  final Future<List<SourceFile>> Function() resolve;
  const RemoteDragPayload(this.resolve);
}
