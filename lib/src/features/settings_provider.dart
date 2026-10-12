import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // For StateProvider

import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/src/features/vnc_display.dart';
import '../services/notification_service.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/rdp_client.dart';
import '../bridge/api.dart/vnc_client.dart';
import 'gcloud_provider.dart' show accountProvider;

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

/// Read back a stored RDP client preference.
///
/// Top-level and not a method so it can be tested without a provider
/// container: the one behaviour worth pinning here is what happens to a
/// preference this version no longer has a client for. 'mstsc' is the live
/// case — LCC offered Windows Remote Desktop until build 20260924.36, a client
/// that could never launch on any platform it builds for — and anyone who
/// selected it has that string on disk today.
///
/// Unknown names fall back to Remmina rather than throwing. That is what makes
/// the removal safe, and it holds only as long as the default arm stays.
RdpClientType parseRdpClientName(String name) {
  switch (name) {
    case 'freerdp':
      return RdpClientType.freeRdp;
    case 'krdc':
      return RdpClientType.krdc;
    case 'gnome_connections':
      return RdpClientType.gnomeConnections;
    case 'remmina':
    default:
      return RdpClientType.remmina;
  }
}

/// The VNC display remembered for each VM, keyed by project:zone:instance.
///
/// The first per-VM setting in the app; everything else here is global. A VM's
/// display does not change, so asking for it on every connection would be
/// friction with no upside.
///
/// The map is never pruned. An entry is about forty bytes, so a thousand VMs
/// cost forty kilobytes — while pruning would need usage bookkeeping and could
/// silently drop a display the user set on purpose. Losing a deliberate
/// setting is the worse failure.
class VncDisplayNotifier extends Notifier<Map<String, int>> {
  static const _prefsKey = 'vnc_displays';

  /// The read of the stored map, started by [build]. Every write and every
  /// answer that must be right waits on it.
  ///
  /// It used to be fire-and-forget, and the map started empty. A `setDisplay`
  /// that arrived before the read landed computed its new map from `{}` and
  /// wrote it over the whole stored one: measured on 2026-10-01, `{vm-a: 1,
  /// vm-b: 2}` on disk became `{vm-c: 0}` after one right-click VNC.
  late Future<void> _loaded;

  @override
  Map<String, int> build() {
    // build() is synchronous, so the state starts empty and fills in when the
    // read lands. Reading `state` in that window answers 0 for every VM; use
    // [displayFor] where the answer must be the stored one.
    _loaded = _load();
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = decodeVncDisplays(prefs.getString(_prefsKey));
  }

  /// The display stored for `vmKey`, once the stored map has been read.
  Future<int> displayFor(String vmKey) async {
    await _loaded;
    return vncDisplayFor(state, vmKey);
  }

  /// Remember `display` for this VM. Called when the user accepts the dialog,
  /// not when the connection succeeds: a wrong number stays visible in the
  /// field and gets corrected, where forgetting it would make them retype.
  Future<void> setDisplay(String vmKey, int display) async {
    // Never compute the new map from one that has not been read yet: that is
    // how every other VM's display was erased.
    await _loaded;
    state = withVncDisplay(state, vmKey, display);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, encodeVncDisplays(state));
  }
}

final vncDisplayProvider =
    NotifierProvider<VncDisplayNotifier, Map<String, int>>(
        VncDisplayNotifier.new);

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
    }
  }

  RdpClientType _parseClientType(String name) => parseRdpClientName(name);

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

/// The preferences key for [base] belonging to [account], or null when no
/// account is active.
///
/// History and favorites used to be one global list each, so a newly
/// signed-in account was shown the VMs and projects another account had
/// connected to or starred.
///
/// Those old global lists are handed to the account signed in when the upgrade
/// lands and then removed, so a second account does not inherit them: see
/// [handLegacyListsToAccount]. Giving them to nobody, as this first did, made
/// them invisible for good.
String? accountScopedKey(String base, String? account) =>
    account == null ? null : '$base:$account';

/// Hands both pre-account global lists — history and favorites — over to
/// [account], together.
///
/// Together is the whole point. This used to live in each notifier's own load,
/// so a list was only handed over once something on screen read that provider.
/// Measured on a real machine on 2026-10-12: the VM panel reads the favorites
/// as soon as it opens, the history is not read until its own view is opened,
/// so the star went to one account and the history sat waiting — and would
/// have gone to whichever account happened to be active whenever that view was
/// first opened. Both loads call this, so the first one to run hands over
/// both and they cannot end up on different accounts.
///
/// Each half is a no-op once its global key is gone, so calling this on every
/// load and every account change costs one preferences read.
Future<void> handLegacyListsToAccount(
    SharedPreferences prefs, String account) async {
  await _handOverHistory(prefs, account);
  await _handOverFavorites(prefs, account);
}

