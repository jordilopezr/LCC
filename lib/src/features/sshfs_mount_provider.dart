/// SSHFS Mount Provider - Sprint 6
///
/// State management for SSHFS mounts using Riverpod.
/// Handles mount operations, tracking active mounts, and UI state.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/sshfs_mount.dart';

/// State for SSHFS mount operations
class SshfsMountState {
  final List<SshfsMount> activeMounts;
  final SshfsStatus? status;
  final List<FileManagerInfo> fileManagers;
  final bool isLoading;
  final String? error;
  final String? successMessage;

  const SshfsMountState({
    this.activeMounts = const [],
    this.status,
    this.fileManagers = const [],
    this.isLoading = false,
    this.error,
    this.successMessage,
  });

  SshfsMountState copyWith({
    List<SshfsMount>? activeMounts,
    SshfsStatus? status,
    List<FileManagerInfo>? fileManagers,
    bool? isLoading,
    String? error,
    String? successMessage,
  }) {
    return SshfsMountState(
      activeMounts: activeMounts ?? this.activeMounts,
      status: status ?? this.status,
      fileManagers: fileManagers ?? this.fileManagers,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      successMessage: successMessage,
    );
  }
}

/// Notifier for SSHFS mount state management
class SshfsMountNotifier extends Notifier<SshfsMountState> {
  @override
  SshfsMountState build() {
    _initialize();
    return const SshfsMountState();
  }

  Future<void> _initialize() async {
    await checkSshfsStatus();
    await loadFileManagers();
    await refreshMounts();
  }

  /// Check SSHFS installation status
  Future<void> checkSshfsStatus() async {
    try {
      final status = await getSshfsStatus();
      state = state.copyWith(status: status);
    } catch (e) {
      state = state.copyWith(error: 'Failed to check SSHFS status: $e');
    }
  }

  /// Load available file managers
  Future<void> loadFileManagers() async {
    try {
      final managers = await getAvailableFileManagers();
      state = state.copyWith(fileManagers: managers);
    } catch (e) {
      // Non-critical error, just log it
    }
  }

  /// Refresh the list of active mounts
  Future<void> refreshMounts() async {
    try {
      final mounts = await refreshSshfsMountStatus();
      state = state.copyWith(activeMounts: mounts);
    } catch (e) {
      state = state.copyWith(error: 'Failed to refresh mounts: $e');
    }
  }

  /// Mount a remote directory
  Future<MountResult> mount({
    required String projectId,
    required String zone,
    required String instanceName,
    required String username,
    required String remotePath,
    required String localMountPoint,
    required int tunnelPort,
    SshfsMountOptions? options,
  }) async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final result = await sshfsMount(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        username: username,
        remotePath: remotePath,
        localMountPoint: localMountPoint,
        tunnelPort: tunnelPort,
        options: options ?? const SshfsMountOptions(
          readOnly: false,
          cache: true,
          compression: true,
          reconnect: true,
          serverAliveInterval: 15,
          allowOther: false,
          followSymlinks: true,
          sshPort: null,
          identityFile: null,
        ),
      );

      if (result.success) {
        await refreshMounts();
        state = state.copyWith(
          isLoading: false,
          successMessage: 'Mounted successfully: ${result.mountPoint}',
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: result.error ?? 'Mount failed',
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Mount error: $e',
      );
      return MountResult(
        success: false,
        mount: null,
        error: e.toString(),
        mountPoint: localMountPoint,
      );
    }
  }

  /// Unmount a mount point
  Future<UnmountResult> unmount(String mountPoint) async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final result = await sshfsUnmount(mountPoint: mountPoint);

      if (result.success) {
        await refreshMounts();
        state = state.copyWith(
          isLoading: false,
          successMessage: 'Unmounted successfully: ${result.mountPoint}',
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: result.error ?? 'Unmount failed',
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Unmount error: $e',
      );
      return UnmountResult(
        success: false,
        error: e.toString(),
        mountPoint: mountPoint,
      );
    }
  }

  /// Unmount by mount ID
  Future<UnmountResult> unmountById(String mountId) async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final result = await sshfsUnmountById(mountId: mountId);

      if (result.success) {
        await refreshMounts();
        state = state.copyWith(
          isLoading: false,
          successMessage: 'Unmounted successfully',
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: result.error ?? 'Unmount failed',
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Unmount error: $e',
      );
      return UnmountResult(
        success: false,
        error: e.toString(),
        mountPoint: '',
      );
    }
  }

  /// Unmount all mounts
  Future<void> unmountAll() async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final results = await sshfsUnmountAll();
      final failures = results.where((r) => !r.success).toList();

      await refreshMounts();

      if (failures.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          successMessage: 'All mounts unmounted successfully',
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Some mounts failed to unmount: ${failures.length}',
        );
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Unmount all error: $e',
      );
    }
  }

  /// Open a mount in the file manager
  Future<void> openInFileManager(String mountId, {String? fileManager}) async {
    try {
      await openSshfsMountInFileManager(
        mountId: mountId,
        fileManager: fileManager,
      );
    } catch (e) {
      state = state.copyWith(error: 'Failed to open file manager: $e');
    }
  }

  /// Get default mount point for an instance
  Future<String> getDefaultMountPoint(String instanceName, String remotePath) async {
    try {
      return await getDefaultSshfsMountPoint(
        instanceName: instanceName,
        remotePath: remotePath,
      );
    } catch (e) {
      // Fallback to a simple path
      final home = '/home/${const String.fromEnvironment('USER', defaultValue: 'user')}';
      return '$home/gcp-mounts/$instanceName';
    }
  }

  /// Validate paths
  Future<(bool, String?)> validatePaths(String remotePath, String localPath) async {
    try {
      await validateSshfsRemotePath(path: remotePath);
      await validateSshfsLocalPath(path: localPath);
      return (true, null);
    } catch (e) {
      return (false, e.toString());
    }
  }

  /// Clear messages
  void clearMessages() {
    state = state.copyWith(error: null, successMessage: null);
  }
}

/// Main SSHFS mount provider
final sshfsMountProvider = NotifierProvider<SshfsMountNotifier, SshfsMountState>(
  SshfsMountNotifier.new,
);

/// Provider for mounts of a specific instance
final instanceMountsProvider = Provider.family<List<SshfsMount>, ({String projectId, String instanceName})>(
  (ref, params) {
    final mounts = ref.watch(sshfsMountProvider).activeMounts;
    return mounts.where((m) =>
      m.projectId == params.projectId &&
      m.instanceName == params.instanceName
    ).toList();
  },
);

/// Provider to check if SSHFS is available
final sshfsAvailableProvider = Provider<bool>((ref) {
  final status = ref.watch(sshfsMountProvider).status;
  return status?.installed == true && status?.fuseAvailable == true;
});

/// Provider for default file manager
final defaultFileManagerProvider = Provider<String?>((ref) {
  final fileManagers = ref.watch(sshfsMountProvider).fileManagers;
  final installed = fileManagers.where((fm) => fm.isInstalled).toList();
  if (installed.isEmpty) return null;

  // Priority: nautilus > dolphin > thunar > nemo > others
  for (final preferred in ['nautilus', 'dolphin', 'thunar', 'nemo', 'pcmanfm', 'caja', 'xdg-open']) {
    final found = installed.firstWhere(
      (fm) => fm.command == preferred,
      orElse: () => installed.first,
    );
    if (found.command == preferred) return found.command;
  }

  return installed.first.command;
});
