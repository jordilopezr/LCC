import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The shutdown line's value comes entirely from being on *every* clean exit:
/// its absence in a log is what tells us the app did not leave on purpose. A
/// fourth exit path that skipped it would restore the old blindness silently,
/// and no runtime test can catch that — nothing in this suite drives
/// `windowManager`. So this reads the source instead.
void main() {
  late String source;

  setUpAll(() {
    // Comments stripped first: these checks count occurrences, and a doc
    // comment that MENTIONS destroy() or the guard would be counted as one.
    // That is not hypothetical — writing the comment that explains the
    // re-entry guard broke two of these checks.
    source = File('lib/main.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
  });

  test('every window destroy goes through the helper that logs first', () {
    final destroys = 'windowManager.destroy()'.allMatches(source).length;

    expect(
      destroys,
      1,
      reason: 'lib/main.dart calls windowManager.destroy() $destroys times. '
          'Exactly one may exist, inside _closeApp, or an exit path will leave '
          'no trace in the log and a clean quit becomes indistinguishable from '
          'a crash again.',
    );
  });

  test('the only destroy sits inside the logging helper', () {
    final helper = source.indexOf('Future<void> _closeApp(');
    final destroy = source.indexOf('windowManager.destroy()');

    expect(helper, isNot(-1), reason: '_closeApp is gone: nothing logs the exit');
    expect(destroy, greaterThan(helper),
        reason: 'destroy() is called before _closeApp is even defined, so it '
            'cannot be the one inside it');
  });

  // The exit path runs more than once: destroy() makes the close event fire
  // again before the process is gone, and without this guard the app logged
  // two shutdown lines 5 ms apart. Only stderr showed both, because the file
  // writer's guard is dropped by the first call — so the duplicate was
  // invisible in the log people actually read.
  test('the exit path refuses to run twice', () {
    expect(source, contains('bool _closing = false;'),
        reason: 'the re-entry guard is gone; destroy() will log twice');
    final body = source.substring(source.indexOf('Future<void> _closeApp('));
    final guard = body.indexOf('if (_closing) return;');
    final logs = body.indexOf('logShutdown(');
    expect(guard, isNot(-1), reason: '_closeApp does not check the guard');
    expect(guard, lessThan(logs),
        reason: 'the guard must come before the line is written, or it logs twice anyway');
  });

  test('each close branch names itself, so the log says which one ran', () {
    for (final reason in const [
      'window_close_idle',
      'window_close_no_context',
      'window_close_confirmed_with_sessions',
    ]) {
      expect(source, contains("_closeApp('$reason')"),
          reason: '$reason is not wired to a close branch');
    }
  });
}
