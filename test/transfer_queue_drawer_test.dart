import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/sftp/transfer_queue_drawer.dart';
import 'package:linux_cloud_connector/src/features/sftp/transfer_queue_provider.dart';

// A queue notifier that skips build()'s empty default and instead seeds one
// TransferItem per TransferStatus, so the drawer renders every row/label/icon
// combination without going through enqueue()/the bridge.
class _SeededQueue extends TransferQueueNotifier {
  @override
  TransferQueueState build() => const TransferQueueState(items: [
        TransferItem(
          id: 1,
          localPath: '/tmp/a',
          remotePath: '/home/u/a',
          direction: TransferDirection.upload,
          sizeBytes: 100,
          status: TransferStatus.queued,
          transferred: 0,
        ),
        TransferItem(
          id: 2,
          localPath: '/tmp/b',
          remotePath: '/home/u/b',
          direction: TransferDirection.upload,
          sizeBytes: 100,
          status: TransferStatus.active,
          transferred: 50,
        ),
        TransferItem(
          id: 3,
          localPath: '/tmp/c',
          remotePath: '/home/u/c',
          direction: TransferDirection.download,
          sizeBytes: 100,
          status: TransferStatus.done,
          transferred: 100,
        ),
        TransferItem(
          id: 4,
          localPath: '/tmp/d',
          remotePath: '/home/u/d',
          direction: TransferDirection.upload,
          sizeBytes: 100,
          status: TransferStatus.failed,
          transferred: 20,
          error: 'boom',
        ),
        TransferItem(
          id: 5,
          localPath: '/tmp/e',
          remotePath: '/home/u/e',
          direction: TransferDirection.download,
          sizeBytes: 100,
          status: TransferStatus.cancelled,
          transferred: 10,
        ),
      ]);
}

void main() {
  testWidgets(
      'renders the correct status label and trailing action icon for every '
      'TransferStatus', (tester) async {
    final provider =
        NotifierProvider<TransferQueueNotifier, TransferQueueState>(() => _SeededQueue());

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TransferQueueDrawer(queueProvider: provider),
        ),
      ),
    ));
    await tester.pump();

    // The drawer caps its list at maxHeight: 160, so the inner ListView is a
    // real (lazy) Sliver viewport: only rows within the viewport/cache extent
    // are built. With 5 seeded rows, the first 3 are visible up front; the
    // remaining 2 only appear after scrolling — so assertions are split into
    // two passes around a scroll, rather than one flat check of all 5 rows.

    // Pass 1 (no scroll needed): queued, active, done.
    expect(find.text('waiting'), findsOneWidget); // queued
    expect(find.text('50%'), findsOneWidget); // active
    expect(find.text('done'), findsOneWidget); // done
    expect(find.byIcon(Icons.close), findsNWidgets(2)); // cancel: queued + active
    expect(find.byIcon(Icons.refresh), findsOneWidget); // retry: done

    // Pass 2: scroll the queue list to bring failed/cancelled into view.
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();

    expect(find.text('error'), findsOneWidget); // failed
    expect(find.text('Cancelled'), findsOneWidget); // cancelled
    expect(find.byIcon(Icons.refresh), findsNWidgets(2)); // retry: failed + cancelled
    expect(find.byIcon(Icons.close), findsNothing); // queued/active scrolled out of view
  });
}
