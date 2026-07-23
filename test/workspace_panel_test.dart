import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A minimal stand-in proving the load-bearing invariant: switching the visible
// index of an IndexedStack must NOT dispose the hidden child (that is what keeps
// a live SSH session alive). WorkspacePanel must use IndexedStack, not TabBarView.
class _Probe extends StatefulWidget {
  const _Probe({super.key});
  @override
  State<_Probe> createState() => _ProbeState();
}
int _disposes = 0;
class _ProbeState extends State<_Probe> {
  @override
  void dispose() { _disposes++; super.dispose(); }
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('IndexedStack keeps hidden children mounted across index change',
      (tester) async {
    _disposes = 0;
    var index = 0;
    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      return MaterialApp(
        home: Column(children: [
          TextButton(
            onPressed: () => setState(() => index = 1),
            child: const Text('switch'),
          ),
          Expanded(
            child: IndexedStack(index: index, children: const [
              _Probe(key: ValueKey('a')),
              SizedBox(key: ValueKey('b')),
            ]),
          ),
        ]),
      );
    }));
    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    expect(_disposes, 0); // the hidden _Probe was NOT disposed
  });
}
