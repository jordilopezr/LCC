import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // For StateProvider
import 'package:shared_preferences/shared_preferences.dart';
import '../services/notification_service.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/rdp_client.dart';
import '../bridge/api.dart/vnc_client.dart';

// ==========================================
// SETTINGS PROVIDERS
// ==========================================

/// Available auto-refresh intervals (in seconds)
enum RefreshInterval {
  disabled(0, 'Disabled'),
  fast10s(10, '10 seconds'),
  default30s(30, '30 seconds'),
  medium60s(60, '1 minute'),
  slow120s(120, '2 minutes'),
  verySlow300s(300, '5 minutes'),
  custom(-1, 'Custom');

  const RefreshInterval(this.seconds, this.label);
  final int seconds;
  final String label;

  static RefreshInterval fromSeconds(int seconds) {
    for (final interval in RefreshInterval.values) {
      if (interval.seconds == seconds) return interval;
    }
    return RefreshInterval.custom;
  }
}

/// Provider for auto-refresh interval configuration
final autoRefreshIntervalProvider = NotifierProvider<AutoRefreshIntervalNotifier, RefreshInterval>(
  AutoRefreshIntervalNotifier.new,
);

class AutoRefreshIntervalNotifier extends Notifier<RefreshInterval> {
  @override
  RefreshInterval build() {
    _loadInterval();
    return RefreshInterval.default30s;
  }

  Future<void> _loadInterval() async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('auto_refresh_interval') ?? 30;
    state = RefreshInterval.fromSeconds(seconds);
  }

  Future<void> setInterval(RefreshInterval interval) async {
    state = interval;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('auto_refresh_interval', interval.seconds);
  }

  Future<void> setCustomInterval(int seconds) async {
    if (seconds < 5 || seconds > 600) {
      throw ArgumentError('Custom interval must be between 5 and 600 seconds');
    }
    state = RefreshInterval.custom;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('auto_refresh_interval', seconds);
  }

  int get intervalSeconds {
    if (state == RefreshInterval.custom) {
      // Load custom value from prefs synchronously (fallback to 30s)
      return 30; // TODO: Make this async-safe
    }
    return state.seconds;
  }
}

/// Provider for auto-refresh enabled state
final autoRefreshEnabledProvider = NotifierProvider<AutoRefreshEnabledNotifier, bool>(
  AutoRefreshEnabledNotifier.new,
);

class AutoRefreshEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    _loadEnabled();
    return true; // Default: enabled
  }

  Future<void> _loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('auto_refresh_enabled') ?? true;
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_refresh_enabled', state);
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_refresh_enabled', enabled);
  }
}

/// Provider for notifications enabled state
final notificationsEnabledProvider = NotifierProvider<NotificationsEnabledNotifier, bool>(
  NotificationsEnabledNotifier.new,
);

class NotificationsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    _loadEnabled();
    return true; // Default: enabled
  }

  Future<void> _loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('notifications_enabled') ?? true;
  }

  Future<void> toggle() async {
    state = !state;
    await NotificationService().setEnabled(state);
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await NotificationService().setEnabled(enabled);
  }
}

/// Provider for last manual refresh timestamp
final lastManualRefreshProvider = StateProvider<DateTime?>((ref) => null);

/// Provider for next auto refresh countdown (in seconds)
final nextRefreshCountdownProvider = StateProvider<int?>((ref) => null);

// ==========================================
// RDP CLIENT SETTINGS
// ==========================================

/// Provider for RDP client selection
final rdpClientProvider = NotifierProvider<RdpClientNotifier, RdpClientType>(
  RdpClientNotifier.new,
);

class RdpClientNotifier extends Notifier<RdpClientType> {
  @override
  RdpClientType build() {
    _loadClient();
    return RdpClientType.remmina; // Default for backward compatibility
  }

  Future<void> _loadClient() async {
    final prefs = await SharedPreferences.getInstance();
    final clientName = prefs.getString('rdp_client');

    if (clientName != null) {
      state = _parseClientType(clientName);
    }
  }

  Future<void> setClient(RdpClientType client) async {
    state = client;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rdp_client', _clientToString(client));
  }

  String _clientToString(RdpClientType client) {
    switch (client) {
      case RdpClientType.remmina:
        return 'remmina';
      case RdpClientType.freeRdp:
        return 'freerdp';
      case RdpClientType.krdc:
        return 'krdc';
      case RdpClientType.gnomeConnections:
        return 'gnome_connections';
      case RdpClientType.mstsc:
        return 'mstsc';
    }
  }

  RdpClientType _parseClientType(String name) {
    switch (name) {
      case 'freerdp':
        return RdpClientType.freeRdp;
      case 'krdc':
        return RdpClientType.krdc;
      case 'gnome_connections':
        return RdpClientType.gnomeConnections;
      case 'mstsc':
        return RdpClientType.mstsc;
      case 'remmina':
      default:
        return RdpClientType.remmina;
    }
  }

