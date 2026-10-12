import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/sftp.dart';
import 'package:linux_cloud_connector/src/features/sftp/transfer_queue_provider.dart';

// A queue whose transfer/cancel are faked so tests never touch the bridge.
class _FakeQueue extends TransferQueueNotifier {
  final Map<int, StreamController<SftpProgress>> controllers = {};
  final List<int> cancelled = [];

  @override
  Stream<SftpProgress> runTransfer(TransferItem item) {
    final c = StreamController<SftpProgress>();
    controllers[item.id] = c;
    return c.stream;
  }

  @override
  Future<void> cancelTransfer(int transferId) async {
    cancelled.add(transferId);
    // Emulate the bridge stream erroring out on cancel.
    controllers[transferId]?.addError('cancelled');
    await controllers[transferId]?.close();
  }

  // Test helper: drive a running transfer to completion.
  Future<void> finish(int id, int total) async {
    controllers[id]!.add(SftpProgress(transferred: BigInt.from(total), total: BigInt.from(total)));
    await controllers[id]!.close();
  }

  Future<void> fail(int id) async {
    controllers[id]!.addError('boom');
    await controllers[id]!.close();
  }
}

TransferItem _item(int id, {TransferDirection dir = TransferDirection.upload}) => TransferItem(
      id: id, localPath: '/tmp/a$id', remotePath: '/home/u/a$id',
      direction: dir, sizeBytes: 100, status: TransferStatus.queued, transferred: 0,
    );

void main() {
  late ProviderContainer container;
  late _FakeQueue fake;
  final provider = NotifierProvider<TransferQueueNotifier, TransferQueueState>(() => fake);

  setUp(() {
    fake = _FakeQueue();
  });
  TransferQueueNotifier wn(ProviderContainer c) => c.read(provider.notifier);
  TransferQueueState ws(ProviderContainer c) => c.read(provider);

  test('processes items sequentially: item 2 does not start until item 1 finishes', () async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    wn(container).enqueue([_item(1), _item(2)]);
    await Future.microtask(() {});
    // Only item 1 is active; item 2 waits.
    expect(ws(container).items.firstWhere((i) => i.id == 1).status, TransferStatus.active);
    expect(ws(container).items.firstWhere((i) => i.id == 2).status, TransferStatus.queued);
    expect(fake.controllers.containsKey(2), false); // runTransfer not called for 2 yet
    await fake.finish(1, 100);
    await Future.delayed(const Duration(milliseconds: 10));
    expect(ws(container).items.firstWhere((i) => i.id == 1).status, TransferStatus.done);
    expect(ws(container).items.firstWhere((i) => i.id == 2).status, TransferStatus.active);
  });

  test('cancel of a queued item skips it without calling the bridge', () async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    wn(container).enqueue([_item(1), _item(2)]);
    await Future.microtask(() {});
    wn(container).cancel(2); // item 2 is still queued
    expect(ws(container).items.firstWhere((i) => i.id == 2).status, TransferStatus.cancelled);
    expect(fake.cancelled.contains(2), false); // no bridge cancel for a queued item
    await fake.finish(1, 100);
    await Future.delayed(const Duration(milliseconds: 10));
    // Item 2 was cancelled, so it never becomes active.
    expect(fake.controllers.containsKey(2), false);
  });

  test('cancel of the active item calls the bridge and marks it cancelled', () async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    wn(container).enqueue([_item(1)]);
    await Future.microtask(() {});
    wn(container).cancel(1); // active
    await Future.delayed(const Duration(milliseconds: 10));
    expect(fake.cancelled.contains(1), true);
    expect(ws(container).items.firstWhere((i) => i.id == 1).status, TransferStatus.cancelled);
  });

  test('retry re-queues a failed item', () async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    wn(container).enqueue([_item(1)]);
    await Future.microtask(() {});
    await fake.fail(1);
    await Future.delayed(const Duration(milliseconds: 10));
    expect(ws(container).items.firstWhere((i) => i.id == 1).status, TransferStatus.failed);
    wn(container).retry(1);
    expect(ws(container).items.firstWhere((i) => i.id == 1).status, isIn(
        [TransferStatus.queued, TransferStatus.active]));
  });

  test('hasActiveTransfers reflects queued/active work', () async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    expect(wn(container).hasActiveTransfers, false);
    wn(container).enqueue([_item(1)]);
    await Future.microtask(() {});
    expect(wn(container).hasActiveTransfers, true);
    await fake.finish(1, 100);
    await Future.delayed(const Duration(milliseconds: 10));
    expect(wn(container).hasActiveTransfers, false);
  });
}
