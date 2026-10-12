import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'transfer_enqueue.dart';

class LocalEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int sizeBytes;
  const LocalEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
  });
}

/// Expands a local entry into the files a cross-pane drop should transfer.
/// A file yields itself; a directory is walked recursively
/// (`followLinks: false` — symlinks are classified as files, same as
/// [listLocalDir], and this also sidesteps symlink-loop hangs). Each
/// descendant's `relativePath` is rooted at the dragged entry's own name
/// (i.e. relative to its *parent*) so the folder is recreated on the
/// destination.
Future<List<SourceFile>> expandLocalEntry(LocalEntry entry) async {
  if (!entry.isDirectory) {
    return [
      SourceFile(path: entry.path, relativePath: entry.name, sizeBytes: entry.sizeBytes),
    ];
  }
  final parent = p.dirname(entry.path);
  final out = <SourceFile>[];
  await for (final e in Directory(entry.path).list(recursive: true, followLinks: false)) {
    if (e is Directory) continue; // only leaf files become transfer items
    final stat = await e.stat();
    out.add(SourceFile(
      path: e.path,
      relativePath: p.relative(e.path, from: parent),
      sizeBytes: stat.size,
    ));
  }
  return out;
}

/// Lists a local directory: directories first, then files, each group sorted
/// case-insensitively by name. Symlinks/other are treated as files.
Future<List<LocalEntry>> listLocalDir(String path) async {
  final dir = Directory(path);
  final out = <LocalEntry>[];
  await for (final e in dir.list(followLinks: false)) {
    final stat = await e.stat();
    final isDir = e is Directory;
    out.add(LocalEntry(
      name: p.basename(e.path),
      path: e.path,
      isDirectory: isDir,
      sizeBytes: isDir ? 0 : stat.size,
    ));
  }
  out.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

class LocalPane extends StatefulWidget {
  final void Function(String path)? onDirChanged;

  /// Cross-pane drag-and-drop seam for the dual SFTP view. When non-null:
  /// every row becomes a drag source (its files, for an upload to the remote
  /// pane) and folder rows plus the pane background become drop targets that
  /// accept drags from the remote pane (a download into that directory). The
  /// callback receives a lazy resolver — call it to get the `SourceFile` list
  /// — and the local destination directory the drop landed on.
  /// Left null (the default), the pane renders exactly as before: no drag
  /// wiring at all.
  final void Function(
    Future<List<SourceFile>> Function() resolveFiles,
    String destDir,
  )? onDrop;

  const LocalPane({super.key, this.onDirChanged, this.onDrop});

  @override
  State<LocalPane> createState() => LocalPaneState();
}

class LocalPaneState extends State<LocalPane> {
  late String _cwd;
  List<LocalEntry> _entries = [];
  String? _error;

  // Folder rows nest a `DragTarget` inside the pane's background
  // `DragTarget`. In the current Flutter version, a drop's
  // `onAcceptWithDetails` is delivered only to the single innermost target
  // under the pointer, so a folder-row drop does not also fire the
  // background handler with the wrong destDir — this flag is a defensive,
  // currently-harmless guard against that double-accept scenario should
  // Flutter's hit-testing behavior ever change. The microtask reset keeps it
  // from bleeding into the next gesture.
  bool _dropClaimed = false;

  void _claimDrop(
    void Function(Future<List<SourceFile>> Function(), String) onDrop,
    Future<List<SourceFile>> Function() resolveFiles,
    String destDir,
  ) {
    if (_dropClaimed) return;
    _dropClaimed = true;
    Future.microtask(() => _dropClaimed = false);
    onDrop(resolveFiles, destDir);
  }

  @override
  void initState() {
    super.initState();
    _cwd = Platform.environment['HOME'] ?? Directory.current.path;
    _load();
  }

  String get currentDir => _cwd;

  Future<void> _load() async {
    try {
      final entries = await listLocalDir(_cwd);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
      widget.onDirChanged?.call(_cwd);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _enter(LocalEntry e) {
    if (!e.isDirectory) return;
    setState(() => _cwd = e.path);
    _load();
  }

  void _up() {
    final parent = p.dirname(_cwd);
    if (parent == _cwd) return;
    setState(() => _cwd = parent);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget list = ListView(children: [
      ListTile(
        dense: true,
        leading: const Icon(Icons.arrow_upward, size: 18),
        title: const Text('..'),
        onTap: _up,
      ),
      for (final e in _entries) _buildRow(context, e),
    ]);
    // Background drop target: dropping anywhere that isn't a folder row lands
    // in the current directory.
    list = _wrapDropTarget(context, destDir: _cwd, child: list);

    return Column(children: [
      Container(
        color: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          const Icon(Icons.computer, size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(_cwd, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _error != null ? Center(child: Text(_error!)) : list,
      ),
    ]);
  }

  Widget _buildRow(BuildContext context, LocalEntry e) {
    Widget tile = ListTile(
      key: ValueKey('local-${e.path}'),
      dense: true,
      leading: Icon(e.isDirectory ? Icons.folder : Icons.insert_drive_file, size: 18),
      title: Text(e.name),
      onTap: () => _enter(e),
    );

    if (widget.onDrop != null) {
      tile = Draggable<LocalDragPayload>(
        data: LocalDragPayload(() => expandLocalEntry(e)),
        feedback: Material(
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(e.name),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: tile),
        child: tile,
      );
      if (e.isDirectory) {
        tile = _wrapDropTarget(context, destDir: e.path, child: tile);
      }
    }
    return tile;
  }

  /// Wraps [child] in a `DragTarget<RemoteDragPayload>` that resolves the
  /// drop into [destDir] when [widget.onDrop] is set; returns [child]
  /// unchanged otherwise (so the pane stays inert when no one is listening).
  Widget _wrapDropTarget(BuildContext context, {required String destDir, required Widget child}) {
    final onDrop = widget.onDrop;
    if (onDrop == null) return child;
    return DragTarget<RemoteDragPayload>(
      onAcceptWithDetails: (details) =>
          _claimDrop(onDrop, details.data.resolve, destDir),
      builder: (context, candidates, rejected) {
        if (candidates.isEmpty) return child;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
          ),
          child: child,
        );
      },
    );
  }
}
