// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Lightweight Cloud Connector';

  @override
  String get settingsLanguageTitle => 'Language';

  @override
  String get settingsLanguageSystem => 'System default';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonClose => 'Close';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonRemove => 'Remove';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonError => 'Error';

  @override
  String get commonWarning => 'Warning';

  @override
  String get commonOk => 'OK';

  @override
  String get commonYes => 'Yes';

  @override
  String get commonNo => 'No';

  @override
  String get commonConnect => 'Connect';

  @override
  String get commonDisconnect => 'Disconnect';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonNever => 'Never';

  @override
  String get accountManageTitle => 'Manage Accounts';

  @override
  String get accountActiveTunnelsWarning =>
      'Active tunnels will be disconnected when switching accounts.';

  @override
  String get accountNoneFound => 'No authenticated accounts found.';

  @override
  String get accountActiveBadge => 'ACTIVE';

  @override
  String get accountSwitchButton => 'Switch';

  @override
  String accountSwitchedTo(String account) {
    return 'Switched to $account';
  }

  @override
  String get accountRemoveTooltip => 'Remove account';

  @override
  String get accountAddButton => 'Add Account';

  @override
  String get accountRemoveTitle => 'Remove Account';

  @override
  String accountRemoveConfirm(String email) {
    return 'Revoke credentials for $email?';
  }

  @override
  String get accountActiveAccountWarning =>
      'This is the active account. All tunnels will be disconnected.';

  @override
  String get commonGcpErrorPermissionDenied =>
      'Access denied. Check your GCP permissions.';

  @override
  String get commonGcpErrorNotFound => 'Resource not found.';

  @override
  String get commonGcpErrorUnauthenticated =>
      'Authentication required. Please re-login.';

  @override
  String get commonGcpErrorQuotaExceeded => 'GCP quota exceeded.';

  @override
  String get commonGcpErrorNetwork => 'Network error. Check your connection.';

  @override
  String get commonGcpErrorUnknown =>
      'An error occurred. Please check your configuration.';

  @override
  String accountRemovedSnackbar(String email) {
    return 'Account $email removed';
  }

  @override
  String get tunnelManagerTitle => 'Tunnel Manager';

  @override
  String tunnelTotalCount(int count) {
    return '$count Total';
  }

  @override
  String tunnelHealthyCount(int count) {
    return '$count Healthy';
  }

  @override
  String tunnelErrorCount(int count) {
    return '$count Error';
  }

  @override
  String tunnelReconnectingCount(int count) {
    return '$count Reconnecting';
  }

  @override
  String get tunnelNoActiveTunnels => 'No active tunnels';

  @override
  String get tunnelConnectPrompt => 'Connect to an instance to create a tunnel';

  @override
  String get tunnelDisconnectAll => 'Disconnect All';

  @override
  String get tunnelDisconnectAllTitle => 'Disconnect All Tunnels?';

  @override
  String tunnelDisconnectAllConfirm(int count) {
    return 'This will close all $count active tunnel(s).';
  }

  @override
  String get tunnelCleanupZombies => 'Cleanup Zombies';

  @override
  String get tunnelNoZombiesFound => 'No zombie tunnels found';

  @override
  String tunnelCleanedUpZombies(int count) {
    return 'Cleaned up $count zombie tunnel(s)';
  }

  @override
  String tunnelCleanupFailed(String error) {
    return 'Cleanup failed: $error';
  }

  @override
  String get tunnelStatusReconnecting => 'Reconnecting';

  @override
  String get tunnelStatusHealthy => 'Healthy';

  @override
  String get tunnelAutoReconnect => 'Auto-reconnect';

  @override
  String get tunnelRetryNow => 'Retry Now';

  @override
  String get doctorTitle => 'Connectivity Doctor';

  @override
  String get doctorRunAgain => 'Run Again';

  @override
  String get doctorRunning => 'Running…';

  @override
  String get doctorExportReport => 'Export Report';

  @override
  String doctorReportExported(String path) {
    return 'Report exported to: $path';
  }

  @override
  String get doctorCopyPath => 'Copy Path';

  @override
  String doctorExportFailed(String error) {
    return 'Failed to export report: $error';
  }

  @override
  String get doctorConfirmFixTitle => 'Confirm Fix Action';

  @override
  String doctorConfirmStartVm(String instanceName) {
    return 'Start the VM instance \"$instanceName\"?';
  }

  @override
  String get doctorConfirmReauthenticate =>
      'Re-authenticate with gcloud? This will open a browser window.';

  @override
  String doctorConfirmExecuteFix(String fixActionId) {
    return 'Execute fix action \"$fixActionId\"?';
  }

  @override
  String get doctorExecute => 'Execute';

  @override
  String doctorFixFailed(String error) {
    return 'Fix failed: $error';
  }

  @override
  String get doctorRunningChecks => 'Running connectivity checks…';

  @override
  String commonErrorPrefix(String error) {
    return 'Error: $error';
  }

  @override
  String get doctorNoResultsYet => 'No results yet';

  @override
  String get doctorCommandCopied => 'Command copied to clipboard';

  @override
  String get doctorCategoryAuthentication => 'Authentication';

  @override
  String get doctorCategoryProjectPermissions => 'Project & Permissions';

  @override
  String get doctorCategoryIapNetwork => 'IAP & Network';

  @override
  String get doctorCategoryVmStatus => 'VM Status';

  @override
  String get doctorCategoryLocalEnvironment => 'Local Environment';

  @override
  String doctorTotalDuration(int ms) {
    return 'Total: ${ms}ms';
  }

  @override
  String get doctorCopyCommand => 'Copy Command';

  @override
  String get doctorFix => 'Fix';

  @override
  String get dbConnectionTitle => 'Database Connection';

  @override
  String get dbTabNewConnection => 'New Connection';

  @override
  String get dbTabSavedProfiles => 'Saved Profiles';

  @override
  String dbCreatingTunnel(int port) {
    return 'Creating tunnel to port $port…';
  }

  @override
  String get dbTunnelCreationFailed => 'Failed to create tunnel';

  @override
  String dbLaunched(String clientName) {
    return 'Launched $clientName';
  }

  @override
  String dbLaunchedFallback(String clientName) {
    return 'Launched $clientName (fallback)';
  }

  @override
  String dbConnectionFailed(String error) {
    return 'Connection failed: $error';
  }

  @override
  String get dbEnterProfileName => 'Please enter a profile name';

  @override
  String dbProfileSaved(String name) {
    return 'Profile \"$name\" saved';
  }

  @override
  String get dbTypeLabel => 'Database Type';

  @override
  String get dbRemotePortLabel => 'Remote Port';

  @override
  String get dbCustomPort => 'Custom port';

  @override
  String get dbDatabaseNameOptional => 'Database Name (optional)';

  @override
  String get dbUsernameOptional => 'Username (optional)';

  @override
  String get dbSqlClientLabel => 'SQL Client';

  @override
  String dbNoCompatibleClients(String dbType) {
    return 'No compatible clients found for $dbType.\nPlease install one of the supported clients.';
  }

  @override
  String get dbAutoClient => 'Auto';

  @override
  String dbErrorLoadingClients(String error) {
    return 'Error loading clients: $error';
  }

  @override
  String get dbConnecting => 'Connecting…';

  @override
  String get dbConnectAndLaunch => 'Connect & Launch';

  @override
  String get dbSaveAsProfileLabel => 'Save as Profile';

  @override
  String get dbProfileNameLabel => 'Profile Name';

  @override
  String get dbProfileNameHint => 'e.g., Production MySQL';

  @override
  String get dbNoSavedProfiles => 'No saved profiles';

  @override
  String get dbNoSavedProfilesHint =>
      'Create a connection and save it as a profile for quick access';

  @override
  String get dbDeleteProfileTitle => 'Delete Profile';

  @override
  String dbDeleteProfileConfirm(String name) {
    return 'Are you sure you want to delete \"$name\"?';
  }

  @override
  String dbTypePortLabel(String dbType, int port) {
    return '$dbType (Port $port)';
  }

  @override
  String dbDatabaseLabel(String name) {
    return 'Database: $name';
  }

  @override
  String dbClientLabel(String clientName) {
    return 'Client: $clientName';
  }

  @override
  String get dbDeleteProfileTooltip => 'Delete profile';

  @override
  String get winCredTitle => 'Windows Password';

  @override
  String get winCredGeneratePasswordTab => 'Generate Password';

  @override
  String get winCredStoredCredentialsTab => 'Stored Credentials';

  @override
  String get winCredInfoBox =>
      'Generate a new Windows password or reset an existing one. The password will be stored securely in your system keyring.';

  @override
  String get commonUsernameLabel => 'Username';

  @override
  String get winCredUsernameHint => 'Windows username (e.g., Administrator)';

  @override
  String get winCredEmailLabel => 'Email';

  @override
  String get winCredEmailHint => 'Your email address (for GCP tracking)';

  @override
  String get winCredGenerateNew => 'Generate New';

  @override
  String get winCredResetPassword => 'Reset Password';

  @override
  String get winCredWaitingForAgent =>
      'Waiting for Windows guest agent response…';

  @override
  String get winCredMayTake60s => 'This may take up to 60 seconds';

  @override
  String get winCredGeneratedCredential => 'Generated Credential';

  @override
  String get winCredNoStoredCredentials => 'No stored credentials';

  @override
  String get winCredNoStoredCredentialsHint =>
      'Generate a password for a Windows VM to store it here';

  @override
  String get winCredClearAll => 'Clear All';

  @override
  String get winCredUsernameField => 'Username: ';

  @override
  String get winCredPasswordField => 'Password: ';

  @override
  String get winCredCopyUsernameTooltip => 'Copy username';

  @override
  String get winCredCopyPasswordTooltip => 'Copy password';

  @override
  String get winCredHidePassword => 'Hide password';

  @override
  String get winCredShowPassword => 'Show password';

  @override
  String get commonCurrentChip => 'Current';

  @override
  String get commonPleaseEnterUsername => 'Please enter a username';

  @override
  String get winCredPasswordWord => 'Password';

  @override
  String winCredCopiedToClipboard(String label) {
    return '$label copied to clipboard';
  }

  @override
  String winCredCopiedToClipboardSensitive(String label) {
    return '$label copied to clipboard (clears in 30s)';
  }

  @override
  String get winCredDeleteCredentialTitle => 'Delete Credential';

  @override
  String winCredDeleteCredentialConfirm(String username, String instanceName) {
    return 'Are you sure you want to delete the stored credential for $username@$instanceName?';
  }

  @override
  String get winCredClearAllTitle => 'Clear All Credentials';

  @override
  String get winCredClearAllConfirm =>
      'Are you sure you want to delete ALL stored Windows credentials? This action cannot be undone.';

  @override
  String get sshfsDialogTitle => 'Mount Remote Filesystem';

  @override
  String get sshfsUnavailableDefaultIssue => 'SSHFS is not available';

  @override
  String get sshfsMountAction => 'Mount';

  @override
  String get sshfsActiveMountsTab => 'Active Mounts';

  @override
  String get sshfsNotAvailableTitle => 'SSHFS Not Available';

  @override
  String sshfsMountInfoText(String instanceName, int port) {
    return 'Mount a remote directory from $instanceName to your local filesystem. The tunnel on port $port will be used for the connection.';
  }

  @override
  String get sshfsUsernameLabel => 'SSH Username';

  @override
  String get sshfsUsernameHint => 'Username on the remote VM';

  @override
  String get sshfsRemotePathLabel => 'Remote Path';

  @override
  String get sshfsLocalMountPointLabel => 'Local Mount Point';

  @override
  String get sshfsResetToDefaultTooltip => 'Reset to default';

  @override
  String get sshfsMountOptionsTitle => 'Mount Options';

  @override
  String get sshfsReadOnlyOption => 'Read Only';

  @override
  String get sshfsCacheOption => 'Cache';

  @override
  String get sshfsCompressionOption => 'Compression';

  @override
  String get sshfsAutoReconnectOption => 'Auto-Reconnect';

  @override
  String get sshfsMountingButton => 'Mounting…';

  @override
  String get sshfsNoActiveMountsTitle => 'No active mounts';

  @override
  String get sshfsNoActiveMountsSubtitle =>
      'Mount a remote directory to see it here';

  @override
  String sshfsActiveMountsCount(int count) {
    return '$count active mounts';
  }

  @override
  String get sshfsUnmountAllButton => 'Unmount All';

  @override
  String sshfsThisInstance(String instanceName) {
    return 'This instance ($instanceName)';
  }

  @override
  String get sshfsInfoProject => 'Project';

  @override
  String get sshfsInfoZone => 'Zone';

  @override
  String get sshfsInfoLocalMount => 'Local Mount';

  @override
  String get sshfsInfoTunnelPort => 'Tunnel Port';

  @override
  String get sshfsOpenButton => 'Open';

  @override
  String get sshfsUnmountButton => 'Unmount';

  @override
  String get sshfsRemotePathRequired => 'Please enter a remote path';

  @override
  String get sshfsLocalPathRequired => 'Please enter a local mount point';

  @override
  String get sshfsUnmountAllConfirmMessage =>
      'Are you sure you want to unmount all SSHFS mounts?';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get settingsAutoRefreshTitle => 'Auto-Refresh';

  @override
  String get settingsEnableAutoRefresh => 'Enable Auto-Refresh';

  @override
  String get settingsAutoRefreshSubtitle =>
      'Automatically refresh instance list';

  @override
  String get settingsRefreshIntervalLabel => 'Refresh Interval';

  @override
  String settingsUpdateEverySeconds(int seconds) {
    return 'Update every $seconds seconds';
  }

  @override
  String get settingsIntervalDisabled => 'Disabled';

  @override
  String get settingsInterval10s => '10 seconds';

  @override
  String get settingsInterval30s => '30 seconds';

  @override
  String get settingsInterval60s => '1 minute';

  @override
  String get settingsInterval120s => '2 minutes';

  @override
  String get settingsInterval300s => '5 minutes';

  @override
  String get settingsCustomInterval => 'Custom Interval';

  @override
  String get settingsCustomIntervalSubtitle =>
      'Specify a custom interval (5-600s)';

  @override
  String get settingsSecondsLabel => 'Seconds';

  @override
  String get settingsSecondsHelper => 'Min: 5, Max: 600';

  @override
  String get settingsInvalidNumber => 'Please enter a valid number';

  @override
  String get settingsIntervalRange =>
      'Interval must be between 5 and 600 seconds';

  @override
  String settingsRefreshIntervalSet(int seconds) {
    return 'Refresh interval set to $seconds seconds';
  }

  @override
  String get settingsSetButton => 'Set';

  @override
  String get settingsNotificationsTitle => 'Notifications';

  @override
  String get settingsEnableNotifications => 'Enable Desktop Notifications';

  @override
  String get settingsNotificationsSubtitle =>
      'Get notified about VM state changes and events';

  @override
  String get settingsNotifiedAboutLabel => 'You will be notified about:';

  @override
  String get settingsNotifyVmState => '• VM state changes (RUNNING ↔ STOPPED)';

  @override
  String get settingsNotifyIapFailures => '• IAP tunnel failures';

  @override
  String get settingsNotifyLifecycleResults =>
      '• Lifecycle operation results (start/stop/reset)';

  @override
  String get settingsSystemDependenciesTitle => 'System Dependencies';

  @override
  String get settingsRdpClientTitle => 'RDP Client';

  @override
  String get settingsVncClientTitle => 'VNC Client';

  @override
  String get settingsAboutTitle => 'About';

  @override
  String get settingsEditionsDescription =>
      'Editions follow a half-year cadence (YYH#). 26H2 covers the second half of 2026. Builds deliver continuous fixes between editions.';

  @override
  String get settingsSupportDevelopmentTitle => 'Support Development';

  @override
  String get settingsSupportMessage =>
      'If you find this tool useful, consider supporting its development!';

  @override
  String get settingsChooseThemeLabel => 'Choose your preferred theme:';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeSystem => 'System (Auto)';

  @override
  String get settingsThemeLightDesc => 'Always use light theme';

  @override
  String get settingsThemeDarkDesc => 'Always use dark theme';

  @override
  String get settingsThemeSystemDesc => 'Follow your system preference';

  @override
  String get settingsNoRdpClients =>
      'No RDP clients detected. Please install one of: Remmina, FreeRDP, KRDC, or GNOME Connections.';

  @override
  String get settingsSelectRdpClient => 'Select your preferred RDP client:';

  @override
  String get settingsNotInstalled => 'Not Installed';

  @override
  String get settingsInstallClientHint => 'Install this client to use it';

  @override
  String settingsRdpClientSet(String name) {
    return 'RDP client set to $name';
  }

  @override
  String get settingsClientTip =>
      '💡 Tip: If your preferred client is unavailable, the app will automatically try other installed clients.';

  @override
  String settingsErrorDetectingRdp(String error) {
    return 'Error detecting RDP clients: $error';
  }

  @override
  String get settingsNoVncClients =>
      'No VNC clients detected. Please install one of: Remmina, TigerVNC, KRDC, or Vinagre.';

  @override
  String get settingsSelectVncClient => 'Select your preferred VNC client:';

  @override
  String settingsVncClientSet(String name) {
    return 'VNC client set to $name';
  }

  @override
  String settingsErrorDetectingVnc(String error) {
    return 'Error detecting VNC clients: $error';
  }

  @override
  String get settingsDependencyStatusLabel =>
      'Status of tools used by the application:';

  @override
  String get settingsDepRdpClients => 'RDP Clients';

  @override
  String get settingsDepVncClients => 'VNC Clients';

  @override
  String get settingsDepSqlClients => 'SQL Clients';

  @override
  String get settingsRequiredBadge => 'Required';

  @override
  String settingsInstalledCount(int count) {
    return '$count Installed';
  }

  @override
  String get settingsInstalledLabel => 'Installed';

  @override
  String get settingsNotFound => 'Not Found';

  @override
  String settingsErrorCheckingDeps(String error) {
    return 'Error checking dependencies: $error';
  }

  @override
  String get settingsRdpDescRemmina => 'Feature-rich, supports config files';

  @override
  String get settingsRdpDescFreeRdp => 'CLI-based, widely available';

  @override
  String get settingsRdpDescKrdc => 'KDE default remote desktop client';

  @override
  String get settingsRdpDescGnome => 'Modern GNOME remote desktop app';

  @override
  String get settingsRdpDescMstsc => 'Windows native remote desktop client';

  @override
  String get settingsVncDescRemmina =>
      'Feature-rich, supports both RDP and VNC';

  @override
  String get settingsVncDescTigerVnc => 'High-performance VNC viewer';

  @override
  String get settingsVncDescKrdc => 'KDE VNC and RDP client';

  @override
  String get settingsVncDescVinagre => 'GNOME VNC viewer';

  @override
  String commonEditionLabel(String version) {
    return 'Edition $version';
  }

  @override
  String commonBuildLabel(String build) {
    return 'Build $build';
  }

  @override
  String get manualInstanceTitle => 'Add Instance Manually';

  @override
  String get manualInstanceDescription =>
      'Add an instance when you have view permission but not list permission.';

  @override
  String get manualInstanceProjectIdLabel => 'Project ID';

  @override
  String get manualInstanceProjectIdHint => 'e.g., my-project-123';

  @override
  String get manualInstanceProjectIdRequired => 'Project ID is required';

  @override
  String get manualInstanceZoneLabel => 'Zone';

  @override
  String get manualInstanceZoneHint => 'e.g., us-central1-a';

  @override
  String get manualInstanceZoneRequired => 'Zone is required';

  @override
  String get manualInstanceNameLabel => 'Instance Name';

  @override
  String get manualInstanceNameHint => 'e.g., my-vm-instance';

  @override
  String get manualInstanceNameRequired => 'Instance name is required';

  @override
  String get manualInstanceSearching => 'Searching…';

  @override
  String get manualInstanceSearchButton => 'Search Instance';

  @override
  String get manualInstanceFoundTitle => 'Instance Found!';

  @override
  String manualInstanceViaMethod(String method) {
    return 'via $method';
  }

  @override
  String get manualInstanceFieldName => 'Name';

  @override
  String get manualInstanceFieldStatus => 'Status';

  @override
  String get manualInstanceFieldMachineType => 'Machine Type';

  @override
  String get manualInstanceAddButton => 'Add Instance';

  @override
  String get snapshotDialogTitle => 'VM Snapshots';

  @override
  String get snapshotTabList => 'Snapshots';

  @override
  String snapshotTabListWithCount(int count) {
    return 'Snapshots ($count)';
  }

  @override
  String get snapshotTabCreate => 'Create';

  @override
  String get snapshotEmptyList => 'No snapshots for this VM';

  @override
  String snapshotMetaCreated(String date) {
    return 'Created: $date';
  }

  @override
  String snapshotMetaDisk(String size) {
    return 'Disk: $size';
  }

  @override
  String snapshotMetaStored(String size) {
    return 'Stored: $size';
  }

  @override
  String snapshotMetaSource(String disk) {
    return 'Source: $disk';
  }

  @override
  String get snapshotRestoreDiskButton => 'Restore disk';

  @override
  String get snapshotDeleteTitle => 'Delete snapshot';

  @override
  String get snapshotDeleteConfirm => 'Permanently delete this snapshot?';

  @override
  String snapshotDeletedSnackbar(String name) {
    return 'Snapshot \"$name\" deleted.';
  }

  @override
  String snapshotDeleteError(String error) {
    return 'Error deleting: $error';
  }

  @override
  String get snapshotRestoreTitle => 'Restore from snapshot';

  @override
  String snapshotRestoreDescription(String name) {
    return 'A new disk will be created from snapshot \"$name\".';
  }

  @override
  String get snapshotRestoreVmNote =>
      'The VM is not modified automatically — you will get the gcloud commands to do the swap.';

  @override
  String get snapshotNewDiskNameLabel => 'New disk name';

  @override
  String get snapshotCreateDiskButton => 'Create disk';

  @override
  String get snapshotCreatingDiskFromSnapshot => 'Creating disk from snapshot…';

  @override
  String snapshotCreateDiskError(String error) {
    return 'Error creating disk: $error';
  }

  @override
  String get snapshotDiskCreatedTitle => 'Disk created from snapshot';

  @override
  String snapshotDiskCreatedMessage(String name, String zone) {
    return 'Disk \"$name\" created in $zone.';
  }

  @override
  String get snapshotRestoreCommandsIntro =>
      'To restore the VM, run these commands:';

  @override
  String get snapshotCopyCommandsButton => 'Copy commands';

  @override
  String get snapshotCommandsCopiedSnackbar => 'Commands copied to clipboard';

  @override
  String get snapshotNameRequired => 'Name is required';

  @override
  String get snapshotNameMaxLength => 'Maximum 63 characters';

  @override
  String get snapshotNameMustStartLowercase =>
      'Must start with a lowercase letter';

  @override
  String get snapshotNameInvalidChars =>
      'Only lowercase letters, digits and hyphens';

  @override
  String get snapshotNameNoTrailingHyphen => 'Cannot end with a hyphen';

  @override
  String snapshotCreatedSnackbar(String name) {
    return 'Snapshot \"$name\" created. It may take a few minutes to appear as READY.';
  }

  @override
  String snapshotCreateError(String error) {
    return 'Error creating snapshot: $error';
  }

  @override
  String get snapshotNameFieldLabel => 'Snapshot name *';

  @override
  String get snapshotNameFieldHelper =>
      'Only lowercase letters, digits and hyphens. Max 63 chars.';

  @override
  String get snapshotDescriptionFieldLabel => 'Description (optional)';

  @override
  String get snapshotCreateButton => 'Create Snapshot';

  @override
  String get snapshotCreateDurationNote =>
      'Snapshots may take 2–5 minutes to complete.';

  @override
  String get snapshotCreatingOverlay =>
      'Creating snapshot…\nThis may take several minutes.';

  @override
  String get snapshotDetectingBootDisk => 'Detecting boot disk…';

  @override
  String snapshotBootDiskDetectError(String error) {
    return 'Could not detect boot disk: $error';
  }

  @override
  String get snapshotBootDiskLabel => 'Boot disk:';

  @override
  String get clientTestTitle => 'Client Libraries Testing';

  @override
  String get clientTestTabApi => 'API Testing';

  @override
  String get clientTestTabLifecycle => 'Lifecycle Ops';

  @override
  String get clientTestTabPerformance => 'Performance';

  @override
  String get clientTestRunAllTooltip => 'Run All Tests';

  @override
  String get clientTestRunningAll => 'Running all tests…';

  @override
  String get clientTestLabelClientLibs => 'Client Libraries';

  @override
  String get clientTestHeaderTitle =>
      'Google Cloud Client Libraries Integration';

  @override
  String get clientTestHeaderDescription =>
      'Test and compare the new Client Libraries integration with traditional gcloud CLI. Client Libraries use direct REST API calls for better performance.';

  @override
  String get clientTestAuthTitle => 'Authentication Test';

  @override
  String get clientTestRetryAuth => 'Retry Authentication';

  @override
  String get clientTestProjectsComparisonTitle => 'Projects Listing Comparison';

  @override
  String get clientTestNoProjectsFound => 'No projects found';

  @override
  String clientTestFoundProjectsCount(int count) {
    return 'Found $count projects';
  }

  @override
  String clientTestAndMoreCount(int count) {
    return '… and $count more';
  }

  @override
  String get clientTestAuthenticateFirst =>
      'Please authenticate with gcloud first';

  @override
  String get clientTestPerfBenchmarkTitle => 'Performance Benchmark';

  @override
  String get clientTestBenchmarkDescription =>
      'Measures the time to list all projects using both methods.';

  @override
  String get clientTestRunningBenchmark => 'Running benchmark…';

  @override
  String get clientTestRunBenchmarkButton => 'Run Benchmark';

  @override
  String get clientTestComputeInstancesTitle => 'Compute Engine Instances';

  @override
  String get clientTestSelectProjectHint =>
      'Please select a project from the main dashboard to test instance listing.';

  @override
  String get clientTestNoInstancesFound => 'No instances found';

  @override
  String clientTestFoundInstancesCount(int count) {
    return 'Found $count instances';
  }

  @override
  String get clientTestRefreshBothButton => 'Refresh Both';

  @override
  String get clientTestLifecycleTitle => 'Lifecycle Operations Testing';

  @override
  String get clientTestLifecycleDescription =>
      'Test VM lifecycle operations (start/stop/reset) using both CLI and Client Libraries. Select an instance from the main dashboard to begin testing.';

  @override
  String get clientTestSelectProjectInstanceHint =>
      'Please select a project and instance from the main dashboard';

  @override
  String clientTestInstanceStatusZone(String status, String zone) {
    return 'Status: $status • Zone: $zone';
  }

  @override
  String clientTestCurrentlyTestingWith(String method) {
    return 'Currently testing with: $method';
  }

  @override
  String get clientTestTestOperationsLabel => 'Test Operations:';

  @override
  String get clientTestStartingInstance => 'Starting instance…';

  @override
  String get clientTestInstanceStartedSuccess =>
      'Instance started successfully!';

  @override
  String get clientTestStartInstanceButton => 'Start Instance';

  @override
  String get clientTestStoppingInstance => 'Stopping instance…';

  @override
  String get clientTestInstanceStoppedSuccess =>
      'Instance stopped successfully!';

  @override
  String get clientTestStopInstanceButton => 'Stop Instance';

  @override
  String get clientTestResettingInstance => 'Resetting instance…';

  @override
  String get clientTestInstanceResetSuccess => 'Instance reset successfully!';

  @override
  String get clientTestResetInstanceButton => 'Reset Instance';

  @override
  String get clientTestTestingTipsTitle => 'Testing Tips';

  @override
  String get clientTestTestingTipsBody =>
      '• Switch the API method in the main dashboard AppBar to test both implementations\n• Operations take 30-120 seconds to complete\n• Watch the console for detailed timing information\n• Client Libraries should be slightly faster due to direct API calls';

  @override
  String get clientTestPerfStatsTitle => 'Performance Statistics';

  @override
  String get clientTestPerfStatsDescription =>
      'Aggregate performance data comparing gcloud CLI and Client Libraries. Run benchmarks from the API Testing tab to populate statistics.';

  @override
  String get clientTestBenchmarkSummaryTitle => 'Benchmark Results Summary';

  @override
  String get clientTestMetricSpeedup => 'Speedup';

  @override
  String get clientTestMetricImprovement => 'Improvement';

  @override
  String get clientTestRunBenchmarkHint =>
      'Run benchmark from API Testing tab to see results';

  @override
  String get clientTestExpectedGainsTitle => 'Expected Performance Gains';

  @override
  String get clientTestOpListProjects => 'List Projects';

  @override
  String get clientTestOpListInstances => 'List Instances';

  @override
  String get clientTestOpStartStopInstance => 'Start/Stop Instance';

  @override
  String get clientTestReasonListProjects =>
      'Faster API calls, no process overhead';

  @override
  String get clientTestReasonListInstances =>
      'Direct REST API vs CLI JSON parsing';

  @override
  String get clientTestReasonStartStop => 'Reduced latency from direct API';

  @override
  String get clientTestReasonReset => 'Minimal overhead difference';

  @override
  String get clientTestExpectedGainsFooter =>
      'Client Libraries excel in high-frequency operations. The more API calls, the larger the cumulative time savings.';

  @override
  String get diagTitle => 'VM Diagnostics';

  @override
  String diagSubtitle(String instanceName, String zone) {
    return '$instanceName ($zone)';
  }

  @override
  String get diagTabSerialConsole => 'Serial Console';

  @override
  String get diagTabDiagnostics => 'Diagnostics';

  @override
  String get diagTabAuditLogs => 'Audit Logs';

  @override
  String diagLogsExportedTo(String path) {
    return 'Logs exported to: $path';
  }

  @override
  String get diagOpenAction => 'Open';

  @override
  String diagExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get diagPortLabel => 'Port: ';

  @override
  String get diagSearchHint => 'Search logs…';

  @override
  String get diagAutoScrollTooltip => 'Auto-scroll';

  @override
  String get diagStopAutoRefreshTooltip => 'Stop auto-refresh';

  @override
  String get diagAutoRefreshTooltip => 'Auto-refresh (5s)';

  @override
  String get diagExportLogsTooltip => 'Export logs';

  @override
  String get diagCopyToClipboardTooltip => 'Copy to clipboard';

  @override
  String get diagCopiedToClipboard => 'Copied to clipboard';

  @override
  String diagFetchedAt(String timestamp) {
    return 'Fetched: $timestamp';
  }

  @override
  String diagLinesCount(int count) {
    return '$count lines';
  }

  @override
  String diagLinesCountFiltered(int count) {
    return '$count lines (filtered)';
  }

  @override
  String get diagSerialPortDisabledTitle => 'Serial Port Logging Disabled';

  @override
  String get diagErrorLoadingSerialTitle => 'Error Loading Serial Output';

  @override
  String get diagCopyEnableCommandButton => 'Copy Enable Command';

  @override
  String get diagCommandCopiedToClipboard => 'Command copied to clipboard';

  @override
  String get diagNoData => 'No data';

  @override
  String get diagInstanceStatusTitle => 'Instance Status';

  @override
  String get diagLabelStatus => 'Status';

  @override
  String get diagLabelMachineType => 'Machine Type';

  @override
  String get diagLabelZone => 'Zone';

  @override
  String get diagLabelProject => 'Project';

  @override
  String get diagLabelCreated => 'Created';

  @override
  String get diagLabelLastStarted => 'Last Started';

  @override
  String get diagLabelLastStopped => 'Last Stopped';

  @override
  String get diagGuestAgentTitle => 'Guest Agent';

  @override
  String get diagStatusReporting => 'Reporting';

  @override
  String get diagStatusNotReporting => 'Not Reporting';

  @override
  String get diagLabelOsType => 'OS Type';

  @override
  String get diagLabelOsVersion => 'OS Version';

  @override
  String get diagLabelLastHeartbeat => 'Last Heartbeat';

  @override
  String get diagGuestAgentWarning =>
      'The guest agent may not be installed or running.';

  @override
  String get diagNetworkInterfacesTitle => 'Network Interfaces';

  @override
  String diagInterfaceNumber(int number) {
    return 'Interface $number';
  }

  @override
  String get diagLabelNetwork => 'Network';

  @override
  String get diagLabelSubnetwork => 'Subnetwork';

  @override
  String get diagLabelInternalIp => 'Internal IP';

  @override
  String get diagLabelExternalIp => 'External IP';

  @override
  String get diagValueNone => 'None';

  @override
  String get diagLabelTier => 'Tier';

  @override
  String get diagDisksTitle => 'Disks';

  @override
  String get diagBootChip => 'Boot';

  @override
  String get diagLabelType => 'Type';

  @override
  String get diagLabelSize => 'Size';

  @override
  String diagSizeGb(int size) {
    return '$size GB';
  }

  @override
  String get diagLabelMode => 'Mode';

  @override
  String get diagLabelAutoDelete => 'Auto-delete';

  @override
  String get diagLabelsTitle => 'Labels';

  @override
  String diagLabelKeyValue(String key, String value) {
    return '$key: $value';
  }

  @override
  String get diagLastLabel => 'Last: ';

  @override
  String get diagHours1 => '1 hour';

  @override
  String get diagHours6 => '6 hours';

  @override
  String get diagHours24 => '24 hours';

  @override
  String get diagDays3 => '3 days';

  @override
  String get diagDays7 => '7 days';

  @override
  String get diagThisInstanceOnly => 'This instance only';

  @override
  String get diagPermissionDeniedTitle => 'Permission Denied';

  @override
  String get diagErrorLoadingAuditLogsTitle => 'Error Loading Audit Logs';

  @override
  String get diagNoAuditLogsFound =>
      'No audit logs found in the selected time range';

  @override
  String get diagUnknownOperation => 'Unknown operation';

  @override
  String get diagSystemFallback => 'System';

  @override
  String diagLogSubtitle(String timestamp, String principal) {
    return '$timestamp - $principal';
  }

  @override
  String get diagLabelSeverity => 'Severity';

  @override
  String get diagLabelResource => 'Resource';

  @override
  String get diagValueNa => 'N/A';

  @override
  String get diagLabelResourceType => 'Resource Type';

  @override
  String get diagLabelLog => 'Log';

  @override
  String get diagLabelRequest => 'Request';

  @override
  String sftpErrorLoadDirectory(String path, String error) {
    return 'Failed to load directory \"$path\": $error\n\nCheck permissions and network connectivity.';
  }

  @override
  String sftpUploadingFile(String fileName) {
    return 'Uploading $fileName…';
  }

  @override
  String sftpErrorUploadFile(String fileName, String error) {
    return 'Failed to upload \"$fileName\": $error\n\nCheck file permissions and disk space.';
  }

  @override
  String sftpUploadingBatch(int current, int total, String fileName) {
    return 'Uploading $current/$total: $fileName…';
  }

  @override
  String sftpUploadingFolder(String folderName) {
    return 'Uploading folder $folderName…';
  }

  @override
  String sftpUploadingFolderProgress(int current, int total, String fileName) {
    return 'Uploading $current/$total: $fileName…';
  }

  @override
  String sftpErrorUploadFolder(String error) {
    return 'Failed to upload folder: $error\n\nSome files may have been uploaded successfully.';
  }

  @override
  String get sftpErrorFolderNameInvalid => 'Invalid folder name.';

  @override
  String sftpErrorUploadBatch(String error) {
    return 'Failed to upload files: $error\n\nSome files may have been uploaded successfully.';
  }

  @override
  String sftpDownloadingFile(String fileName) {
    return 'Downloading $fileName…';
  }

  @override
  String sftpErrorDownloadFile(String fileName, String error) {
    return 'Failed to download \"$fileName\": $error\n\nCheck local disk space and permissions.';
  }

  @override
  String get sftpErrorDirNameEmpty => 'Directory name cannot be empty.';

  @override
  String get sftpErrorDirNameSeparators =>
      'Directory name cannot contain path separators (/ or \\).';

  @override
  String get sftpErrorDirNameParentRef =>
      'Directory name cannot contain \"..\" (parent directory references).';

  @override
  String get sftpErrorDirNameTooLong =>
      'Directory name too long (max 255 characters).';

  @override
  String get sftpCreatingDirectory => 'Creating directory…';

  @override
  String sftpErrorCreateDirectory(String dirName, String error) {
    return 'Failed to create directory \"$dirName\": $error\n\nCheck remote permissions.';
  }

  @override
  String sftpDeletingFile(String fileName) {
    return 'Deleting $fileName…';
  }

  @override
  String sftpErrorDeleteFile(String fileName, String error) {
    return 'Failed to delete \"$fileName\": $error\n\nCheck remote permissions and ensure it is not in use.';
  }

  @override
  String get sftpLoadingPreview => 'Loading preview…';

  @override
  String sftpErrorLoadPreview(String error) {
    return 'Failed to load preview: $error';
  }

  @override
  String sftpFileBrowserTitle(String instanceName) {
    return 'File Browser - $instanceName';
  }

  @override
  String get sftpSearchHint => 'Search files and folders…';

  @override
  String get sftpParentDirectoryTooltip => 'Go to parent directory';

  @override
  String get sftpUploadButton => 'Upload';

  @override
  String get sftpUploadFileButton => 'Upload File';

  @override
  String get sftpUploadFolderButton => 'Upload Folder';

  @override
  String get sftpNewFolderButton => 'New Folder';

  @override
  String get sftpDropFilesHere => 'Drop files here to upload';

  @override
  String get sftpEmptyFolder =>
      'This folder is empty\n\nDrag & drop files here to upload';

  @override
  String sftpNoFilesMatch(String query) {
    return 'No files match \"$query\"';
  }

  @override
  String get sftpCreateFolderTitle => 'Create New Folder';

  @override
  String get sftpFolderNameLabel => 'Folder Name';

  @override
  String get sftpCreateButton => 'Create';

  @override
  String get sftpConfirmDeleteTitle => 'Confirm Delete';

  @override
  String sftpConfirmDeleteMessage(String fileName) {
    return 'Are you sure you want to delete \"$fileName\"?';
  }

  @override
  String get sftpFolderLabel => 'Folder';

  @override
  String get sftpPreviewTooltip => 'Preview';

  @override
  String get sftpDownloadTooltip => 'Download';

  @override
  String sftpErrorLoadFile(String error) {
    return 'Failed to load file: $error';
  }

  @override
  String get sftpErrorLoadImage => 'Failed to load image';

  @override
  String get dashboardLoadingAccountsTooltip => 'Loading accounts…';

  @override
  String get appLogoutButton => 'Logout';

  @override
  String get appConnectionHistoryTitle => 'Connection History';

  @override
  String get appExportLogsTooltip => 'Export Logs';

  @override
  String get appAboutTooltip => 'About';

  @override
  String get dashboardGcloudRequiredTitle => 'Google Cloud CLI Required';

  @override
  String get dashboardGcloudRequiredDescription =>
      'Lightweight Cloud Connector requires the Google Cloud CLI (gcloud) to connect to your GCP resources.';

  @override
  String get dashboardInstallInstructionsTitle => 'Installation Instructions';

  @override
  String get dashboardInstallInstructionsBody =>
      'Please go to the following site and follow the instructions to install the Google Cloud SDK for your operating system:';

  @override
  String get dashboardOpenInstructionsButton => 'Open Instructions in Browser';

  @override
  String get dashboardCheckAgainButton => 'Check Again';

  @override
  String get dashboardLaunchingBrowserLogin => 'Launching browser for login…';

  @override
  String dashboardLoginFailed(String error) {
    return 'Login Failed: $error';
  }

  @override
  String get dashboardLoginButton => 'Login to Google Cloud';

  @override
  String get appExportingLogs => 'Exporting logs…';

  @override
  String get appLogsExportedTitle => 'Logs Exported Successfully';

  @override
  String get appLogsExportedBody =>
      'All logs have been consolidated and exported to:';

  @override
  String get appLogsExportedHint =>
      'You can share this file for troubleshooting.';

  @override
  String appExportLogsFailed(String error) {
    return 'Failed to export logs: $error';
  }

  @override
  String appLogoutMultiAccountCount(int count) {
    return 'You have $count authenticated accounts.';
  }

  @override
  String appLogoutActiveAccount(String email) {
    return 'Active: $email';
  }

  @override
  String appLogoutThisAccount(String email) {
    return 'Logout $email';
  }

  @override
  String get appLogoutAllAccounts => 'Logout All';

  @override
  String get appLogoutConfirmSingle =>
      'This will revoke your Google Cloud credentials from this machine. Are you sure?';

  @override
  String appLoggedOutAccount(String email) {
    return 'Logged out $email.';
  }

  @override
  String appLogoutError(String error) {
    return 'Logout Error: $error';
  }

  @override
  String get appLoggedOutFullMessage =>
      'Logged out successfully. All cached data cleared.';

  @override
  String dashboardAutoRefreshEnabledTooltip(int seconds) {
    return 'Auto-refresh enabled (${seconds}s)';
  }

  @override
  String get dashboardEnableAutoRefreshTooltip => 'Enable auto-refresh';

  @override
  String get dashboardAutoRefreshDisabledSnackbar => 'Auto-refresh disabled';

  @override
  String dashboardAutoRefreshEnabledSnackbar(int seconds) {
    return 'Auto-refresh enabled (${seconds}s interval)';
  }

  @override
  String appAddedInstanceSnackbar(String name) {
    return 'Added instance: $name';
  }

  @override
  String get appCopyright => '© 2026 Jordi Lopez Reyes';

  @override
  String get appTagline =>
      'A native tool to simplify Google Cloud IAP connections on Linux.';

  @override
  String get appEditionsCalverTitle => 'LCC Editions — CalVer';

  @override
  String get appEditionsCalverBody =>
      'Editions follow a half-year cadence (YYH#):\n  • 26H1 — First half of 2026\n  • 26H2 — Second half of 2026 (current)\nBuilds provide continuous fixes between editions.';

  @override
  String appWhatsNewTitle(String edition) {
    return 'What\'s new in Edition $edition:';
  }

  @override
  String get appWhatsNewItem1 => '• VM Labels display & label-based search';

  @override
  String get appWhatsNewItem2 => '• Suspend/Resume VM state';

  @override
  String get appWhatsNewItem3 => '• OS Login & Windows VM auto-detection';

  @override
  String get appWhatsNewItem4 => '• Global Tunnel Manager + Auto-Reconnect';

  @override
  String get appWhatsNewItem5 => '• Multi-account & Project Explorer';

  @override
  String get appWhatsNewItem6 => '• Connectivity Doctor (10 diagnostic checks)';

  @override
  String get appWhatsNewItem7 =>
      '• SSHFS Mount, Database Clients, Windows Credentials';

  @override
  String get appDeveloperLabel => 'Developer:';

  @override
  String get appSourceCodeLabel => 'Source Code:';

  @override
  String get appTechStackLabel => 'Tech Stack:';

  @override
  String get appTechStackValue =>
      'Flutter • Rust • Google Cloud Client Libraries';

  @override
  String get dashboardSearchInstancesHint => 'Search instances…';

  @override
  String get dashboardFilterAll => 'All';

  @override
  String get dashboardAllProjectsHint => 'All Projects';

  @override
  String get dashboardNoProjectsSelected => 'No projects selected';

  @override
  String get dashboardSelectProjectsHint =>
      'Click \"Select Projects\" above to choose GCP projects';

  @override
  String get dashboardProjectsErrorsTitle => 'Some projects had errors';

  @override
  String get dashboardPermissionDeniedParen => '(Permission denied)';

  @override
  String get dashboardErrorParen => '(Error)';

  @override
  String get dashboardNoInstancesFoundProjects =>
      'No instances found in selected projects.';

  @override
  String get dashboardNoMatchingInstances => 'No matching instances.';

  @override
  String dashboardFavoritesCount(int count) {
    return 'Favorites ($count)';
  }

  @override
  String get dashboardRemoveFavoriteTooltip => 'Remove from favorites';

  @override
  String get dashboardAddFavoriteTooltip => 'Add to favorites';

  @override
  String get dashboardPermissionDenied => 'Permission denied';

  @override
  String get dashboardErrorLoadingShort => 'Error loading';

  @override
  String dashboardRunningTunnelActive(String machineType) {
    return 'RUNNING • Tunnel Active • $machineType';
  }

  @override
  String get dashboardMenuMountSshfs => 'Mount SSHFS';

  @override
  String get dashboardMenuStop => 'Stop';

  @override
  String get dashboardMenuStart => 'Start';

  @override
  String get dashboardMenuSuspend => 'Suspend';

  @override
  String get dashboardMenuReset => 'Reset';

  @override
  String get dashboardMenuResume => 'Resume';

  @override
  String get dashboardMenuDoctor => 'Doctor';

  @override
  String get dashboardOpeningSftp => 'Opening SFTP…';

  @override
  String get dashboardOpeningSshfsMount => 'Opening SSHFS mount…';

  @override
  String get dashboardStartingInstanceShort => 'Starting instance…';

  @override
  String get dashboardStoppingInstanceShort => 'Stopping instance…';

  @override
  String get dashboardSuspendingInstanceShort => 'Suspending instance…';

  @override
  String get dashboardResumingInstanceShort => 'Resuming instance…';

  @override
  String get dashboardResettingInstanceShort => 'Resetting instance…';

  @override
  String get dashboardSelectInstanceHint =>
      'Select an instance to view details';

  @override
  String get dashboardInstanceResourcesTitle => 'Instance Resources';

  @override
  String get dashboardCpuLabel => 'CPU';

  @override
  String dashboardVcpusValue(int count) {
    return '$count vCPUs';
  }

  @override
  String get dashboardRamLabel => 'RAM';

  @override
  String dashboardSizeGbValue(String size) {
    return '$size GB';
  }

  @override
  String get dashboardDiskLabel => 'Disk';

  @override
  String get dashboardOsLoginChip => 'OS Login';

  @override
  String get dashboardActiveTunnelsTitle => 'Active Tunnels';

  @override
  String get dashboardActionsTitle => 'Actions';

  @override
  String get dashboardConnectRdpButton => 'Connect RDP';

  @override
  String get dashboardConnectVncButton => 'Connect VNC';

  @override
  String get dashboardConnectSshButton => 'Connect SSH';

  @override
  String get dashboardLaunchingTerminal => 'Launching Terminal…';

  @override
  String dashboardSshError(String error) {
    return 'SSH Error: $error';
  }

  @override
  String get dashboardOpenSftpButton => 'Open SFTP';

  @override
  String get dashboardOpeningTunnelSftp => 'Opening tunnel for SFTP…';

  @override
  String get dashboardSftpTunnelFailed =>
      'Failed to create SSH tunnel for SFTP.\n\nPlease verify:\n• Instance is RUNNING\n• You have IAP tunnel permissions\n• Network connectivity is working\n• gcloud CLI is authenticated';

  @override
  String dashboardStateError(String error) {
    return 'State error: $error\nPlease restart the app.';
  }

  @override
  String dashboardSftpBrowserFailed(String error) {
    return 'Failed to open SFTP browser: $error';
  }

  @override
  String get dashboardUnexpectedError =>
      'An unexpected error occurred.\nPlease check console logs and report this bug.';

  @override
  String get dashboardCustomTunnelButton => 'Custom Tunnel';

  @override
  String get dashboardDatabaseButton => 'Database';

  @override
  String get dashboardCreatingSshTunnelSshfs =>
      'Creating SSH tunnel for SSHFS mount…';

  @override
  String get dashboardSshfsTunnelFailed =>
      'Failed to create SSH tunnel for SSHFS mount.';

  @override
  String get dashboardDisconnectAllTunnelsButton => 'Disconnect All Tunnels';

  @override
  String get dashboardTestIapConnectionButton => 'Test IAP Connection';

  @override
  String get dashboardTestingIapConnection =>
      'Testing IAP connection… This verifies if IAP is properly configured.';

  @override
  String get dashboardStartInstanceButton => 'Start Instance';

  @override
  String get dashboardStartingInstanceProgress =>
      'Starting instance… This may take a few minutes.';

  @override
  String dashboardStartInstanceFailed(String error) {
    return 'Failed to start instance: $error';
  }

  @override
  String get dashboardStopInstanceButton => 'Stop Instance';

  @override
  String dashboardStopInstanceConfirm(String name) {
    return 'Are you sure you want to stop $name?\n\nThis will disconnect all active tunnels and shut down the instance.';
  }

  @override
  String get dashboardStoppingInstanceProgress =>
      'Stopping instance… This may take a few minutes.';

  @override
  String dashboardStopInstanceFailed(String error) {
    return 'Failed to stop instance: $error';
  }

  @override
  String get dashboardResetInstanceButton => 'Reset Instance';

  @override
  String dashboardResetInstanceConfirm(String name) {
    return 'Are you sure you want to reset $name?\n\nThis will forcefully restart the instance and disconnect all active tunnels.';
  }

  @override
  String get dashboardResettingInstanceProgress =>
      'Resetting instance… This may take a few minutes.';

  @override
  String dashboardResetInstanceFailed(String error) {
    return 'Failed to reset instance: $error';
  }

  @override
  String get dashboardSuspendInstanceButton => 'Suspend Instance';

  @override
  String dashboardSuspendInstanceConfirm(String name) {
    return 'Are you sure you want to suspend $name?\n\nThis will save the VM state to disk and disconnect all active tunnels. You can resume it later.';
  }

  @override
  String get dashboardSuspendingInstanceProgress =>
      'Suspending instance… This may take a few minutes.';

  @override
  String get dashboardInstanceSuspendedSuccess =>
      'Instance suspended successfully!';

  @override
  String dashboardSuspendInstanceFailed(String error) {
    return 'Failed to suspend instance: $error';
  }

  @override
  String get dashboardResumeInstanceButton => 'Resume Instance';

  @override
  String get dashboardResumingInstanceProgress =>
      'Resuming instance… This may take a few minutes.';

  @override
  String get dashboardInstanceResumedSuccess =>
      'Instance resumed successfully!';

  @override
  String dashboardResumeInstanceFailed(String error) {
    return 'Failed to resume instance: $error';
  }

  @override
  String get appCustomTunnelTitle => 'Custom Tunnel Configuration';

  @override
  String get appCustomTunnelDescription =>
      'Select a service preset or enter a custom port:';

  @override
  String get appCustomPortLabel => 'Custom Port';

  @override
  String get appCustomPortHint => 'Enter port (1-65535)';

  @override
  String appSelectedPortLabel(int port) {
    return 'Selected port: $port';
  }

  @override
  String get appConnectionSettingsTitle => 'Connection Settings';

  @override
  String get appDomainOptionalLabel => 'Domain (Optional)';

  @override
  String get appSaveCredentialsLabel => 'Save Credentials';

  @override
  String get appFullscreenLabel => 'Fullscreen';

  @override
  String get appWidthLabel => 'Width';

  @override
  String get appHeightLabel => 'Height';

  @override
  String get appVncConnectionSettingsTitle => 'VNC Connection Settings';

  @override
  String get appPasswordOptionalLabel => 'Password (Optional)';

  @override
  String get appVncPasswordHelper =>
      'Leave empty if VNC server has no password';

  @override
  String get appDisplayOptionsLabel => 'Display Options';

  @override
  String get appViewOnlyLabel => 'View Only';

  @override
  String get appViewOnlyHelper => 'Read-only mode (no keyboard/mouse input)';

  @override
  String get appQualityLabel => 'Quality';

  @override
  String get appConnectionQualityLabel => 'Connection Quality';

  @override
  String get appQualityAuto => 'Auto (Recommended)';

  @override
  String get appQualityHigh => 'High Quality';

  @override
  String get appQualityMedium => 'Medium Quality';

  @override
  String get appQualityLow => 'Low Quality (Faster)';

  @override
  String get dashboardTunnelUnhealthy => 'Unhealthy';

  @override
  String get dashboardTunnelDegraded => 'Degraded';

  @override
  String dashboardTunnelPortLabel(String port) {
    return 'Tunnel → :$port';
  }

  @override
  String get dashboardDisconnectTunnelTooltip => 'Disconnect this tunnel';

  @override
  String get dashboardUptimeLabel => 'Uptime';

  @override
  String get dashboardLastCheckLabel => 'Last Check';

  @override
  String get dashboardLatencyLabel => 'Latency';

  @override
  String dashboardAttemptLabel(int current, int max) {
    return 'Attempt $current/$max';
  }

  @override
  String get dashboardRetryConnectionButton => 'Retry Connection';

  @override
  String get dashboardOnState => 'ON';

  @override
  String get dashboardOffState => 'OFF';

  @override
  String dashboardAutoMonitoringLabel(String state) {
    return 'Auto-monitoring every 30s | Auto-reconnect: $state';
  }

  @override
  String get appNoProjectsFound => 'No projects found.';

  @override
  String get appSelectProjectLabel => 'Select Project';

  @override
  String appErrorLoadingProjects(String error) {
    return 'Error loading projects: $error';
  }

  @override
  String get appSelectProjectsButton => 'Select Projects';

  @override
  String appProjectsSelectedCount(int count, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Projects',
      one: '$count Project',
    );
    return '$_temp0 ($total VMs)';
  }

  @override
  String appProjectsErrorsTooltip(int count) {
    return '$count project(s) with errors';
  }

  @override
  String get appManageProjectsTitle => 'Manage Projects';

  @override
  String get appRefreshAllProjectsTooltip => 'Refresh all projects';

  @override
  String get appSearchProjectsHint => 'Search projects…';

  @override
  String appProjectsSelectedOfMax(int count, int max) {
    return '$count of $max projects selected';
  }

  @override
  String appTotalVmsLabel(int total) {
    return '$total total VMs';
  }

  @override
  String get appNoProjectsAvailable => 'No projects available';

  @override
  String get appNoMatchingProjects => 'No matching projects';

  @override
  String appInstanceCountVms(int count) {
    return '$count VMs';
  }

  @override
  String get appClearAllButton => 'Clear All';

  @override
  String get appDoneButton => 'Done';

  @override
  String get appClearButton => 'Clear';

  @override
  String get appClearHistoryTitle => 'Clear History';

  @override
  String get appClearHistoryConfirm =>
      'Are you sure you want to clear all connection history?';

  @override
  String get appNoConnectionHistory => 'No connection history';

  @override
  String get appNoConnectionHistoryHint =>
      'Your recent connections will appear here';

  @override
  String get appConnectAgainTooltip => 'Connect again';

  @override
  String get appVmNotFoundTooltip => 'VM not found in current projects';

  @override
  String get appJustNow => 'Just now';

  @override
  String appMinutesAgo(int minutes) {
    return '${minutes}m ago';
  }

  @override
  String appHoursAgo(int hours) {
    return '${hours}h ago';
  }

  @override
  String appDaysAgo(int days) {
    return '${days}d ago';
  }
}
