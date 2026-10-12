import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/sftp/local_pane.dart';

void main() {
  test('listLocalDir returns dirs first, then files, sorted by name', () async {
    final tmp = await Directory.systemTemp.createTemp('lcc_lp_');
    addTearDown(() => tmp.delete(recursive: true));
    await File('${tmp.path}/b.txt').writeAsString('hello');
    await File('${tmp.path}/a.txt').writeAsString('hi');
    await Directory('${tmp.path}/zdir').create();
    final entries = await listLocalDir(tmp.path);
    expect(entries.map((e) => e.name), ['zdir', 'a.txt', 'b.txt']);
    expect(entries.first.isDirectory, true);
    expect(entries.firstWhere((e) => e.name == 'a.txt').sizeBytes, 2);
  });

  test('listLocalDir treats a symlink to a directory as a file', () async {
    final tmp = await Directory.systemTemp.createTemp('lcc_lp_');
    addTearDown(() => tmp.delete(recursive: true));
    final subdir = await Directory('${tmp.path}/subdir').create();
    await Link('${tmp.path}/lnk').create(subdir.path);
    final entries = await listLocalDir(tmp.path);
    final lnkEntry = entries.firstWhere((e) => e.name == 'lnk');
    expect(lnkEntry.isDirectory, false);
  });
}
