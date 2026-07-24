import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/db_client.dart';
import 'database_profiles_provider.dart';
import 'gcloud_provider.dart';

/// Show the database connection panel dialog
void showDatabaseConnectionPanel(
  BuildContext context, {
  required String projectId,
  required String zone,
  required String instanceName,
}) {
  showDialog(
    context: context,
    builder: (context) => DatabaseConnectionPanel(
      projectId: projectId,
      zone: zone,
      instanceName: instanceName,
    ),
  );
}

/// Database connection panel with tabbed interface
class DatabaseConnectionPanel extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const DatabaseConnectionPanel({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<DatabaseConnectionPanel> createState() => _DatabaseConnectionPanelState();
}

class _DatabaseConnectionPanelState extends ConsumerState<DatabaseConnectionPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      child: Container(
        width: 700,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.storage, color: Colors.purple.shade700, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.dbConnectionTitle,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        widget.instanceName,
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
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

            // Tabs
            TabBar(
              controller: _tabController,
              labelColor: Colors.purple.shade700,
              tabs: [
                Tab(text: l10n.dbTabNewConnection),
                Tab(text: l10n.dbTabSavedProfiles),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _NewConnectionTab(
                    projectId: widget.projectId,
                    zone: widget.zone,
                    instanceName: widget.instanceName,
                  ),
                  _SavedProfilesTab(
                    projectId: widget.projectId,
                    zone: widget.zone,
                    instanceName: widget.instanceName,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// NEW CONNECTION TAB
// ==========================================

class _NewConnectionTab extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const _NewConnectionTab({
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<_NewConnectionTab> createState() => _NewConnectionTabState();
}

class _NewConnectionTabState extends ConsumerState<_NewConnectionTab> {
  DatabaseType _selectedDbType = DatabaseType.mySql;
  DbClientType? _selectedClient;
  final _portController = TextEditingController();
  final _databaseController = TextEditingController();
  final _usernameController = TextEditingController();
  final _profileNameController = TextEditingController();
  bool _isConnecting = false;
  bool _useCustomPort = false;

  @override
  void initState() {
    super.initState();
    _updateDefaultPort();
  }

  @override
  void dispose() {
    _portController.dispose();
    _databaseController.dispose();
    _usernameController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  void _updateDefaultPort() {
    final defaultPort = DbConnectionProfile.getDefaultPort(_selectedDbType);
    _portController.text = defaultPort.toString();
  }

  Future<void> _connect() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _isConnecting = true);

    try {
      final port = int.tryParse(_portController.text) ??
          DbConnectionProfile.getDefaultPort(_selectedDbType);

      // First, create the IAP tunnel
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.dbCreatingTunnel(port))),
      );

      final localPort = await ref.read(activeConnectionsProvider.notifier).connect(
        widget.projectId,
        widget.zone,
        widget.instanceName,
        remotePort: port,
      );

      if (localPort == null) {
        throw Exception(l10n.dbTunnelCreationFailed);
      }

      // Launch the database client
      final settings = DbConnectionSettings(
        databaseType: _selectedDbType,
        host: '127.0.0.1',
        port: localPort,
        databaseName: _databaseController.text.isNotEmpty ? _databaseController.text : null,
        username: _usernameController.text.isNotEmpty ? _usernameController.text : null,
        instanceName: widget.instanceName,
        clientType: _selectedClient,
      );

      final result = await launchDb(settings: settings);

      if (mounted) {
        final clientName = DbConnectionProfile.getClientTypeName(result.clientUsed);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.fallbackOccurred
                  ? l10n.dbLaunchedFallback(clientName)
                  : l10n.dbLaunched(clientName),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.dbConnectionFailed(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  Future<void> _saveProfile() async {
    final l10n = AppLocalizations.of(context);
    final name = _profileNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.dbEnterProfileName),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final profile = DbConnectionProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      databaseType: _selectedDbType,
      remotePort: int.tryParse(_portController.text) ??
          DbConnectionProfile.getDefaultPort(_selectedDbType),
      databaseName: _databaseController.text.isNotEmpty ? _databaseController.text : null,
      username: _usernameController.text.isNotEmpty ? _usernameController.text : null,
      preferredClient: _selectedClient,
      createdAt: DateTime.now(),
      lastUsed: DateTime.now(),
    );

    await ref.read(dbProfilesProvider.notifier).addProfile(profile);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.dbProfileSaved(name)),
          backgroundColor: Colors.green,
        ),
      );
      _profileNameController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final availableClients = ref.watch(availableClientsForDbProvider(_selectedDbType));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Database type selection
          Text(
            l10n.dbTypeLabel,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: DatabaseType.values.map((type) {
              final isSelected = type == _selectedDbType;
              return ChoiceChip(
                label: Text(DbConnectionProfile.getDatabaseTypeName(type)),
                selected: isSelected,
                selectedColor: Colors.purple.shade100,
                onSelected: (selected) {
                  if (selected) {
                    setState(() {
                      _selectedDbType = type;
                      _selectedClient = null;
                      _updateDefaultPort();
                    });
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 24),

          // Port configuration
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.dbRemotePortLabel,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Checkbox(
                          value: _useCustomPort,
                          onChanged: (value) {
                            setState(() {
                              _useCustomPort = value ?? false;
                              if (!_useCustomPort) {
                                _updateDefaultPort();
                              }
                            });
                          },
                        ),
                        Text(l10n.dbCustomPort),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _portController,
                            enabled: _useCustomPort,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              isDense: true,
                              border: const OutlineInputBorder(),
                              hintText: DbConnectionProfile.getDefaultPort(_selectedDbType).toString(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Database name (optional)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _databaseController,
                  decoration: InputDecoration(
                    labelText: l10n.dbDatabaseNameOptional,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: l10n.dbUsernameOptional,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // SQL Client selection
          Text(
            l10n.dbSqlClientLabel,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          availableClients.when(
            data: (clients) {
              if (clients.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, color: Colors.orange.shade700),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.dbNoCompatibleClients(
                            DbConnectionProfile.getDatabaseTypeName(_selectedDbType),
                          ),
                          style: TextStyle(color: Colors.orange.shade900),
                        ),
                      ),
                    ],
                  ),
                );
              }

              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Auto-detect option
                  ChoiceChip(
                    label: Text(l10n.dbAutoClient),
                    selected: _selectedClient == null,
                    selectedColor: Colors.purple.shade100,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedClient = null);
                      }
                    },
                  ),
                  ...clients.map((client) {
                    final isSelected = client == _selectedClient;
                    return ChoiceChip(
                      label: Text(DbConnectionProfile.getClientTypeName(client)),
                      selected: isSelected,
                      selectedColor: Colors.purple.shade100,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _selectedClient = client);
                        }
                      },
                    );
                  }),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text(l10n.dbErrorLoadingClients(e.toString())),
          ),
          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isConnecting ? null : _connect,
                  icon: _isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(_isConnecting ? l10n.dbConnecting : l10n.dbConnectAndLaunch),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Save profile section
          const Divider(),
          const SizedBox(height: 16),
          Text(
            l10n.dbSaveAsProfileLabel,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _profileNameController,
                  decoration: InputDecoration(
                    labelText: l10n.dbProfileNameLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: l10n.dbProfileNameHint,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _saveProfile,
                icon: const Icon(Icons.save),
                label: Text(l10n.commonSave),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ==========================================
// SAVED PROFILES TAB
// ==========================================

class _SavedProfilesTab extends ConsumerWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const _SavedProfilesTab({
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profiles = ref.watch(dbProfilesProvider);

    if (profiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bookmark_border, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              l10n.dbNoSavedProfiles,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.dbNoSavedProfilesHint,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: profiles.length,
      itemBuilder: (context, index) {
        final profile = profiles[index];
        return _ProfileCard(
          profile: profile,
          projectId: projectId,
          zone: zone,
          instanceName: instanceName,
        );
      },
    );
  }
}

class _ProfileCard extends ConsumerStatefulWidget {
  final DbConnectionProfile profile;
  final String projectId;
  final String zone;
  final String instanceName;

  const _ProfileCard({
    required this.profile,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends ConsumerState<_ProfileCard> {
  bool _isConnecting = false;

  Future<void> _quickConnect() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _isConnecting = true);

    try {
      // Mark profile as used
      await ref.read(dbProfilesProvider.notifier).markUsed(widget.profile.id);

      // Create the IAP tunnel
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.dbCreatingTunnel(widget.profile.remotePort))),
      );

      final localPort = await ref.read(activeConnectionsProvider.notifier).connect(
        widget.projectId,
        widget.zone,
        widget.instanceName,
        remotePort: widget.profile.remotePort,
      );

      if (localPort == null) {
        throw Exception(l10n.dbTunnelCreationFailed);
      }

      // Launch the database client
      final settings = DbConnectionSettings(
        databaseType: widget.profile.databaseType,
        host: '127.0.0.1',
        port: localPort,
        databaseName: widget.profile.databaseName,
        username: widget.profile.username,
        instanceName: widget.instanceName,
        clientType: widget.profile.preferredClient,
      );

      final result = await launchDb(settings: settings);

      if (mounted) {
        final clientName = DbConnectionProfile.getClientTypeName(result.clientUsed);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.dbLaunched(clientName)),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.dbConnectionFailed(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  Future<void> _deleteProfile() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.dbDeleteProfileTitle),
        content: Text(l10n.dbDeleteProfileConfirm(widget.profile.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(dbProfilesProvider.notifier).removeProfile(widget.profile.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dbTypeName = DbConnectionProfile.getDatabaseTypeName(widget.profile.databaseType);
    final clientName = widget.profile.preferredClient != null
        ? DbConnectionProfile.getClientTypeName(widget.profile.preferredClient!)
        : l10n.dbAutoClient;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.purple.shade100,
          child: Icon(
            _getDbIcon(widget.profile.databaseType),
            color: Colors.purple.shade700,
          ),
        ),
        title: Text(
          widget.profile.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.dbTypePortLabel(dbTypeName, widget.profile.remotePort)),
            if (widget.profile.databaseName != null)
              Text(l10n.dbDatabaseLabel(widget.profile.databaseName!)),
            Text(
              l10n.dbClientLabel(clientName),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: Colors.red.shade400,
              onPressed: _deleteProfile,
              tooltip: l10n.dbDeleteProfileTooltip,
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _isConnecting ? null : _quickConnect,
              icon: _isConnecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(_isConnecting ? '...' : l10n.commonConnect),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getDbIcon(DatabaseType type) {
    switch (type) {
      case DatabaseType.mySql:
        return Icons.storage;
      case DatabaseType.postgreSql:
        return Icons.dns;
      case DatabaseType.sqlServer:
        return Icons.business;
      case DatabaseType.redis:
        return Icons.memory;
      case DatabaseType.mongoDb:
        return Icons.cloud;
    }
  }
}
