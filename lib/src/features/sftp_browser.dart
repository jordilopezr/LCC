import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/sftp.dart';

// SFTP Browser State
class SftpBrowserState {
  final String currentPath;
  final List<RemoteFileEntry> files;
  final bool isLoading;
  final String? error;
  final String? operationInProgress;
  /// Fraction (0.0–1.0) of the file currently transferring, or null for an
  /// indeterminate operation. Set alongside [operationInProgress] during
  /// streaming uploads so the banner can show a real progress bar.
  final double? progress;
  final String searchQuery;

  const SftpBrowserState({
    this.currentPath = '/home',
    this.files = const [],
    this.isLoading = false,
    this.error,
    this.operationInProgress,
    this.progress,
    this.searchQuery = '',
  });

  SftpBrowserState copyWith({
    String? currentPath,
    List<RemoteFileEntry>? files,
    bool? isLoading,
    String? error,
    String? operationInProgress,
    double? progress,
    String? searchQuery,
  }) {
    return SftpBrowserState(
      currentPath: currentPath ?? this.currentPath,
      files: files ?? this.files,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      operationInProgress: operationInProgress,
      progress: progress,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }

  /// Get filtered files based on search query
  List<RemoteFileEntry> get filteredFiles {
    if (searchQuery.isEmpty) return files;
    final query = searchQuery.toLowerCase();
    return files.where((file) {
      return file.name.toLowerCase().contains(query);
    }).toList();
  }
}

// SFTP Browser Notifier Parameters
class SftpBrowserParams {
  final String host;
  final int port;
  final String username;

  const SftpBrowserParams({
    required this.host,
    required this.port,
    required this.username,
  });
}

// SFTP Browser Notifier
class SftpBrowserNotifier extends Notifier<SftpBrowserState> {
  late String host;
  late int port;
  late String username;

  @override
  SftpBrowserState build() {
    // Parameters will be set before build is called
    return const SftpBrowserState();
  }

  void initialize(String h, int p, String u, AppLocalizations l10n) {
    host = h;
    port = p;
    username = u;
    // Load initial directory after initialization
    _loadDirectory('/home/$username', l10n);
  }

  Future<void> _loadDirectory(String dirPath, AppLocalizations l10n) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final files = await sftpListDir(
        host: host,
        port: port,
        username: username,
        remotePath: dirPath,
      );

