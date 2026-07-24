/// Windows Credentials Dialog - Sprint 5
///
/// UI for generating and managing Windows VM credentials.
/// Provides two tabs:
/// 1. Generate Password - Generate new or reset existing password
/// 2. Stored Credentials - View and manage stored credentials

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../bridge/api.dart/windows_credentials/storage.dart';
import 'windows_credentials_provider.dart';

/// Show the Windows credentials dialog
void showWindowsCredentialsDialog(
  BuildContext context, {
  required WidgetRef ref,
  required String projectId,
  required String zone,
  required String instanceName,
}) {
  showDialog(
    context: context,
    builder: (context) => WindowsCredentialsDialog(
      projectId: projectId,
      zone: zone,
      instanceName: instanceName,
    ),
  );
}

class WindowsCredentialsDialog extends ConsumerStatefulWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const WindowsCredentialsDialog({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  ConsumerState<WindowsCredentialsDialog> createState() =>
      _WindowsCredentialsDialogState();
}

class _WindowsCredentialsDialogState
    extends ConsumerState<WindowsCredentialsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();

  WindowsCredential? _generatedCredential;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    // Try to get the user's email from gcloud and set username
    _loadUserInfo();

    // Check if there's an existing credential for this instance
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final existingCredential = ref.read(instanceCredentialProvider((
        projectId: widget.projectId,
        zone: widget.zone,
        instanceName: widget.instanceName,
      )));
      if (existingCredential != null) {
        setState(() {
          _generatedCredential = existingCredential;
          _usernameController.text = existingCredential.username;
        });
      }
    });
  }

  Future<void> _loadUserInfo() async {
    try {
      // Get the GCP account email (e.g., jordi.lopezreyes@emeal.nttdata.com)
      final email = await getGcloudAccountEmail();
      if (mounted) {
        _emailController.text = email;

        // Extract username from email (part before @) and use underscores instead of dots
        // e.g., jordi.lopezreyes@emeal.nttdata.com -> jordi_lopezreyes
        final userPart = email.split('@').first;
        // Replace dots with underscores for Windows compatibility
        _usernameController.text = userPart.replaceAll('.', '_');
      }
    } catch (_) {
      // Fallback to Administrator if GCP account cannot be retrieved
      _emailController.text = '';
      _usernameController.text = 'Administrator';
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(windowsCredentialsProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Dialog(
      child: Container(
        width: 600,
        height: 550,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.vpn_key,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.winCredTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        widget.instanceName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
            const SizedBox(height: 16),

            // Tab bar
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: l10n.winCredGeneratePasswordTab),
                Tab(text: l10n.winCredStoredCredentialsTab),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildGenerateTab(state, theme, l10n),
                  _buildStoredTab(state, theme, l10n),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenerateTab(
      WindowsCredentialsState state, ThemeData theme, AppLocalizations l10n) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Info box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.primary.withAlpha(50),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.winCredInfoBox,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Username field
          TextField(
            controller: _usernameController,
            decoration: InputDecoration(
              labelText: l10n.commonUsernameLabel,
              hintText: l10n.winCredUsernameHint,
              prefixIcon: const Icon(Icons.person),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          // Email field
          TextField(
            controller: _emailController,
            decoration: InputDecoration(
              labelText: l10n.winCredEmailLabel,
              hintText: l10n.winCredEmailHint,
              prefixIcon: const Icon(Icons.email),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: state.isLoading ? null : _generatePassword,
                  icon: state.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                  label: Text(l10n.winCredGenerateNew),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: state.isLoading ||
                          _generatedCredential == null
                      ? null
                      : _resetPassword,
                  icon: state.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(l10n.winCredResetPassword),
                ),
              ),
            ],
          ),

          // Loading indicator
          if (state.isLoading) ...[
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(l10n.winCredWaitingForAgent),
                  const SizedBox(height: 4),
                  Text(
                    l10n.winCredMayTake60s,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],

          // Error message
          if (state.error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(state.error!)),
                ],
              ),
            ),
          ],

          // Generated credential display
          if (_generatedCredential != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              l10n.winCredGeneratedCredential,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _buildCredentialCard(_generatedCredential!, theme, l10n),
          ],
        ],
      ),
    );
  }

  Widget _buildStoredTab(
      WindowsCredentialsState state, ThemeData theme, AppLocalizations l10n) {
    if (state.credentials.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.vpn_key_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(100),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.winCredNoStoredCredentials,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.winCredNoStoredCredentialsHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Clear all button
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: state.isLoading ? null : _confirmClearAll,
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: Text(l10n.winCredClearAll),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ),
        // Credentials list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: state.credentials.length,
            itemBuilder: (context, index) {
              final credential = state.credentials[index];
              return _buildCredentialListTile(credential, theme, l10n);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCredentialCard(
      WindowsCredential credential, ThemeData theme, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withAlpha(50),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Username
          Row(
            children: [
              const Icon(Icons.person, size: 18),
              const SizedBox(width: 8),
              Text(l10n.winCredUsernameField, style: theme.textTheme.bodySmall),
              Expanded(
                child: SelectableText(
                  credential.username,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => _copyToClipboard(
                    credential.username, l10n.commonUsernameLabel, l10n),
                tooltip: l10n.winCredCopyUsernameTooltip,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Password
          Row(
            children: [
              const Icon(Icons.key, size: 18),
              const SizedBox(width: 8),
              Text(l10n.winCredPasswordField, style: theme.textTheme.bodySmall),
              Expanded(
                child: SelectableText(
                  _passwordVisible ? credential.password : '*' * 16,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  _passwordVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
                tooltip: _passwordVisible
                    ? l10n.winCredHidePassword
                    : l10n.winCredShowPassword,
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => _copyToClipboard(
                    credential.password, l10n.winCredPasswordWord, l10n,
                    isSensitive: true),
                tooltip: l10n.winCredCopyPasswordTooltip,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCredentialListTile(
      WindowsCredential credential, ThemeData theme, AppLocalizations l10n) {
    final isCurrentInstance = credential.projectId == widget.projectId &&
        credential.zone == widget.zone &&
        credential.instanceName == widget.instanceName;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isCurrentInstance
          ? theme.colorScheme.primaryContainer.withAlpha(50)
          : null,
      child: ExpansionTile(
        leading: Icon(
          Icons.computer,
          color: isCurrentInstance
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          credential.instanceName,
          style: TextStyle(
            fontWeight: isCurrentInstance ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          '${credential.username} @ ${credential.projectId}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: isCurrentInstance
            ? Chip(
                label: Text(l10n.commonCurrentChip),
                labelStyle: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.primary,
                ),
                backgroundColor: theme.colorScheme.primaryContainer,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCredentialCard(credential, theme, l10n),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _deleteCredential(credential),
                      icon: const Icon(Icons.delete, size: 18),
                      label: Text(l10n.commonDelete),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generatePassword() async {
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();

    if (username.isEmpty) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.commonPleaseEnterUsername)),
      );
      return;
    }

    ref.read(windowsCredentialsProvider.notifier).clearMessages();

    final credential = await ref.read(windowsCredentialsProvider.notifier).generatePassword(
      projectId: widget.projectId,
      zone: widget.zone,
      instanceName: widget.instanceName,
      username: username,
      email: email,
    );

    if (credential != null && mounted) {
      setState(() {
        _generatedCredential = credential;
      });
    }
  }

  Future<void> _resetPassword() async {
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();

    ref.read(windowsCredentialsProvider.notifier).clearMessages();

    final credential = await ref.read(windowsCredentialsProvider.notifier).resetPassword(
      projectId: widget.projectId,
      zone: widget.zone,
      instanceName: widget.instanceName,
      username: username,
      email: email,
    );

    if (credential != null && mounted) {
      setState(() {
        _generatedCredential = credential;
      });
    }
  }

  Future<void> _copyToClipboard(
      String text, String label, AppLocalizations l10n,
      {bool isSensitive = false}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isSensitive
              ? l10n.winCredCopiedToClipboardSensitive(label)
              : l10n.winCredCopiedToClipboard(label)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    if (isSensitive) {
      await Future.delayed(const Duration(seconds: 30));
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  Future<void> _deleteCredential(WindowsCredential credential) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.winCredDeleteCredentialTitle),
        content: Text(
          l10n.winCredDeleteCredentialConfirm(
              credential.username, credential.instanceName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(windowsCredentialsProvider.notifier).deleteCredential(
        projectId: credential.projectId,
        zone: credential.zone,
        instanceName: credential.instanceName,
      );

      if (credential.projectId == widget.projectId &&
          credential.zone == widget.zone &&
          credential.instanceName == widget.instanceName) {
        setState(() {
          _generatedCredential = null;
        });
      }
    }
  }

  Future<void> _confirmClearAll() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.winCredClearAllTitle),
        content: Text(l10n.winCredClearAllConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.winCredClearAll),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(windowsCredentialsProvider.notifier).clearAll();
      setState(() {
        _generatedCredential = null;
      });
    }
  }
}
