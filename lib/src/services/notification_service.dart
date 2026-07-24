import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing desktop notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _notificationsEnabled = true;

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

    final title = 'VM State Changed: $instanceName';
    final body = '$oldState → $newState\n$project/$zone';

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

    final title = 'IAP Tunnel Failed: $instanceName';
    final body = 'Port $remotePort disconnected\n$project/$zone';

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

    final title = success
        ? '✓ $operation completed: $instanceName'
        : '✗ $operation failed: $instanceName';
    final body = success
        ? '$project/$zone'
        : '${errorMessage ?? 'Unknown error'}\n$project/$zone';

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

    final title = 'Tunnel Reconnecting: $instanceName';
    final body = 'Port $remotePort - Attempt $attempt/$maxAttempts\n$project';

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

    final title = 'Tunnel Reconnected: $instanceName';
    final body = 'Port $remotePort successfully restored\n$project';

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

    final title = 'Tunnel Failed: $instanceName';
    final body = 'Port $remotePort - Gave up after $maxAttempts attempts\n$project';

    await _showNotification(
      id: 'reconnect:$instanceName:$remotePort'.hashCode,
      title: title,
      body: body,
      payload: 'tunnel_gave_up:$project:$instanceName:$remotePort',
      importance: Importance.high,
      priority: Priority.high,
    );
  }

  /// Show a general notification
  Future<void> notifyGeneral({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!isEnabled) return;

    await _showNotification(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      payload: payload,
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