  /// Get display name for UI
  String displayName(RdpClientType client) {
    switch (client) {
      case RdpClientType.remmina:
        return 'Remmina';
      case RdpClientType.freeRdp:
        return 'FreeRDP (xfreerdp)';
      case RdpClientType.krdc:
        return 'KRDC';
      case RdpClientType.gnomeConnections:
        return 'GNOME Connections';
      case RdpClientType.mstsc:
        return 'Windows Remote Desktop';
    }
  }
}

/// Provider for available RDP clients on system
final availableRdpClientsProvider = FutureProvider<List<RdpClientType>>((ref) async {
  try {
    return await getAvailableRdpClients();
  } catch (e) {
    // If detection fails, return empty list
    return [];
  }
});

// ==========================================
// VNC CLIENT SETTINGS
// ==========================================

/// Provider for VNC client selection
final vncClientProvider = NotifierProvider<VncClientNotifier, VncClientType>(
  VncClientNotifier.new,
);

class VncClientNotifier extends Notifier<VncClientType> {
  @override
  VncClientType build() {
    _loadClient();
    return VncClientType.remmina; // Default for backward compatibility
  }

  Future<void> _loadClient() async {
    final prefs = await SharedPreferences.getInstance();
    final clientName = prefs.getString('vnc_client');

    if (clientName != null) {
      state = _parseClientType(clientName);
    }
  }

  Future<void> setClient(VncClientType client) async {
    state = client;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vnc_client', _clientToString(client));
  }

  String _clientToString(VncClientType client) {
    switch (client) {
      case VncClientType.remmina:
        return 'remmina';
      case VncClientType.tigerVnc:
        return 'tigervnc';
      case VncClientType.krdc:
        return 'krdc';
      case VncClientType.vinagre:
        return 'vinagre';
    }
  }

  VncClientType _parseClientType(String name) {
    switch (name) {
      case 'tigervnc':
        return VncClientType.tigerVnc;
      case 'krdc':
        return VncClientType.krdc;
      case 'vinagre':
        return VncClientType.vinagre;
      case 'remmina':
      default:
        return VncClientType.remmina;
    }
  }

  /// Get display name for UI
  String displayName(VncClientType client) {
    switch (client) {
      case VncClientType.remmina:
        return 'Remmina';
      case VncClientType.tigerVnc:
        return 'TigerVNC';
      case VncClientType.krdc:
        return 'KRDC';
      case VncClientType.vinagre:
        return 'Vinagre';
    }
  }
}

/// Provider for available VNC clients on system
final availableVncClientsProvider = FutureProvider<List<VncClientType>>((ref) async {
  try {
    return await getAvailableVncClients();
  } catch (e) {
    // If detection fails, return empty list
    return [];
  }
});

// ==========================================
// THEME SETTINGS
// ==========================================

/// Available theme modes
enum AppThemeMode {
  light('Light'),
  dark('Dark'),
  system('System (Auto)');

  const AppThemeMode(this.label);
  final String label;
}

/// Provider for app theme mode
final themeModeProvider = NotifierProvider<ThemeModeNotifier, AppThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<AppThemeMode> {
  @override
  AppThemeMode build() {
    _loadTheme();
    return AppThemeMode.system; // Default: follow system preference
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString('theme_mode');

    if (themeName != null) {
      state = _parseThemeMode(themeName);
    }
  }

  Future<void> setTheme(AppThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', _themeToString(mode));
  }

  String _themeToString(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return 'light';
      case AppThemeMode.dark:
        return 'dark';
      case AppThemeMode.system:
        return 'system';
    }
  }

  AppThemeMode _parseThemeMode(String name) {
    switch (name) {
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      case 'system':
      default:
        return AppThemeMode.system;
    }
  }
}

// ==========================================
// APP LOCALE (i18n)
// ==========================================

final localeProvider = NotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);

/// App locale override. `null` means follow the system locale.
class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() {
    _loadLocale();
    return null; // Default: follow system locale
  }

  Future<void> _loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('app_locale');
    if (code != null && code != 'system') {
      state = Locale(code);
    }
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_locale', locale?.languageCode ?? 'system');
  }
}

// ==========================================
// CONNECTION HISTORY
// ==========================================

/// Entry in connection history
class ConnectionHistoryEntry {
  final String instanceName;
  final String projectId;
  final String zone;
  final String connectionType; // 'rdp', 'ssh', 'vnc', 'sftp'
  final DateTime timestamp;
  final bool success;

  const ConnectionHistoryEntry({
    required this.instanceName,
    required this.projectId,
    required this.zone,
    required this.connectionType,
    required this.timestamp,
    this.success = true,
  });

  /// Unique key to identify the VM
  String get uniqueKey => '$projectId:$zone:$instanceName';

