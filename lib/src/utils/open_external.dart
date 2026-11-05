import 'dart:io';

/// Opens a URL, file or folder with the desktop's default handler: `open` on
/// macOS (Safari or the default browser, Finder), `xdg-open` on Linux.
Future<ProcessResult> openExternal(String target) {
  final opener = Platform.isMacOS ? '/usr/bin/open' : 'xdg-open';
  return Process.run(opener, [target]);
}
