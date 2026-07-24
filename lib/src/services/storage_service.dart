import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  // Singleton instance
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  late final FlutterSecureStorage _secureStorage;
  late final SharedPreferences _sharedPrefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    
    _secureStorage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      // Linux uses libsecret by default, which is what we want.
    );
    
    _sharedPrefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  // --- General Preferences (SharedPreferences) ---

  Future<void> saveLastProject(String projectId) async {
    await _sharedPrefs.setString('last_project_id', projectId);
  }

  String? getLastProject() {
    return _sharedPrefs.getString('last_project_id');
  }

  Future<void> saveApiMethod(String method) async {
    await _sharedPrefs.setString('api_method', method);
  }

  String getLastApiMethod() {
    return _sharedPrefs.getString('api_method') ?? 'clientLibrary';
  }

  // --- Multi-Project Support ---

  /// Maximum number of projects that can be selected simultaneously
  static const int maxSelectedProjects = 10;

  /// Regex for validating GCP project IDs
  static final RegExp _projectIdRegex = RegExp(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$');

  /// Validate a GCP project ID format
  static bool isValidProjectId(String projectId) {
    return _projectIdRegex.hasMatch(projectId);
  }

  /// Save list of selected project IDs
  Future<void> saveSelectedProjects(List<String> projectIds) async {
    // Filter to only valid project IDs (security)
    final validIds = projectIds.where(isValidProjectId).toList();
    // Enforce maximum limit
    final limitedIds = validIds.take(maxSelectedProjects).toList();
    await _sharedPrefs.setStringList('selected_project_ids', limitedIds);
  }

  /// Get list of selected project IDs
  List<String> getSelectedProjects() {
    final saved = _sharedPrefs.getStringList('selected_project_ids') ?? [];
    // Filter to only valid project IDs (sanitization on load)
    return saved.where(isValidProjectId).toList();
  }

  /// Clear all selected projects
  Future<void> clearSelectedProjects() async {
    await _sharedPrefs.remove('selected_project_ids');
  }

  /// Migrate from legacy single project to multi-project (called once)
  Future<void> migrateToMultiProject() async {
    final legacy = getLastProject();
    if (legacy != null && isValidProjectId(legacy)) {
      final current = getSelectedProjects();
      if (!current.contains(legacy)) {
        await saveSelectedProjects([...current, legacy]);
      }
    }
  }

  // --- Multi-Account Support (Sprint 8) ---

  /// Save account-to-projects mapping
  Future<void> saveAccountProjects(Map<String, List<String>> accountProjects) async {
    // Serialize as: account1=proj1,proj2;account2=proj3,proj4
    final entries = accountProjects.entries.map((e) {
      final projects = e.value.where(isValidProjectId).join(',');
      return '${Uri.encodeComponent(e.key)}=$projects';
    }).join(';');
    await _sharedPrefs.setString('account_project_map', entries);
  }

  /// Get account-to-projects mapping
  Map<String, List<String>> getAccountProjects() {
    final stored = _sharedPrefs.getString('account_project_map');
    if (stored == null || stored.isEmpty) return {};

    final result = <String, List<String>>{};
    for (final entry in stored.split(';')) {
      final idx = entry.indexOf('=');
      if (idx > 0) {
        final account = Uri.decodeComponent(entry.substring(0, idx));
        final projects = entry.substring(idx + 1)
            .split(',')
            .where((p) => p.isNotEmpty && isValidProjectId(p))
            .toList();
        result[account] = projects;
      }
    }
    return result;
  }

  /// Migrate existing projects to account mapping (called once on upgrade)
  /// Assigns all existing selected projects to the provided active account
  Future<void> migrateProjectsToAccount(String activeAccountEmail) async {
    final existing = getAccountProjects();
    if (existing.isNotEmpty) return; // Already migrated

    final projects = getSelectedProjects();
    if (projects.isEmpty) return; // Nothing to migrate

    await saveAccountProjects({activeAccountEmail: projects});
  }

  // --- Secure Credentials (FlutterSecureStorage) ---

  // Key format: "rdp_creds_<instance_name>" -> JSON or separate keys?
  // Let's use separate keys for simplicity: "rdp_user_<instance>" and "rdp_pass_<instance>"
  // We can also store "rdp_domain_<instance>"

  Future<void> saveRdpCredentials({
    required String instanceName,
    required String username,
    required String password,
    String? domain,
  }) async {
    await _secureStorage.write(key: 'rdp_user_$instanceName', value: username);
    await _secureStorage.write(key: 'rdp_pass_$instanceName', value: password);
    if (domain != null && domain.isNotEmpty) {
      await _secureStorage.write(key: 'rdp_domain_$instanceName', value: domain);
    } else {
      await _secureStorage.delete(key: 'rdp_domain_$instanceName');
    }
  }

  Future<Map<String, String?>> getRdpCredentials(String instanceName) async {
    final user = await _secureStorage.read(key: 'rdp_user_$instanceName');
    final pass = await _secureStorage.read(key: 'rdp_pass_$instanceName');
    final domain = await _secureStorage.read(key: 'rdp_domain_$instanceName');
    
    return {
      'username': user,
      'password': pass,
      'domain': domain,
    };
  }

  Future<void> clearRdpCredentials(String instanceName) async {
    await _secureStorage.delete(key: 'rdp_user_$instanceName');
    await _secureStorage.delete(key: 'rdp_pass_$instanceName');
    await _secureStorage.delete(key: 'rdp_domain_$instanceName');
  }

  // --- Manual Instances (when user has get but not list permission) ---

  /// Save list of manually added instances
  Future<void> saveManualInstances(List<Map<String, dynamic>> instances) async {
    final jsonStrings = instances.map((i) => _mapToString(i)).toList();
    await _sharedPrefs.setStringList('manual_instances', jsonStrings);
  }

  /// Get list of manually added instances
  Future<List<Map<String, dynamic>>> getManualInstances() async {
    final stored = _sharedPrefs.getStringList('manual_instances') ?? [];
    return stored.map((s) => _stringToMap(s)).toList();
  }

  /// Clear all manual instances
  Future<void> clearManualInstances() async {
    await _sharedPrefs.remove('manual_instances');
  }

  /// Clear all session data (called on logout)
  /// This removes temporary cached data but preserves user preferences
  /// IMPORTANT: selected_project_ids and manual_instances are user preferences, NOT session data
  /// They should persist across logout/login cycles
  Future<void> clearSessionData() async {
    await _sharedPrefs.remove('last_project_id');
    // Do NOT remove selected_project_ids - it's a user preference
    // Do NOT remove manual_instances - it's a user preference
    // Do NOT remove api_method - it's a user preference
  }

  // Simple JSON encoding/decoding helpers
  String _mapToString(Map<String, dynamic> map) {
    final parts = <String>[];
    for (final entry in map.entries) {
      final value = entry.value?.toString() ?? '';
      parts.add('${entry.key}=${Uri.encodeComponent(value)}');
    }
    return parts.join('&');
  }

  Map<String, dynamic> _stringToMap(String str) {
    final map = <String, dynamic>{};
    for (final part in str.split('&')) {
      final idx = part.indexOf('=');
      if (idx > 0) {
        final key = part.substring(0, idx);
        final value = Uri.decodeComponent(part.substring(idx + 1));
        // Try to parse as int if possible
        final intValue = int.tryParse(value);
        map[key] = intValue ?? value;
      }
    }
    return map;
  }
}