      state = state.copyWith(
        currentPath: dirPath,
        files: files,
        isLoading: false,
      );
    } catch (e, stackTrace) {
      // Structured logging for debugging
      debugPrint('═══ SFTP ERROR: Directory Listing ═══');
      debugPrint('Operation: List directory');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('Remote Path: $dirPath');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('═════════════════════════════════════');

      state = state.copyWith(
        isLoading: false,
        error: l10n.sftpErrorLoadDirectory(dirPath, e.toString()),
      );
    }
  }

  Future<void> navigateTo(String dirPath, AppLocalizations l10n) async {
    await _loadDirectory(dirPath, l10n);
  }

  Future<void> refresh(AppLocalizations l10n) async {
    await _loadDirectory(state.currentPath, l10n);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  void updateSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void clearSearch() {
    state = state.copyWith(searchQuery: '');
  }

  /// Sanitize filename to prevent command injection and path traversal
  String _sanitizeFilename(String filename) {
    return filename
        // Remove path separators
        .replaceAll(RegExp(r'[/\\\0]'), '_')
        // Remove shell metacharacters that could enable command injection
        .replaceAll(RegExp(r'[;&|`$()]'), '_')
        // Remove other potentially dangerous characters
        .replaceAll(RegExp(r'[<>"]'), '_')
        // Collapse multiple underscores
        .replaceAll(RegExp(r'_+'), '_')
        // Trim leading/trailing underscores and whitespace
        .trim()
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  Future<void> uploadFile(AppLocalizations l10n) async {
    String? fileName;
    String? localPath;
    String? remotePath;

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.single.path != null) {
        localPath = result.files.single.path!;
        // Sanitize filename to prevent injection attacks
        fileName = _sanitizeFilename(path.basename(localPath));
        remotePath = path.join(state.currentPath, fileName);

        final label = l10n.sftpUploadingFile(fileName);
        state = state.copyWith(operationInProgress: label, progress: 0);

        await for (final p in sftpUploadParallel(
          host: host,
          port: port,
          username: username,
          localPath: localPath,
          remotePath: remotePath,
          concurrency: 4,
        )) {
          final total = p.total.toInt();
          state = state.copyWith(
            operationInProgress: label,
            progress: total > 0 ? p.transferred.toInt() / total : null,
          );
        }

        state = state.copyWith(operationInProgress: null);
        await refresh(l10n);
      }
    } catch (e, stackTrace) {
      // Structured logging for debugging
      debugPrint('═══ SFTP ERROR: Upload File ═══');
      debugPrint('Operation: Upload file');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('File Name: ${fileName ?? "unknown"}');
      debugPrint('Local Path: ${localPath ?? "unknown"}');
      debugPrint('Remote Path: ${remotePath ?? "unknown"}');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorUploadFile(fileName ?? 'file', e.toString()),
      );
    }
  }

  /// Upload multiple files from drag & drop
  Future<void> uploadFiles(List<XFile> files, AppLocalizations l10n) async {
    if (files.isEmpty) return;

    try {
      final totalFiles = files.length;
      int uploadedCount = 0;

      for (final file in files) {
        uploadedCount++;
        final fileName = _sanitizeFilename(path.basename(file.path));
        final remotePath = path.join(state.currentPath, fileName);

        state = state.copyWith(
          operationInProgress: l10n.sftpUploadingBatch(uploadedCount, totalFiles, fileName),
        );

        await sftpUpload(
          host: host,
          port: port,
          username: username,
          localPath: file.path,
          remotePath: remotePath,
        );
      }

      state = state.copyWith(operationInProgress: null);
      await refresh(l10n);
    } catch (e, stackTrace) {
      // Structured logging for debugging
      debugPrint('═══ SFTP ERROR: Batch Upload ═══');
      debugPrint('Operation: Upload multiple files');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('Total Files: ${files.length}');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('═════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorUploadBatch(e.toString()),
      );
    }
  }

  /// Upload a whole local folder (recursively) into the current remote directory.
  Future<void> uploadFolder(AppLocalizations l10n) async {
    String? localDir;
    try {
      localDir = await FilePicker.platform.getDirectoryPath();
      if (localDir == null) return; // user cancelled

      final folderName = _sanitizeFilename(path.basename(localDir));
      if (folderName.isEmpty) {
        state = state.copyWith(error: l10n.sftpErrorFolderNameInvalid);
        return;
      }
      final remoteRoot = path.join(state.currentPath, folderName);

      // Snapshot the tree first so we can create parents before children and
      // report progress over a known total.
      final entries =
          await Directory(localDir).list(recursive: true, followLinks: false).toList();
      final subDirs = entries.whereType<Directory>().map((d) => d.path).toList()..sort();
      final files = entries.whereType<File>().toList();

      state = state.copyWith(operationInProgress: l10n.sftpUploadingFolder(folderName));
      await sftpMkdir(host: host, port: port, username: username, remotePath: remoteRoot);

      // Recreate the directory structure (sorted => parents precede children).
      for (final d in subDirs) {
        final rel = path.relative(d, from: localDir);
        await sftpMkdir(
          host: host,
          port: port,
          username: username,
          remotePath: path.join(remoteRoot, rel),
        );
      }

      // Upload every file, preserving its relative path, with a 3-worker pool
      // (each worker using 2 internal connections) and an aggregate
      // byte-based progress bar across the whole folder.
      final dir = localDir;

      // Total bytes for the whole folder (for the global progress bar).
      final sizes = <String, int>{};
      var totalBytes = 0;
      for (final f in files) {
        final len = await f.length();
        sizes[f.path] = len;
        totalBytes += len;
      }

      // 3 files in flight, each with 2 internal connections (≤6 total).
      var nextIndex = 0;
      var filesDone = 0;
      var doneBytes = 0;
      final inFlight = <String, int>{};

      void emitProgress() {
        final current =
            doneBytes + inFlight.values.fold<int>(0, (a, b) => a + b);
        final fraction = totalBytes > 0 ? current / totalBytes : null;
        state = state.copyWith(
          operationInProgress: l10n.sftpFolderProgressLabel(
            totalBytes > 0 ? (current * 100 ~/ totalBytes) : 100,
            current ~/ 1000000,
            totalBytes ~/ 1000000,
            filesDone,
            files.length,
          ),
          progress: fraction,
        );
      }

      Future<void> worker() async {
        while (true) {
          final i = nextIndex++;
          if (i >= files.length) return;
          final f = files[i];
          final rel = path.relative(f.path, from: dir);
          await for (final p in sftpUploadParallel(
            host: host,
            port: port,
            username: username,
            localPath: f.path,
            remotePath: path.join(remoteRoot, rel),
            concurrency: 2,
          )) {
            inFlight[f.path] = p.transferred.toInt();
            emitProgress();
          }
          inFlight.remove(f.path);
          doneBytes += sizes[f.path] ?? 0;
          filesDone++;
          emitProgress();
        }
      }

      emitProgress();
      await Future.wait([worker(), worker(), worker()]);

      state = state.copyWith(operationInProgress: null);
      await refresh(l10n);
    } catch (e, stackTrace) {
      debugPrint('═══ SFTP ERROR: Upload Folder ═══');
      debugPrint('Operation: Upload folder');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('Local Dir: ${localDir ?? "unknown"}');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('═════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorUploadFolder(e.toString()),
      );
    }
  }

  Future<void> downloadFile(RemoteFileEntry file, AppLocalizations l10n) async {
    String? localPath;

    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

      if (selectedDirectory != null) {
        localPath = path.join(selectedDirectory, file.name);
        final label = l10n.sftpDownloadingFile(file.name);
        state = state.copyWith(operationInProgress: label, progress: 0);

        await for (final p in sftpDownloadParallel(
          host: host,
          port: port,
          username: username,
          remotePath: file.path,
          localPath: localPath,
          concurrency: 4,
        )) {
          final total = p.total.toInt();
          state = state.copyWith(
            operationInProgress: label,
            progress: total > 0 ? p.transferred.toInt() / total : null,
          );
        }

        state = state.copyWith(operationInProgress: null);
      }
    } catch (e, stackTrace) {
      // Structured logging for debugging
      debugPrint('═══ SFTP ERROR: Download File ═══');
      debugPrint('Operation: Download file');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('File Name: ${file.name}');
      debugPrint('File Size: ${file.size} bytes');
      debugPrint('Remote Path: ${file.path}');
      debugPrint('Local Path: ${localPath ?? "unknown"}');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('══════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorDownloadFile(file.name, e.toString()),
      );
    }
  }

  Future<void> createDirectory(String dirName, AppLocalizations l10n) async {
    String? remotePath;

    // Input validation: Prevent directory name injection attacks
    final trimmedName = dirName.trim();

    if (trimmedName.isEmpty) {
      state = state.copyWith(
        error: l10n.sftpErrorDirNameEmpty,
      );
      return;
    }

    if (trimmedName.contains('/') || trimmedName.contains('\\')) {
      state = state.copyWith(
        error: l10n.sftpErrorDirNameSeparators,
      );
      return;
    }

    if (trimmedName.contains('..')) {
      state = state.copyWith(
        error: l10n.sftpErrorDirNameParentRef,
      );
      return;
    }

    if (trimmedName.length > 255) {
      state = state.copyWith(
        error: l10n.sftpErrorDirNameTooLong,
      );
      return;
    }

    // Note: We allow names starting with '.' for hidden directories (Unix convention)
    // If you want to prevent hidden directories, uncomment:
    // if (trimmedName.startsWith('.')) {
    //   state = state.copyWith(
    //     error: 'Directory name cannot start with "." (hidden directories not allowed).',
    //   );
    //   return;
    // }

    try {
      remotePath = path.join(state.currentPath, trimmedName);
      state = state.copyWith(operationInProgress: l10n.sftpCreatingDirectory);

      await sftpMkdir(
        host: host,
        port: port,
        username: username,
        remotePath: remotePath,
      );

      state = state.copyWith(operationInProgress: null);
      await refresh(l10n);
    } catch (e, stackTrace) {
      // Structured logging for debugging
      debugPrint('═══ SFTP ERROR: Create Directory ═══');
      debugPrint('Operation: Create directory');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('Directory Name: $dirName');
      debugPrint('Parent Path: ${state.currentPath}');
      debugPrint('Full Path: ${remotePath ?? "unknown"}');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('═════════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorCreateDirectory(dirName, e.toString()),
      );
    }
  }

  Future<void> deleteEntry(RemoteFileEntry file, AppLocalizations l10n) async {
    try {
      state = state.copyWith(operationInProgress: l10n.sftpDeletingFile(file.name));

      await sftpDelete(
        host: host,
        port: port,
        username: username,
        remotePath: file.path,
        isDirectory: file.isDirectory,
      );

      state = state.copyWith(operationInProgress: null);
      await refresh(l10n);
    } catch (e, stackTrace) {
      // Structured logging for debugging
      debugPrint('═══ SFTP ERROR: Delete Entry ═══');
      debugPrint('Operation: Delete ${file.isDirectory ? "directory" : "file"}');
      debugPrint('Host: $host:$port');
      debugPrint('Username: $username');
      debugPrint('Entry Name: ${file.name}');
      debugPrint('Entry Path: ${file.path}');
      debugPrint('Is Directory: ${file.isDirectory}');
      debugPrint('Error Type: ${e.runtimeType}');
      debugPrint('Error Message: $e');
      debugPrint('Stack Trace:\n$stackTrace');
      debugPrint('═════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorDeleteFile(file.name, e.toString()),
      );
    }
  }

  /// Download file to temp directory for preview
  Future<String?> downloadForPreview(RemoteFileEntry file, AppLocalizations l10n) async {
    try {
      state = state.copyWith(operationInProgress: l10n.sftpLoadingPreview);

      // Create temp directory
      final tempDir = await Directory.systemTemp.createTemp('sftp_preview_');
      final localPath = path.join(tempDir.path, file.name);

      await sftpDownload(
        host: host,
        port: port,
        username: username,
        remotePath: file.path,
        localPath: localPath,
      );

      state = state.copyWith(operationInProgress: null);
      return localPath;
    } catch (e, stackTrace) {
      debugPrint('═══ SFTP ERROR: Preview Download ═══');
      debugPrint('File: ${file.name}');
      debugPrint('Error: $e');
      debugPrint('Stack: $stackTrace');
      debugPrint('═════════════════════════════════════');

      state = state.copyWith(
        operationInProgress: null,
        error: l10n.sftpErrorLoadPreview(e.toString()),
      );
      return null;
    }
  }
}

