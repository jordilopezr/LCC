import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/gcloud.dart';
import '../bridge/api.dart/gcp_rest_client.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

/// Dialog to manually add an instance by project, zone, and name.
/// First tries REST API, then falls back to gcloud CLI.
class ManualInstanceDialog extends ConsumerStatefulWidget {
  const ManualInstanceDialog({super.key});

  @override
  ConsumerState<ManualInstanceDialog> createState() => _ManualInstanceDialogState();
}

class _ManualInstanceDialogState extends ConsumerState<ManualInstanceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _projectController = TextEditingController();
  final _zoneController = TextEditingController();
  final _instanceController = TextEditingController();

  bool _isLoading = false;
  String? _error;
  GcpInstanceClientLib? _foundInstance;
  String _usedMethod = '';

  // Common GCP zones for autocomplete
  static const _commonZones = [
    'us-central1-a', 'us-central1-b', 'us-central1-c', 'us-central1-f',
    'us-east1-b', 'us-east1-c', 'us-east1-d',
    'us-west1-a', 'us-west1-b', 'us-west1-c',
    'europe-west1-b', 'europe-west1-c', 'europe-west1-d',
    'europe-west2-a', 'europe-west2-b', 'europe-west2-c',
    'asia-east1-a', 'asia-east1-b', 'asia-east1-c',
    'southamerica-east1-a', 'southamerica-east1-b', 'southamerica-east1-c',
    'southamerica-west1-a', 'southamerica-west1-b', 'southamerica-west1-c',
  ];

  @override
  void dispose() {
    _projectController.dispose();
    _zoneController.dispose();
    _instanceController.dispose();
    super.dispose();
  }

  Future<void> _searchInstance() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _foundInstance = null;
      _usedMethod = '';
    });

    final projectId = _projectController.text.trim();
    final zone = _zoneController.text.trim();
    final instanceName = _instanceController.text.trim();

    // First try REST API (Client Libraries)
    try {
      final instance = await getInstanceClientLib(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
      );

      setState(() {
        _foundInstance = instance;
        _usedMethod = 'REST API';
        _isLoading = false;
      });
      return;
    } catch (e) {
      // REST API failed, try gcloud CLI as fallback
      debugPrint('REST API failed: $e, trying gcloud CLI...');
    }

    // Fallback to gcloud CLI
    try {
      final gcloudInstance = await getInstanceGcloud(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
      );

      // Convert GcpInstance to GcpInstanceClientLib for consistency
      setState(() {
        _foundInstance = GcpInstanceClientLib(
          name: gcloudInstance.name,
          status: gcloudInstance.status,
          zone: gcloudInstance.zone,
          machineType: gcloudInstance.machineType,
          cpuCount: gcloudInstance.cpuCount,
          memoryMb: gcloudInstance.memoryMb,
          diskGb: gcloudInstance.diskGb,
          labels: const [],
          osLoginEnabled: false,
          isWindows: false,
        );
        _usedMethod = 'gcloud CLI';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('AnyhowException(', '').replaceAll(')', '');
        _isLoading = false;
      });
    }
  }

  void _addInstance() {
    if (_foundInstance != null) {
      Navigator.of(context).pop(ManualInstanceResult(
        projectId: _projectController.text.trim(),
        instance: _foundInstance!,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.add_circle_outline, color: Colors.blue.shade700),
          const SizedBox(width: 8),
          Text(l10n.manualInstanceTitle),
        ],
      ),
      content: SizedBox(
        width: 450,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.manualInstanceDescription,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),

              // Project ID
              TextFormField(
                controller: _projectController,
                decoration: InputDecoration(
                  labelText: l10n.manualInstanceProjectIdLabel,
                  hintText: l10n.manualInstanceProjectIdHint,
                  prefixIcon: const Icon(Icons.folder),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return l10n.manualInstanceProjectIdRequired;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Zone with autocomplete
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  if (textEditingValue.text.isEmpty) {
                    return _commonZones;
                  }
                  return _commonZones.where((zone) =>
                    zone.toLowerCase().contains(textEditingValue.text.toLowerCase())
                  );
                },
                onSelected: (String selection) {
                  _zoneController.text = selection;
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  // Sync controllers
                  controller.text = _zoneController.text;
                  controller.addListener(() {
                    _zoneController.text = controller.text;
                  });

                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: l10n.manualInstanceZoneLabel,
                      hintText: l10n.manualInstanceZoneHint,
                      prefixIcon: const Icon(Icons.location_on),
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.manualInstanceZoneRequired;
                      }
                      return null;
                    },
                  );
                },
              ),
              const SizedBox(height: 16),

              // Instance Name
              TextFormField(
                controller: _instanceController,
                decoration: InputDecoration(
                  labelText: l10n.manualInstanceNameLabel,
                  hintText: l10n.manualInstanceNameHint,
                  prefixIcon: const Icon(Icons.computer),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return l10n.manualInstanceNameRequired;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Search button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _searchInstance,
                  icon: _isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                  label: Text(_isLoading ? l10n.manualInstanceSearching : l10n.manualInstanceSearchButton),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),

              // Error message
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Found instance
              if (_foundInstance != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.check_circle, color: Colors.green.shade700, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            l10n.manualInstanceFoundTitle,
                            style: TextStyle(
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (_usedMethod.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                l10n.manualInstanceViaMethod(_usedMethod),
                                style: TextStyle(fontSize: 10, color: Colors.green.shade700),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildInfoRow(l10n.manualInstanceFieldName, _foundInstance!.name),
                      _buildInfoRow(l10n.manualInstanceFieldStatus, _foundInstance!.status),
                      _buildInfoRow(l10n.manualInstanceZoneLabel, _foundInstance!.zone),
                      _buildInfoRow(l10n.manualInstanceFieldMachineType, _foundInstance!.machineType),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        if (_foundInstance != null)
          ElevatedButton.icon(
            onPressed: _addInstance,
            icon: const Icon(Icons.add),
            label: Text(l10n.manualInstanceAddButton),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Result returned when an instance is added manually
class ManualInstanceResult {
  final String projectId;
  final GcpInstanceClientLib instance;

  ManualInstanceResult({
    required this.projectId,
    required this.instance,
  });
}

/// Show the manual instance dialog
Future<ManualInstanceResult?> showManualInstanceDialog(BuildContext context) {
  return showDialog<ManualInstanceResult>(
    context: context,
    builder: (context) => const ManualInstanceDialog(),
  );
}