  /// Serialize to JSON for storage
  Map<String, dynamic> toJson() => {
    'instanceName': instanceName,
    'projectId': projectId,
    'zone': zone,
    'connectionType': connectionType,
    'timestamp': timestamp.toIso8601String(),
    'success': success,
  };

  /// Deserialize from JSON
  factory ConnectionHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ConnectionHistoryEntry(
      instanceName: json['instanceName'] as String,
      projectId: json['projectId'] as String,
      zone: json['zone'] as String,
      connectionType: json['connectionType'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      success: json['success'] as bool? ?? true,
    );
  }

  /// Icon for the connection type
  String get typeIcon {
    switch (connectionType) {
      case 'rdp':
        return 'desktop_windows';
      case 'ssh':
        return 'terminal';
      case 'vnc':
        return 'remove_red_eye';
      case 'sftp':
        return 'folder_open';
      default:
        return 'link';
    }
  }

  /// Display label for connection type
  String get typeLabel {
    switch (connectionType) {
      case 'rdp':
        return 'RDP';
      case 'ssh':
        return 'SSH';
      case 'vnc':
        return 'VNC';
      case 'sftp':
        return 'SFTP';
      default:
        return connectionType.toUpperCase();
    }
  }
}

/// Provider for connection history
final connectionHistoryProvider = NotifierProvider<ConnectionHistoryNotifier, List<ConnectionHistoryEntry>>(
  ConnectionHistoryNotifier.new,
);

class ConnectionHistoryNotifier extends Notifier<List<ConnectionHistoryEntry>> {
  static const int maxEntries = 50;
  static const int retentionDays = 30;
  static const String _storageKey = 'connection_history';

  @override
  List<ConnectionHistoryEntry> build() {
    _loadHistory();
    return [];
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_storageKey) ?? [];

    final entries = <ConnectionHistoryEntry>[];
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: retentionDays));

    for (final jsonStr in jsonList) {
      try {
        final json = Map<String, dynamic>.from(
          // ignore: avoid_dynamic_calls
          (jsonStr as dynamic) is String
              ? _parseJson(jsonStr)
              : jsonStr as Map<String, dynamic>
        );
        final entry = ConnectionHistoryEntry.fromJson(json);
        // Only include entries within retention period
        if (entry.timestamp.isAfter(cutoff)) {
          entries.add(entry);
        }
      } catch (e) {
        // Skip invalid entries
        continue;
      }
    }

    // Sort by timestamp descending (most recent first)
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    state = entries;
  }

  Map<String, dynamic> _parseJson(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } catch (_) {
      return {};
    }
  }

  String _toJsonString(Map<String, dynamic> map) {
    return jsonEncode(map);
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = state.map((e) => _toJsonString(e.toJson())).toList();
    await prefs.setStringList(_storageKey, jsonList);
  }

  /// Add a new entry to history
  Future<void> addEntry(ConnectionHistoryEntry entry) async {
    // Remove duplicate entries for same VM (keep the new one)
    final filtered = state.where((e) => e.uniqueKey != entry.uniqueKey).toList();

    // Add new entry at the beginning
    final newList = [entry, ...filtered];

    // Limit to max entries
    state = newList.take(maxEntries).toList();
    await _saveHistory();
  }

  /// Clear all history
  Future<void> clearHistory() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  /// Remove old entries (called on app startup)
  Future<void> cleanupOldEntries() async {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: retentionDays));

    final filtered = state.where((e) => e.timestamp.isAfter(cutoff)).toList();

    if (filtered.length != state.length) {
      state = filtered;
      await _saveHistory();
    }
  }
}

// ==========================================
// FAVORITES
// ==========================================

/// Provider for favorite VMs
final favoritesProvider = NotifierProvider<FavoritesNotifier, Set<String>>(
  FavoritesNotifier.new,
);

class FavoritesNotifier extends Notifier<Set<String>> {
  static const String _storageKey = 'favorite_vms';

  @override
  Set<String> build() {
    _loadFavorites();
    return {};
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_storageKey) ?? [];
    state = list.toSet();
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storageKey, state.toList());
  }

  /// Check if a VM is favorite
  bool isFavorite(String uniqueKey) => state.contains(uniqueKey);

  /// Toggle favorite status
  Future<void> toggle(String uniqueKey) async {
    if (state.contains(uniqueKey)) {
      state = {...state}..remove(uniqueKey);
    } else {
      state = {...state, uniqueKey};
    }
    await _saveFavorites();
  }

  /// Add to favorites
  Future<void> addFavorite(String uniqueKey) async {
    if (!state.contains(uniqueKey)) {
      state = {...state, uniqueKey};
      await _saveFavorites();
    }
  }

  /// Remove from favorites
  Future<void> removeFavorite(String uniqueKey) async {
    if (state.contains(uniqueKey)) {
      state = {...state}..remove(uniqueKey);
      await _saveFavorites();
    }
  }
}