// Create a unique provider for each SFTP session
NotifierProvider<SftpBrowserNotifier, SftpBrowserState> createSftpBrowserProvider() {
  return NotifierProvider<SftpBrowserNotifier, SftpBrowserState>(SftpBrowserNotifier.new);
}

// SFTP Browser Dialog Widget
class SftpBrowserDialog extends ConsumerStatefulWidget {
  final String host;
  final int port;
  final String username;
  final String instanceName;

  const SftpBrowserDialog({
    super.key,
    required this.host,
    required this.port,
    required this.username,
    required this.instanceName,
  });

  @override
  ConsumerState<SftpBrowserDialog> createState() => _SftpBrowserDialogState();
}

class _SftpBrowserDialogState extends ConsumerState<SftpBrowserDialog> {
  late final NotifierProvider<SftpBrowserNotifier, SftpBrowserState> provider;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    provider = createSftpBrowserProvider();
    // Initialize the notifier with connection parameters after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ref.read(provider.notifier).initialize(
        widget.host,
        widget.port,
        widget.username,
        l10n,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(provider);
    final l10n = AppLocalizations.of(context);

    return Dialog(
      child: Container(
        width: 900,
        height: 700,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.folder_open, size: 28, color: Colors.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sftpFileBrowserTitle(widget.instanceName),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        state.currentPath,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
              child: TextField(
                decoration: InputDecoration(
                  hintText: l10n.sftpSearchHint,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: state.searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () => ref.read(provider.notifier).clearSearch(),
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                ),
                onChanged: (value) => ref.read(provider.notifier).updateSearchQuery(value),
              ),
            ),

            // Toolbar
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                children: [
                  // Parent Directory Navigation Button
                  IconButton(
                    onPressed: (state.isLoading || state.currentPath == '/home/${widget.username}')
                        ? null
                        : () {
                            final parentPath = path.dirname(state.currentPath);
                            ref.read(provider.notifier).navigateTo(parentPath, l10n);
                          },
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: l10n.sftpParentDirectoryTooltip,
                    color: Colors.blue.shade700,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: state.isLoading ? null : () => ref.read(provider.notifier).uploadFile(l10n),
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: Text(l10n.sftpUploadFileButton),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: state.isLoading ? null : () => ref.read(provider.notifier).uploadFolder(l10n),
                    icon: const Icon(Icons.drive_folder_upload, size: 18),
                    label: Text(l10n.sftpUploadFolderButton),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: state.isLoading ? null : () => _showCreateDirectoryDialog(l10n),
                    icon: const Icon(Icons.create_new_folder, size: 18),
                    label: Text(l10n.sftpNewFolderButton),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: state.isLoading ? null : () => ref.read(provider.notifier).refresh(l10n),
                    icon: const Icon(Icons.refresh),
                    tooltip: l10n.commonRefresh,
                  ),
                  const Spacer(),
                ],
              ),
            ),

            // Progress banner on its own full-width row so it never overflows
            // the toolbar (the filename + bar + percentage can be wide).
            if (state.operationInProgress != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: state.progress,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.operationInProgress!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (state.progress != null) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: LinearProgressIndicator(value: state.progress),
                      ),
                      const SizedBox(width: 8),
                      Text('${(state.progress! * 100).round()}%'),
                    ],
                  ],
                ),
              ),

            // Error display
            if (state.error != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.error!,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => ref.read(provider.notifier).clearError(),
                    ),
                  ],
                ),
              ),

            // File list with drag & drop support
            Expanded(
              child: DropTarget(
                onDragEntered: (details) {
                  setState(() => _isDragging = true);
                },
                onDragExited: (details) {
                  setState(() => _isDragging = false);
                },
                onDragDone: (details) async {
                  setState(() => _isDragging = false);
                  await ref.read(provider.notifier).uploadFiles(details.files, l10n);
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isDragging ? Colors.blue : Colors.transparent,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    color: _isDragging ? Colors.blue.withValues(alpha: 0.05) : null,
                  ),
                  child: state.isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : state.filteredFiles.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _isDragging
                                        ? Icons.file_upload
                                        : (state.searchQuery.isEmpty ? Icons.folder_open : Icons.search_off),
                                    size: 64,
                                    color: _isDragging ? Colors.blue : Colors.grey.shade400,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _isDragging
                                        ? l10n.sftpDropFilesHere
                                        : (state.searchQuery.isEmpty
                                            ? l10n.sftpEmptyFolder
                                            : l10n.sftpNoFilesMatch(state.searchQuery)),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _isDragging ? Colors.blue : Colors.grey.shade600,
                                      fontSize: 16,
                                      fontWeight: _isDragging ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Stack(
                              children: [
                                ListView.builder(
                                  itemCount: state.filteredFiles.length,
                                  itemBuilder: (context, index) {
                                    final file = state.filteredFiles[index];
                                    return _FileListTile(
                                      file: file,
                                      searchQuery: state.searchQuery,
                                      onTap: () {
                                        if (file.isDirectory) {
                                          ref.read(provider.notifier).navigateTo(file.path, l10n);
                                        }
                                      },
                                      onPreview: _canPreview(file) && !file.isDirectory
                                          ? () => _showPreview(file, l10n)
                                          : null,
                                      onDownload: file.isDirectory ? null : () {
                                        ref.read(provider.notifier).downloadFile(file, l10n);
                                      },
                                      onDelete: file.name == '..' ? null : () {
                                        _showDeleteConfirmation(file, l10n);
                                      },
                                    );
                                  },
                                ),
                                // Drag overlay
                                if (_isDragging)
                                  Container(
                                    color: Colors.blue.withValues(alpha: 0.1),
                                    child: Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.file_upload,
                                            size: 80,
                                            color: Colors.blue.shade700,
                                          ),
                                          const SizedBox(height: 16),
                                          Text(
                                            l10n.sftpDropFilesHere,
                                            style: TextStyle(
                                              fontSize: 24,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDirectoryDialog(AppLocalizations l10n) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.sftpCreateFolderTitle),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: l10n.sftpFolderNameLabel,
            hintText: 'my-folder',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                ref.read(provider.notifier).createDirectory(controller.text, l10n);
                Navigator.pop(context);
              }
            },
            child: Text(l10n.sftpCreateButton),
          ),
        ],
      ),
    ).then((_) => controller.dispose()); // Dispose controller when dialog closes
  }

  void _showDeleteConfirmation(RemoteFileEntry file, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.sftpConfirmDeleteTitle),
        content: Text(l10n.sftpConfirmDeleteMessage(file.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              ref.read(provider.notifier).deleteEntry(file, l10n);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
  }

  /// Check if file can be previewed
  bool _canPreview(RemoteFileEntry file) {
    if (file.isDirectory || file.name == '..') return false;

    final ext = path.extension(file.name).toLowerCase();
    const textExtensions = ['.txt', '.md', '.log', '.json', '.xml', '.yaml', '.yml', '.conf', '.ini', '.sh', '.py', '.js', '.dart', '.html', '.css', '.sql'];
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'];

    return textExtensions.contains(ext) || imageExtensions.contains(ext);
  }

  /// Show file preview dialog
  Future<void> _showPreview(RemoteFileEntry file, AppLocalizations l10n) async {
    final localPath = await ref.read(provider.notifier).downloadForPreview(file, l10n);
    if (localPath == null || !mounted) return;

    final ext = path.extension(file.name).toLowerCase();
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'];

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: Container(
          width: 800,
          height: 600,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    imageExtensions.contains(ext) ? Icons.image : Icons.description,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      file.name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      // Clean up temp file
                      try {
                        File(localPath).deleteSync();
                      } catch (_) {}
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
              const Divider(),
              // Content
              Expanded(
                child: imageExtensions.contains(ext)
                    ? _ImagePreview(filePath: localPath)
                    : _TextPreview(filePath: localPath),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      // Clean up temp file after dialog closes
      try {
        File(localPath).deleteSync();
      } catch (_) {}
    });
  }
}

