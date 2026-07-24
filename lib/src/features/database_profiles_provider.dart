import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/db_client.dart';

// ==========================================
// DATABASE PROFILES PROVIDER
// ==========================================

/// A saved database connection profile
class DbConnectionProfile {
  final String id;
  final String name;
  final DatabaseType databaseType;
  final int remotePort;
  final String? databaseName;
  final String? username;
  final DbClientType? preferredClient;
  final DateTime createdAt;
  final DateTime lastUsed;

  const DbConnectionProfile({
    required this.id,
    required this.name,
    required this.databaseType,
    required this.remotePort,
    this.databaseName,
    this.username,
    this.preferredClient,
    required this.createdAt,
    required this.lastUsed,
  });

  /// Get default port for database type
  static int getDefaultPort(DatabaseType type) {
    switch (type) {
      case DatabaseType.mySql:
        return 3306;
      case DatabaseType.postgreSql:
        return 5432;
      case DatabaseType.sqlServer:
        return 1433;
      case DatabaseType.redis:
        return 6379;
      case DatabaseType.mongoDb:
        return 27017;
    }
  }

  /// Get display name for database type
  static String getDatabaseTypeName(DatabaseType type) {
    switch (type) {
      case DatabaseType.mySql:
        return 'MySQL';
      case DatabaseType.postgreSql:
        return 'PostgreSQL';
      case DatabaseType.sqlServer:
        return 'SQL Server';
      case DatabaseType.redis:
        return 'Redis';
      case DatabaseType.mongoDb:
        return 'MongoDB';
    }
  }

  /// Get display name for client type
  static String getClientTypeName(DbClientType type) {
    switch (type) {
      case DbClientType.dBeaver:
        return 'DBeaver';
      case DbClientType.mySqlWorkbench:
        return 'MySQL Workbench';
      case DbClientType.pgAdmin:
        return 'pgAdmin 4';
      case DbClientType.azureDataStudio:
        return 'Azure Data Studio';
      case DbClientType.redisInsight:
        return 'RedisInsight';
      case DbClientType.mongoDbCompass:
        return 'MongoDB Compass';
    }
  }

  /// Create a copy with updated lastUsed
  DbConnectionProfile copyWithLastUsed(DateTime time) {
    return DbConnectionProfile(
      id: id,
      name: name,
      databaseType: databaseType,
      remotePort: remotePort,
      databaseName: databaseName,
      username: username,
      preferredClient: preferredClient,
      createdAt: createdAt,
      lastUsed: time,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'databaseType': databaseType.index,
    'remotePort': remotePort,
    'databaseName': databaseName,
    'username': username,
    'preferredClient': preferredClient?.index,
    'createdAt': createdAt.toIso8601String(),
    'lastUsed': lastUsed.toIso8601String(),
  };

  /// Deserialize from JSON
  factory DbConnectionProfile.fromJson(Map<String, dynamic> json) {
    return DbConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      databaseType: DatabaseType.values[json['databaseType'] as int],
      remotePort: json['remotePort'] as int,
      databaseName: json['databaseName'] as String?,
      username: json['username'] as String?,
      preferredClient: json['preferredClient'] != null
          ? DbClientType.values[json['preferredClient'] as int]
          : null,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastUsed: DateTime.parse(json['lastUsed'] as String),
    );
  }
}

/// Provider for database connection profiles
final dbProfilesProvider = NotifierProvider<DbProfilesNotifier, List<DbConnectionProfile>>(
  DbProfilesNotifier.new,
);

class DbProfilesNotifier extends Notifier<List<DbConnectionProfile>> {
  static const String _storageKey = 'db_connection_profiles';

  @override
  List<DbConnectionProfile> build() {
    _loadProfiles();
    return [];
  }