/// One entry per VM, the most recent — the rule [ConnectionHistoryNotifier.addEntry]
/// already follows. The same VM can sit in both lists with different times.
Future<void> _handOverHistory(SharedPreferences prefs, String account) async {
  const base = ConnectionHistoryNotifier._storageKey;
  final legacy = prefs.getStringList(base);
  if (legacy == null) return; // ya entregada, o nunca hubo
  final key = '$base:$account';

  // Se guardan las cadenas tal como vinieron: reescribirlas por un ida y
  // vuelta de JSON podría perder cualquier campo que `toJson` no ponga.
  final dated = <({DateTime at, String vm, String raw})>[];
  for (final raw in [...?prefs.getStringList(key), ...legacy]) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) continue;
      final entry = ConnectionHistoryEntry.fromJson(decoded);
      dated.add((at: entry.timestamp, vm: entry.uniqueKey, raw: raw));
    } catch (e) {
      continue; // una entrada ilegible no bloquea la entrega
    }
  }
  dated.sort((a, b) => b.at.compareTo(a.at));
  final seen = <String>{};
  final merged = [for (final d in dated) if (seen.add(d.vm)) d.raw];

  // Escribir antes de borrar: si algo falla en medio sobra, no falta.
  await prefs.setStringList(key, merged);
  await prefs.remove(base);
}

Future<void> _handOverFavorites(SharedPreferences prefs, String account) async {
  const base = FavoritesNotifier._storageKey;
  final legacy = prefs.getStringList(base);
  if (legacy == null) return;
  final key = '$base:$account';
  await prefs.setStringList(
      key, {...?prefs.getStringList(key), ...legacy}.toList());
  await prefs.remove(base);
}

/// Provider for connection history
final connectionHistoryProvider = NotifierProvider<ConnectionHistoryNotifier, List<ConnectionHistoryEntry>>(
  ConnectionHistoryNotifier.new,
);

class ConnectionHistoryNotifier extends Notifier<List<ConnectionHistoryEntry>> {
  static const int maxEntries = 50;
  static const int retentionDays = 30;
  static const String _storageKey = 'connection_history';

  /// This account's key, or null with no active account (nothing is read or
  /// written then).
  String? _key;

  /// The read of this account's history, started by [build]. Every write
  /// waits on it.
  ///
  /// It used to be fire-and-forget, and the state starts empty: an entry
  /// added before the read landed computed its new list from `[]` and wrote
  /// it over the stored one. Measured on 2026-10-03: two stored connections
  /// plus one new left **one** entry on disk.
  late Future<void> _loaded;

  @override
  List<ConnectionHistoryEntry> build() {
    final account =
        ref.watch(accountProvider.select((s) => s.activeAccountEmail));
    final key = _key = accountScopedKey(_storageKey, account);
    // With no account there is nothing to read, but `_loaded` must still be
    // assigned: writes await it without knowing whether an account was there.
    _loaded =
        key == null ? Future<void>.value() : _loadHistory(key, account!);
    return [];
  }

  /// Waits for the stored history and answers the key to write to, or null
  /// when there is no active account or the account changed while waiting —
  /// in which case what was about to be written belonged to the previous one.
  ///
  /// The account check is load-bearing, and it took being removed to prove it.
  /// On 2026-10-06 a switch was measured to dispose this notifier fast enough
  /// that the write in flight died with it, so the check looked like dead code
  /// and was dropped. Handing the legacy lists over added three awaits to the
  /// load, the switch started landing inside that window, and one account's
  /// star was written into the other's file.
  Future<String?> _keyAfterLoad() async {
    final key = _key;
    await _loaded;
    return (!ref.mounted || _key != key) ? null : key;
  }