// File List Tile Widget
class _FileListTile extends StatelessWidget {
  final RemoteFileEntry file;
  final String searchQuery;
  final VoidCallback onTap;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;

  const _FileListTile({
    required this.file,
    required this.searchQuery,
    required this.onTap,
    this.onPreview,
    this.onDownload,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: Icon(
        file.isDirectory ? Icons.folder : _getFileIcon(file.name),
        color: file.isDirectory ? Colors.blue.shade400 : Colors.grey.shade600,
        size: 28,
      ),
      title: _buildHighlightedText(file.name, searchQuery),
      subtitle: file.isDirectory
          ? Text(l10n.sftpFolderLabel)
          : Text(_formatFileSize(file.size)),
      trailing: file.name == '..'
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onPreview != null)
                  IconButton(
                    icon: const Icon(Icons.visibility, size: 20),
                    onPressed: onPreview,
                    tooltip: l10n.sftpPreviewTooltip,
                    color: Colors.blue.shade600,
                  ),
                if (onDownload != null)
                  IconButton(
                    icon: const Icon(Icons.download, size: 20),
                    onPressed: onDownload,
                    tooltip: l10n.sftpDownloadTooltip,
                  ),
                if (onDelete != null)
                  IconButton(
                    icon: Icon(Icons.delete, size: 20, color: Colors.red.shade400),
                    onPressed: onDelete,
                    tooltip: l10n.commonDelete,
                  ),
              ],
            ),
      onTap: onTap,
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    switch (ext) {
      case '.txt':
      case '.md':
        return Icons.description;
      case '.pdf':
        return Icons.picture_as_pdf;
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
        return Icons.image;
      case '.zip':
      case '.tar':
      case '.gz':
        return Icons.archive;
      case '.sh':
      case '.py':
      case '.js':
      case '.dart':
        return Icons.code;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatFileSize(BigInt bytes) {
    // Use toDouble() to avoid overflow for very large files
    final double b = bytes.toDouble();

    if (b < 1024) {
      return '${bytes.toInt()} B';  // Safe: small values
    }
    if (b < 1024 * 1024) {
      return '${(b / 1024).toStringAsFixed(1)} KB';
    }
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Build text with search query highlighted
  Widget _buildHighlightedText(String text, String query) {
    if (query.isEmpty) {
      return Text(text);
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matches = <TextSpan>[];
    int currentIndex = 0;

    while (currentIndex < text.length) {
      final matchIndex = lowerText.indexOf(lowerQuery, currentIndex);

      if (matchIndex == -1) {
        // No more matches, add remaining text
        if (currentIndex < text.length) {
          matches.add(TextSpan(text: text.substring(currentIndex)));
        }
        break;
      }

      // Add text before match
      if (matchIndex > currentIndex) {
        matches.add(TextSpan(text: text.substring(currentIndex, matchIndex)));
      }

      // Add highlighted match
      matches.add(
        TextSpan(
          text: text.substring(matchIndex, matchIndex + query.length),
          style: const TextStyle(
            backgroundColor: Colors.yellow,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
      );

      currentIndex = matchIndex + query.length;
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.black87, fontSize: 14),
        children: matches,
      ),
    );
  }
}

// Text File Preview Widget
class _TextPreview extends StatefulWidget {
  final String filePath;

  const _TextPreview({required this.filePath});

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  String? _content;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    try {
      final file = File(widget.filePath);
      final content = await file.readAsString();
      if (mounted) {
        setState(() {
          _content = content;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      final l10n = AppLocalizations.of(context);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(l10n.sftpErrorLoadFile(_error!), style: const TextStyle(color: Colors.red)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          _content ?? '',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// Image File Preview Widget
class _ImagePreview extends StatelessWidget {
  final String filePath;

  const _ImagePreview({required this.filePath});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InteractiveViewer(
        minScale: 0.1,
        maxScale: 5.0,
        child: Image.file(
          File(filePath),
          errorBuilder: (context, error, stackTrace) {
            final l10n = AppLocalizations.of(context);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.broken_image, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  l10n.sftpErrorLoadImage,
                  style: TextStyle(color: Colors.red.shade700),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
