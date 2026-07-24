/// Windows Credentials Provider - Sprint 5
///
/// State management for Windows VM credential generation and storage.
/// Uses Riverpod for state management and the Rust backend for
/// credential operations with libsecret.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/windows_credentials/storage.dart';

/// State for Windows credentials
class WindowsCredentialsState {
  final List<WindowsCredential> credentials;
  final bool isLoading;
  final String? error;
  final String? successMessage;

  const WindowsCredentialsState({
    this.credentials = const [],
    this.isLoading = false,
    this.error,
    this.successMessage,
  });

  WindowsCredentialsState copyWith({
    List<WindowsCredential>? credentials,
    bool? isLoading,
    String? error,
    String? successMessage,
  }) {
    return WindowsCredentialsState(
      credentials: credentials ?? this.credentials,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      successMessage: successMessage,
    );
  }
}

/// Notifier for Windows credentials state
class WindowsCredentialsNotifier extends Notifier<WindowsCredentialsState> {
  @override
  WindowsCredentialsState build() {
    // Load credentials on initialization
    _loadCredentials();
    return const WindowsCredentialsState();
  }

  /// Load all stored credentials
  Future<void> _loadCredentials() async {
    try {
      final credentials = await getAllWindowsCredentials();
      state = state.copyWith(credentials: credentials);
    } catch (e) {
      state = state.copyWith(error: 'Failed to load credentials: $e');
    }
  }

  /// Reload credentials from storage
  Future<void> refresh() async {
    await _loadCredentials();
  }

  /// Generate a new Windows password for a VM
  Future<WindowsCredential?> generatePassword({
    required String projectId,
    required String zone,
    required String instanceName,
    required String username,
    required String email,
  }) async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final credential = await generateWindowsPassword(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        username: username,
        email: email,
      );

      // Reload credentials to include the new one
      await _loadCredentials();

      state = state.copyWith(
        isLoading: false,
        successMessage: 'Password generated successfully for $username@$instanceName',
      );

      return credential;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to generate password: $e',
      );
      return null;
    }
  }

  /// Reset (regenerate) a Windows password
  Future<WindowsCredential?> resetPassword({
    required String projectId,
    required String zone,
    required String instanceName,
    required String username,
    required String email,
  }) async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final credential = await resetWindowsPassword(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        username: username,
        email: email,
      );

      // Reload credentials
      await _loadCredentials();

      state = state.copyWith(
        isLoading: false,
        successMessage: 'Password reset successfully for $username@$instanceName',
      );

      return credential;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to reset password: $e',
      );
      return null;
    }
  }

  /// Get stored credential for a specific instance
  WindowsCredential? getCredentialForInstance({
    required String projectId,
    required String zone,
    required String instanceName,
  }) {
    try {
      return state.credentials.firstWhere(
        (c) =>
            c.projectId == projectId &&
            c.zone == zone &&
            c.instanceName == instanceName,
      );
    } catch (_) {
      return null;
    }
  }

  /// Delete a stored credential
  Future<void> deleteCredential({
    required String projectId,
    required String zone,
    required String instanceName,
  }) async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      await deleteWindowsCredential(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
      );

      // Reload credentials
      await _loadCredentials();

      state = state.copyWith(
        isLoading: false,
        successMessage: 'Credential deleted for $instanceName',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to delete credential: $e',
      );
    }
  }

  /// Clear all stored credentials
  Future<void> clearAll() async {
    state = state.copyWith(isLoading: true, error: null, successMessage: null);

    try {
      final count = await clearAllWindowsCredentials();

      state = WindowsCredentialsState(
        credentials: const [],
        isLoading: false,
        successMessage: 'Cleared $count credentials',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to clear credentials: $e',
      );
    }
  }

  /// Clear any error/success messages
  void clearMessages() {
    state = state.copyWith(error: null, successMessage: null);
  }
}

/// Main provider for Windows credentials
final windowsCredentialsProvider =
    NotifierProvider<WindowsCredentialsNotifier, WindowsCredentialsState>(
  WindowsCredentialsNotifier.new,
);

/// Provider to check if an instance is a Windows VM
final isWindowsInstanceProvider = FutureProvider.family<bool, ({String projectId, String zone, String instanceName})>(
  (ref, params) async {
    try {
      return await isWindowsInstance(
        projectId: params.projectId,
        zone: params.zone,
        instanceName: params.instanceName,
      );
    } catch (_) {
      return false;
    }
  },
);

/// Provider to get stored credential for a specific instance
final instanceCredentialProvider = Provider.family<WindowsCredential?, ({String projectId, String zone, String instanceName})>(
  (ref, params) {
    final state = ref.watch(windowsCredentialsProvider);
    try {
      return state.credentials.firstWhere(
        (c) =>
            c.projectId == params.projectId &&
            c.zone == params.zone &&
            c.instanceName == params.instanceName,
      );
    } catch (_) {
      return null;
    }
  },
);