  Future<void> _loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_storageKey) ?? [];

    final profiles = <DbConnectionProfile>[];
    for (final jsonStr in jsonList) {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        profiles.add(DbConnectionProfile.fromJson(json));
      } catch (e) {
        // Skip invalid entries
        continue;
      }
    }

    // Sort by last used (most recent first)
    profiles.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    state = profiles;
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = state.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_storageKey, jsonList);
  }

  /// Add a new profile
  Future<void> addProfile(DbConnectionProfile profile) async {
    // Check for duplicate names
    final existing = state.where((p) => p.name == profile.name).toList();
    if (existing.isNotEmpty) {
      // Update existing profile instead
      await updateProfile(profile.copyWithLastUsed(DateTime.now()));
      return;
    }

    state = [profile, ...state];
    await _saveProfiles();
  }

  /// Update an existing profile
  Future<void> updateProfile(DbConnectionProfile profile) async {
    state = state.map((p) => p.id == profile.id ? profile : p).toList();
    await _saveProfiles();
  }

  /// Remove a profile
  Future<void> removeProfile(String id) async {
    state = state.where((p) => p.id != id).toList();
    await _saveProfiles();
  }

  /// Mark a profile as recently used
  Future<void> markUsed(String id) async {
    final profile = state.firstWhere((p) => p.id == id);
    final updated = profile.copyWithLastUsed(DateTime.now());
    await updateProfile(updated);
  }

  /// Clear all profiles
  Future<void> clearProfiles() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}

// ==========================================
// DATABASE CLIENT DETECTION PROVIDERS
// ==========================================

/// Provider for all available database clients on the system
final availableDbClientsProvider = FutureProvider<List<DbClientType>>((ref) async {
  try {
    return await getAvailableDbClients();
  } catch (e) {
    return [];
  }
});

/// Provider for available clients for a specific database type
final availableClientsForDbProvider = FutureProvider.family<List<DbClientType>, DatabaseType>((ref, dbType) async {
  try {
    return await getAvailableClientsForDbType(dbType: dbType);
  } catch (e) {
    return [];
  }
});

/// Provider for the default port of a database type
final defaultDbPortProvider = Provider.family<int, DatabaseType>((ref, dbType) {
  return DbConnectionProfile.getDefaultPort(dbType);
});

// ==========================================
// SELECTED DATABASE CLIENT PROVIDER
// ==========================================

/// Provider for user's preferred database client selection per database type
final preferredDbClientProvider = NotifierProvider<PreferredDbClientNotifier, Map<DatabaseType, DbClientType?>>(
  PreferredDbClientNotifier.new,
);

class PreferredDbClientNotifier extends Notifier<Map<DatabaseType, DbClientType?>> {
  static const String _storageKey = 'preferred_db_clients';

  @override
  Map<DatabaseType, DbClientType?> build() {
    _loadPreferences();
    return {};
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_storageKey);

    if (jsonStr != null) {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        final result = <DatabaseType, DbClientType?>{};

        for (final entry in json.entries) {
          final dbTypeIndex = int.tryParse(entry.key);
          if (dbTypeIndex != null && dbTypeIndex < DatabaseType.values.length) {
            final dbType = DatabaseType.values[dbTypeIndex];
            final clientIndex = entry.value as int?;
            if (clientIndex != null && clientIndex < DbClientType.values.length) {
              result[dbType] = DbClientType.values[clientIndex];
            }
          }
        }

        state = result;
      } catch (e) {
        // Keep empty map on error
      }
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final json = <String, int?>{};

    for (final entry in state.entries) {
      json[entry.key.index.toString()] = entry.value?.index;
    }

    await prefs.setString(_storageKey, jsonEncode(json));
  }

  /// Set preferred client for a database type
  Future<void> setPreferredClient(DatabaseType dbType, DbClientType? client) async {
    state = {...state, dbType: client};
    await _savePreferences();
  }

  /// Get preferred client for a database type
  DbClientType? getPreferredClient(DatabaseType dbType) {
    return state[dbType];
  }
}