  Future<void> _loadHistory(String key, String account) async {
    final prefs = await SharedPreferences.getInstance();
    await handLegacyListsToAccount(prefs, account);
    final jsonList = prefs.getStringList(key) ?? [];

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
    // The account may have changed while this was loading.
    if (!ref.mounted || _key != key) return;
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

  /// Writes to [key], the one the operation started on — never to whatever
  /// `_key` happens to hold by now.
  ///
  /// Reading `_key` here instead left a window between the check in
  /// [_keyAfterLoad] and this save: an account switch landing inside it put
  /// one account's entries in the other's file. Measured 10 runs out of 10
  /// on 2026-10-06, once handing the legacy lists over had lengthened the
  /// load enough for the switch to land there.
  Future<void> _saveHistory(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = state.map((e) => _toJsonString(e.toJson())).toList();
    await prefs.setStringList(key, jsonList);
  }

  /// Add a new entry to history
  Future<void> addEntry(ConnectionHistoryEntry entry) async {
    // Never compute the new list from one that has not been read yet: that is
    // how the stored connections were erased.
    final key = await _keyAfterLoad();
    if (key == null) return;
    // Remove duplicate entries for same VM (keep the new one)
    final filtered = state.where((e) => e.uniqueKey != entry.uniqueKey).toList();

    // Add new entry at the beginning
    final newList = [entry, ...filtered];

    // Limit to max entries
    state = newList.take(maxEntries).toList();
    await _saveHistory(key);
  }

  /// Clear all history
  Future<void> clearHistory() async {
    // Waited on so the read cannot land afterwards and bring back what was
    // just cleared.
    final key = await _keyAfterLoad();
    state = [];
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// Remove old entries (called on app startup)
  Future<void> cleanupOldEntries() async {
    // Without the stored entries there is nothing to judge the age of, and
    // the empty result would be written over them.
    final key = await _keyAfterLoad();
    if (key == null) return;
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: retentionDays));

    final filtered = state.where((e) => e.timestamp.isAfter(cutoff)).toList();

    if (filtered.length != state.length) {
      state = filtered;
      await _saveHistory(key);
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

  /// This account's key, or null with no active account (nothing is read or
  /// written then).
  String? _key;

  /// The read of this account's favorites, started by [build]. Every write
  /// waits on it. See [ConnectionHistoryNotifier._loaded]: starred VMs were
  /// erased the same way.
  late Future<void> _loaded;

  @override
  Set<String> build() {
    final account =
        ref.watch(accountProvider.select((s) => s.activeAccountEmail));
    final key = _key = accountScopedKey(_storageKey, account);
    _loaded =
        key == null ? Future<void>.value() : _loadFavorites(key, account!);
    return {};
  }

  /// Waits for the stored favorites and answers the key to write to, or null
  /// when there is no active account or the account changed while waiting.
  /// See [ConnectionHistoryNotifier._keyAfterLoad] on why that check is there.
  Future<String?> _keyAfterLoad() async {
    final key = _key;
    await _loaded;
    return (!ref.mounted || _key != key) ? null : key;
  }

  Future<void> _loadFavorites(String key, String account) async {
    final prefs = await SharedPreferences.getInstance();
    await handLegacyListsToAccount(prefs, account);
    final list = prefs.getStringList(key) ?? [];
    // The account may have changed while this was loading.
    if (!ref.mounted || _key != key) return;
    state = list.toSet();
  }

  /// Writes to [key], the one the operation started on. See
  /// [ConnectionHistoryNotifier._saveHistory] on why it is not read from
  /// `_key` here.
  Future<void> _saveFavorites(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, state.toList());
  }

  /// Check if a VM is favorite
  bool isFavorite(String uniqueKey) => state.contains(uniqueKey);

  /// Toggle favorite status
  Future<void> toggle(String uniqueKey) async {
    // Never decide from a set that has not been read yet: starring one VM
    // wrote it over every other starred one, and unstarring did nothing.
    final key = await _keyAfterLoad();
    if (key == null) return;
    if (state.contains(uniqueKey)) {
      state = {...state}..remove(uniqueKey);
    } else {
      state = {...state, uniqueKey};
    }
    await _saveFavorites(key);
  }

  /// Add to favorites
  Future<void> addFavorite(String uniqueKey) async {
    final key = await _keyAfterLoad();
    if (key == null) return;
    if (!state.contains(uniqueKey)) {
      state = {...state, uniqueKey};
      await _saveFavorites(key);
    }
  }

  /// Remove from favorites
  Future<void> removeFavorite(String uniqueKey) async {
    final key = await _keyAfterLoad();
    if (key == null) return;
    if (state.contains(uniqueKey)) {
      state = {...state}..remove(uniqueKey);
      await _saveFavorites(key);
    }
  }
}
