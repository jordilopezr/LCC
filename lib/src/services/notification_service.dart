import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

/// Service for managing desktop notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _notificationsEnabled = true;

  AppLocalizations? _l10n;

  /// Keep the service's localizations in sync with the app's current locale.
  /// Called from a widget below MaterialApp (see main.dart), so it uses the
  /// same resolved locale as the UI (including "system").
  void updateLocalizations(AppLocalizations l10n) {
    _l10n = l10n;
  }

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_initialized) return;

    // Load preferences
    final prefs = await SharedPreferences.getInstance();
    _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;

    // Linux/Ubuntu initialization settings
    final initializationSettingsLinux = LinuxInitializationSettings(
      defaultActionName: 'Open notification',
      defaultIcon: AssetsLinuxIcon('assets/icon.png'),
    );

    final initializationSettings = InitializationSettings(
      linux: initializationSettingsLinux,
    );

    try {
      await _notifications.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationTap,
      );
      _initialized = true;
      print('[NotificationService] Initialized successfully');
    } catch (e) {
      print('[NotificationService] Failed to initialize: $e');
      // Fallback: disable notifications if initialization fails
      _initialized = false;
      _notificationsEnabled = false;
    }
  }

  /// Handle notification tap
  void _onNotificationTap(NotificationResponse response) {
    print('[NotificationService] Notification tapped: ${response.payload}');
    // TODO: Handle navigation based on payload
  }

  /// Check if notifications are enabled
  bool get isEnabled => _notificationsEnabled && _initialized;

  /// Enable or disable notifications
  Future<void> setEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', enabled);
  }

  /// Show a notification about VM state change
  Future<void> notifyVmStateChange({
    required String instanceName,
    required String oldState,
    required String newState,
    required String project,
    required String zone,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;

    final title = l10n.notifVmStateChangeTitle(instanceName);
    final body = l10n.notifVmStateChangeBody(oldState, newState, project, zone);

    await _showNotification(
      id: instanceName.hashCode,
      title: title,
      body: body,
      payload: 'vm_state_change:$project:$zone:$instanceName',
    );
  }

  /// Show a notification about tunnel failure
  Future<void> notifyTunnelFailed({
    required String instanceName,
    required int remotePort,
    required String project,
    required String zone,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;

    final title = l10n.notifTunnelFailedTitle(instanceName);
    final body = l10n.notifTunnelFailedBody(remotePort, project, zone);

    await _showNotification(
      id: '$instanceName:$remotePort'.hashCode,
      title: title,
      body: body,
      payload: 'tunnel_failed:$project:$zone:$instanceName:$remotePort',
      importance: Importance.high,
      priority: Priority.high,
    );
  }

  /// Show a notification about lifecycle operation completion
  Future<void> notifyLifecycleOperation({
    required String instanceName,
    required String operation,
    required bool success,
    required String project,
    required String zone,
    String? errorMessage,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;

    final title = success
        ? l10n.notifLifecycleSuccessTitle(operation, instanceName)
        : l10n.notifLifecycleFailedTitle(operation, instanceName);
    final body = success
        ? l10n.notifLifecycleSuccessBody(project, zone)
        : l10n.notifLifecycleFailedBody(errorMessage ?? l10n.notifUnknownError, project, zone);

    await _showNotification(
      id: '$operation:$instanceName'.hashCode,
      title: title,
      body: body,
      payload: 'lifecycle:$project:$zone:$instanceName:$operation',
      importance: success ? Importance.defaultImportance : Importance.high,
      priority: success ? Priority.defaultPriority : Priority.high,
    );
  }

  /// Show a notification about tunnel reconnection attempt
  Future<void> notifyTunnelReconnecting({
    required String instanceName,
    required int remotePort,
    required int attempt,
    required int maxAttempts,
    required String project,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;

    final title = l10n.notifTunnelReconnectingTitle(instanceName);
    final body = l10n.notifTunnelReconnectingBody(remotePort, attempt, maxAttempts, project);

    await _showNotification(
      id: 'reconnect:$instanceName:$remotePort'.hashCode,
      title: title,
      body: body,
      payload: 'tunnel_reconnecting:$project:$instanceName:$remotePort',
    );
  }

  /// Show a notification about successful tunnel reconnection
  Future<void> notifyTunnelReconnected({
    required String instanceName,
    required int remotePort,
    required String project,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;

    final title = l10n.notifTunnelReconnectedTitle(instanceName);
    final body = l10n.notifTunnelReconnectedBody(remotePort, project);

    await _showNotification(
      id: 'reconnect:$instanceName:$remotePort'.hashCode,
      title: title,
      body: body,
      payload: 'tunnel_reconnected:$project:$instanceName:$remotePort',
    );
  }

  /// Show a notification about tunnel giving up reconnection
  Future<void> notifyTunnelGaveUp({
    required String instanceName,
    required int remotePort,
    required int maxAttempts,
    required String project,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;

    final title = l10n.notifTunnelGaveUpTitle(instanceName);
    final body = l10n.notifTunnelGaveUpBody(remotePort, maxAttempts, project);

    await _showNotification(
      id: 'reconnect:$instanceName:$remotePort'.hashCode,
      title: title,
      body: body,
      payload: 'tunnel_gave_up:$project:$instanceName:$remotePort',
      importance: Importance.high,
      priority: Priority.high,
    );
  }

  /// Show a notification that a preferred RDP/VNC client was unavailable and a
  /// fallback client was used. `protocol` is "RDP"/"VNC" (raw, not translated).
  Future<void> notifyClientFallback({
    required String protocol,
    required String clientName,
  }) async {
    if (!isEnabled) return;
    final l10n = _l10n;
    if (l10n == null) return;
    await _showNotification(
      id: 'fallback:$protocol'.hashCode,
      title: l10n.notifClientFallbackTitle(protocol),
      body: l10n.notifClientFallbackBody(clientName),
      payload: 'client_fallback:$protocol',
    );
  }

  /// Internal method to show notification
  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    Importance importance = Importance.defaultImportance,
    Priority priority = Priority.defaultPriority,
  }) async {
    if (!_initialized) {
      print('[NotificationService] Not initialized, skipping notification');
      return;
    }

    try {
      final linuxDetails = LinuxNotificationDetails(
        defaultActionName: 'Open',
        category: LinuxNotificationCategory.deviceAdded,
      );

      final notificationDetails = NotificationDetails(
        linux: linuxDetails,
      );

      await _notifications.show(
        id,
        title,
        body,
        notificationDetails,
        payload: payload,
      );

      print('[NotificationService] Shown: $title');
    } catch (e) {
      print('[NotificationService] Failed to show notification: $e');
    }
  }

  /// Cancel a specific notification
  Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }

  /// Cancel all notifications
  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }
}
