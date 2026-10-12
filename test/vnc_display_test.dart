import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/vnc_display.dart';

void main() {
  group('parseVncDisplay', () {
    test('accepts the display numbers people actually use', () {
      expect(parseVncDisplay('0'), 0);
      expect(parseVncDisplay('1'), 1);
      expect(parseVncDisplay('99'), 99);
      expect(parseVncDisplay(' 2 '), 2);
    });

    // The mistake this field invites: it asks for :1 and sits where a port
    // used to be hardcoded, so someone will type 5901. Accepting it would
    // tunnel to port 11801 and fail with something unrelated to the cause.
    test('rejects a port typed into the display field', () {
      expect(parseVncDisplay('5901'), isNull);
      expect(parseVncDisplay('5900'), isNull);
    });

    test('rejects anything that is not a small non-negative number', () {
      expect(parseVncDisplay(''), isNull);
      expect(parseVncDisplay('abc'), isNull);
      expect(parseVncDisplay('-1'), isNull);
      expect(parseVncDisplay('100'), isNull);
      expect(parseVncDisplay('1.5'), isNull);
    });
  });

  group('vncPortForDisplay', () {
    test('a display is its number past 5900', () {
      expect(vncPortForDisplay(0), 5900);
      expect(vncPortForDisplay(1), 5901);
      expect(vncPortForDisplay(99), 5999);
    });
  });

  group('el mapa por VM', () {
    const key = 'proj:us-central1-a:vm1';

    // Nothing stored means display :0, which is port 5900 — exactly what the
    // app did before this existed. Nobody's behaviour changes until they ask.
    test('a VM nobody configured is display 0', () {
      expect(vncDisplayFor(const {}, key), 0);
      expect(vncDisplayFor(const {'other:z:vm': 4}, key), 0);
    });

    test('a configured VM keeps its own display', () {
      expect(vncDisplayFor(const {key: 3}, key), 3);
    });

    test('storing one leaves the others alone and does not mutate the input', () {
      const before = {'a:z:vm': 1};
      final after = withVncDisplay(before, key, 2);

      expect(after, {'a:z:vm': 1, key: 2});
      expect(before, {'a:z:vm': 1}, reason: 'the input map was mutated');
    });

    test('storing again replaces rather than duplicating', () {
      final once = withVncDisplay(const {}, key, 1);
      final twice = withVncDisplay(once, key, 7);

      expect(twice, {key: 7});
    });
  });

  group('serialización', () {
    // What survives a restart. Written by hand rather than through
    // SharedPreferences so the test says what the stored shape is.
    test('round-trips through the stored string', () {
      const map = {'p:z:vm1': 1, 'p:z:vm2': 12};
      expect(decodeVncDisplays(encodeVncDisplays(map)), map);
    });

    // A preference file edited by hand, truncated, or written by a future
    // version must not stop the app from launching VNC at all.
    test('garbage on disk reads as "nothing configured"', () {
      expect(decodeVncDisplays(null), isEmpty);
      expect(decodeVncDisplays(''), isEmpty);
      expect(decodeVncDisplays('{not json'), isEmpty);
      expect(decodeVncDisplays('[1,2,3]'), isEmpty);
    });

    // A value out of range on disk is treated as unconfigured rather than
    // trusted: the same rule the field enforces, enforced again on read.
    test('an out-of-range value on disk is ignored, not trusted', () {
      expect(decodeVncDisplays('{"p:z:vm":5901}'), isEmpty);
      expect(decodeVncDisplays('{"p:z:vm":-1}'), isEmpty);
      expect(decodeVncDisplays('{"p:z:vm":2,"q:z:vm":999}'), {'p:z:vm': 2});
    });
  });
}
