import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/sftp/transfer_enqueue.dart';
import 'package:linux_cloud_connector/src/features/sftp/transfer_queue_provider.dart';

void main() {
  final files = [
    SourceFile(path: '/l/a.txt', relativePath: 'a.txt', sizeBytes: 10),
    SourceFile(path: '/l/sub/b.txt', relativePath: 'sub/b.txt', sizeBytes: 20),
  ];

  test('skipExisting drops colliding names, keeps the rest', () {
    final items = buildTransferItems(
      files: files,
      direction: TransferDirection.upload,
      destDir: '/r',
      existingNames: {'a.txt'},
      choice: ConflictChoice.skipExisting,
    );
    expect(items.length, 1);
    expect(items.single.remotePath, '/r/sub/b.txt');
    expect(items.single.direction, TransferDirection.upload);
  });

  test('overwriteAll keeps everything', () {
    final items = buildTransferItems(
      files: files,
      direction: TransferDirection.upload,
      destDir: '/r',
      existingNames: {'a.txt'},
      choice: ConflictChoice.overwriteAll,
    );
    expect(items.length, 2);
    expect(items.map((i) => i.remotePath), ['/r/a.txt', '/r/sub/b.txt']);
    expect(items.every((i) => i.status == TransferStatus.queued), true);
  });

  test('cancel yields no items', () {
    final items = buildTransferItems(
      files: files, direction: TransferDirection.upload, destDir: '/r',
      existingNames: {'a.txt'}, choice: ConflictChoice.cancel);
    expect(items, isEmpty);
  });

  test('download builds local dest paths and downloads', () {
    final items = buildTransferItems(
      files: [SourceFile(path: '/r/x.log', relativePath: 'x.log', sizeBytes: 5)],
      direction: TransferDirection.download, destDir: '/home/u/dl',
      existingNames: const {}, choice: ConflictChoice.overwriteAll);
    expect(items.single.direction, TransferDirection.download);
    expect(items.single.localPath, '/home/u/dl/x.log');
    expect(items.single.remotePath, '/r/x.log');
  });

  test('destSubdirs yields every ancestor prefix, parent before child', () {
    final subdirs = destSubdirs([
      SourceFile(path: '/l/com/example/app/Main.java',
          relativePath: 'com/example/app/Main.java', sizeBytes: 1),
    ]);
    expect(subdirs, ['com', 'com/example', 'com/example/app']);
  });

  test('destSubdirs yields nothing for a root-level file', () {
    final subdirs = destSubdirs([
      SourceFile(path: '/l/a.txt', relativePath: 'a.txt', sizeBytes: 1),
    ]);
    expect(subdirs, isEmpty);
  });

  test('destSubdirs dedupes a prefix shared by multiple files', () {
    final subdirs = destSubdirs([
      SourceFile(path: '/l/com/example/A.txt',
          relativePath: 'com/example/A.txt', sizeBytes: 1),
      SourceFile(path: '/l/com/example/B.txt',
          relativePath: 'com/example/B.txt', sizeBytes: 1),
    ]);
    expect(subdirs, ['com', 'com/example']);
  });
}
