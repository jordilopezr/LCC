import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Lightweight Cloud Connector'**
  String get appTitle;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get settingsLanguageSystem;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get commonRemove;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get commonRefresh;

  /// No description provided for @commonCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// No description provided for @commonError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get commonError;

  /// No description provided for @commonWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get commonWarning;

  /// No description provided for @commonOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// No description provided for @commonYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get commonYes;

  /// No description provided for @commonNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get commonNo;

  /// No description provided for @commonConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get commonConnect;

  /// No description provided for @commonDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get commonDisconnect;

  /// No description provided for @commonAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// No description provided for @commonEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// No description provided for @commonLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get commonLoading;

  /// No description provided for @commonNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get commonNever;

  /// No description provided for @accountManageTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage Accounts'**
  String get accountManageTitle;

  /// No description provided for @accountActiveTunnelsWarning.
  ///
  /// In en, this message translates to:
  /// **'Active tunnels will be disconnected when switching accounts.'**
  String get accountActiveTunnelsWarning;

  /// No description provided for @accountNoneFound.
  ///
  /// In en, this message translates to:
  /// **'No authenticated accounts found.'**
  String get accountNoneFound;

  /// No description provided for @accountActiveBadge.
  ///
  /// In en, this message translates to:
  /// **'ACTIVE'**
  String get accountActiveBadge;

  /// No description provided for @accountSwitchButton.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get accountSwitchButton;

  /// No description provided for @accountSwitchedTo.
  ///
  /// In en, this message translates to:
  /// **'Switched to {account}'**
  String accountSwitchedTo(String account);

  /// No description provided for @accountRemoveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove account'**
  String get accountRemoveTooltip;

  /// No description provided for @accountAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add Account'**
  String get accountAddButton;

  /// No description provided for @accountRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove Account'**
  String get accountRemoveTitle;

  /// No description provided for @accountRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Revoke credentials for {email}?'**
  String accountRemoveConfirm(String email);

  /// No description provided for @accountActiveAccountWarning.
  ///
  /// In en, this message translates to:
  /// **'This is the active account. All tunnels will be disconnected.'**
  String get accountActiveAccountWarning;

  /// No description provided for @commonGcpErrorPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Access denied. Check your GCP permissions.'**
  String get commonGcpErrorPermissionDenied;

  /// No description provided for @commonGcpErrorNotFound.
  ///
  /// In en, this message translates to:
  /// **'Resource not found.'**
  String get commonGcpErrorNotFound;

  /// No description provided for @commonGcpErrorUnauthenticated.
  ///
  /// In en, this message translates to:
  /// **'Authentication required. Please re-login.'**
  String get commonGcpErrorUnauthenticated;

  /// No description provided for @commonGcpErrorQuotaExceeded.
  ///
  /// In en, this message translates to:
  /// **'GCP quota exceeded.'**
  String get commonGcpErrorQuotaExceeded;

  /// No description provided for @commonGcpErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network error. Check your connection.'**
  String get commonGcpErrorNetwork;

  /// No description provided for @commonGcpErrorUnknown.
  ///
  /// In en, this message translates to:
  /// **'An error occurred. Please check your configuration.'**
  String get commonGcpErrorUnknown;

  /// No description provided for @accountRemovedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Account {email} removed'**
  String accountRemovedSnackbar(String email);

  /// No description provided for @tunnelManagerTitle.
  ///
  /// In en, this message translates to:
  /// **'Tunnel Manager'**
  String get tunnelManagerTitle;

  /// No description provided for @tunnelTotalCount.
  ///
  /// In en, this message translates to:
  /// **'{count} Total'**
  String tunnelTotalCount(int count);

  /// No description provided for @tunnelHealthyCount.
  ///
  /// In en, this message translates to:
  /// **'{count} Healthy'**
  String tunnelHealthyCount(int count);

  /// No description provided for @tunnelErrorCount.
  ///
  /// In en, this message translates to:
  /// **'{count} Error'**
  String tunnelErrorCount(int count);

  /// No description provided for @tunnelReconnectingCount.
  ///
  /// In en, this message translates to:
  /// **'{count} Reconnecting'**
  String tunnelReconnectingCount(int count);

  /// No description provided for @tunnelNoActiveTunnels.
  ///
  /// In en, this message translates to:
  /// **'No active tunnels'**
  String get tunnelNoActiveTunnels;

  /// No description provided for @tunnelConnectPrompt.
  ///
  /// In en, this message translates to:
  /// **'Connect to an instance to create a tunnel'**
  String get tunnelConnectPrompt;

  /// No description provided for @tunnelDisconnectAll.
  ///
  /// In en, this message translates to:
  /// **'Disconnect All'**
  String get tunnelDisconnectAll;

  /// No description provided for @tunnelDisconnectAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Disconnect All Tunnels?'**
  String get tunnelDisconnectAllTitle;

  /// No description provided for @tunnelDisconnectAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will close all {count} active tunnel(s).'**
  String tunnelDisconnectAllConfirm(int count);

  /// No description provided for @tunnelCleanupZombies.
  ///
  /// In en, this message translates to:
  /// **'Cleanup Zombies'**
  String get tunnelCleanupZombies;

  /// No description provided for @tunnelNoZombiesFound.
  ///
  /// In en, this message translates to:
  /// **'No zombie tunnels found'**
  String get tunnelNoZombiesFound;

  /// No description provided for @tunnelCleanedUpZombies.
  ///
  /// In en, this message translates to:
  /// **'Cleaned up {count} zombie tunnel(s)'**
  String tunnelCleanedUpZombies(int count);

  /// No description provided for @tunnelCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Cleanup failed: {error}'**
  String tunnelCleanupFailed(String error);

  /// No description provided for @tunnelStatusReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting'**
  String get tunnelStatusReconnecting;

  /// No description provided for @tunnelStatusHealthy.
  ///
  /// In en, this message translates to:
  /// **'Healthy'**
  String get tunnelStatusHealthy;

  /// No description provided for @tunnelAutoReconnect.
  ///
  /// In en, this message translates to:
  /// **'Auto-reconnect'**
  String get tunnelAutoReconnect;

  /// No description provided for @tunnelRetryNow.
  ///
  /// In en, this message translates to:
  /// **'Retry Now'**
  String get tunnelRetryNow;

  /// No description provided for @doctorTitle.
  ///
  /// In en, this message translates to:
  /// **'Connectivity Doctor'**
  String get doctorTitle;

  /// No description provided for @doctorRunAgain.
  ///
  /// In en, this message translates to:
  /// **'Run Again'**
  String get doctorRunAgain;

  /// No description provided for @doctorRunning.
  ///
  /// In en, this message translates to:
  /// **'Running…'**
  String get doctorRunning;

  /// No description provided for @doctorExportReport.
  ///
  /// In en, this message translates to:
  /// **'Export Report'**
  String get doctorExportReport;

  /// No description provided for @doctorReportExported.
  ///
  /// In en, this message translates to:
  /// **'Report exported to: {path}'**
  String doctorReportExported(String path);

  /// No description provided for @doctorCopyPath.
  ///
  /// In en, this message translates to:
  /// **'Copy Path'**
  String get doctorCopyPath;

  /// No description provided for @doctorExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to export report: {error}'**
  String doctorExportFailed(String error);

  /// No description provided for @doctorConfirmFixTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm Fix Action'**
  String get doctorConfirmFixTitle;

  /// No description provided for @doctorConfirmStartVm.
  ///
  /// In en, this message translates to:
  /// **'Start the VM instance \"{instanceName}\"?'**
  String doctorConfirmStartVm(String instanceName);

  /// No description provided for @doctorConfirmReauthenticate.
  ///
  /// In en, this message translates to:
  /// **'Re-authenticate with gcloud? This will open a browser window.'**
  String get doctorConfirmReauthenticate;

  /// No description provided for @doctorConfirmExecuteFix.
  ///
  /// In en, this message translates to:
  /// **'Execute fix action \"{fixActionId}\"?'**
  String doctorConfirmExecuteFix(String fixActionId);

  /// No description provided for @doctorExecute.
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get doctorExecute;

  /// No description provided for @doctorFixFailed.
  ///
  /// In en, this message translates to:
  /// **'Fix failed: {error}'**
  String doctorFixFailed(String error);

  /// No description provided for @doctorRunningChecks.
  ///
  /// In en, this message translates to:
  /// **'Running connectivity checks…'**
  String get doctorRunningChecks;

  /// No description provided for @commonErrorPrefix.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String commonErrorPrefix(String error);

  /// No description provided for @doctorNoResultsYet.
  ///
  /// In en, this message translates to:
  /// **'No results yet'**
  String get doctorNoResultsYet;

  /// No description provided for @doctorCommandCopied.
  ///
  /// In en, this message translates to:
  /// **'Command copied to clipboard'**
  String get doctorCommandCopied;

  /// No description provided for @doctorCategoryAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get doctorCategoryAuthentication;

  /// No description provided for @doctorCategoryProjectPermissions.
  ///
  /// In en, this message translates to:
  /// **'Project & Permissions'**
  String get doctorCategoryProjectPermissions;

  /// No description provided for @doctorCategoryIapNetwork.
  ///
  /// In en, this message translates to:
  /// **'IAP & Network'**
  String get doctorCategoryIapNetwork;

  /// No description provided for @doctorCategoryVmStatus.
  ///
  /// In en, this message translates to:
  /// **'VM Status'**
  String get doctorCategoryVmStatus;

  /// No description provided for @doctorCategoryLocalEnvironment.
  ///
  /// In en, this message translates to:
  /// **'Local Environment'**
  String get doctorCategoryLocalEnvironment;

  /// No description provided for @doctorTotalDuration.
  ///
  /// In en, this message translates to:
  /// **'Total: {ms}ms'**
  String doctorTotalDuration(int ms);

  /// No description provided for @doctorCopyCommand.
  ///
  /// In en, this message translates to:
  /// **'Copy Command'**
  String get doctorCopyCommand;

  /// No description provided for @doctorFix.
  ///
  /// In en, this message translates to:
  /// **'Fix'**
  String get doctorFix;

  /// No description provided for @dbConnectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Database Connection'**
  String get dbConnectionTitle;

  /// No description provided for @dbTabNewConnection.
  ///
  /// In en, this message translates to:
  /// **'New Connection'**
  String get dbTabNewConnection;

  /// No description provided for @dbTabSavedProfiles.
  ///
  /// In en, this message translates to:
  /// **'Saved Profiles'**
  String get dbTabSavedProfiles;

  /// No description provided for @dbCreatingTunnel.
  ///
  /// In en, this message translates to:
  /// **'Creating tunnel to port {port}…'**
  String dbCreatingTunnel(int port);

  /// No description provided for @dbTunnelCreationFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to create tunnel'**
  String get dbTunnelCreationFailed;

  /// No description provided for @dbLaunched.
  ///
  /// In en, this message translates to:
  /// **'Launched {clientName}'**
  String dbLaunched(String clientName);

  /// No description provided for @dbLaunchedFallback.
  ///
  /// In en, this message translates to:
  /// **'Launched {clientName} (fallback)'**
  String dbLaunchedFallback(String clientName);

  /// No description provided for @dbConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {error}'**
  String dbConnectionFailed(String error);

  /// No description provided for @dbEnterProfileName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a profile name'**
  String get dbEnterProfileName;

  /// No description provided for @dbProfileSaved.
  ///
  /// In en, this message translates to:
  /// **'Profile \"{name}\" saved'**
  String dbProfileSaved(String name);

  /// No description provided for @dbTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Database Type'**
  String get dbTypeLabel;

  /// No description provided for @dbRemotePortLabel.
  ///
  /// In en, this message translates to:
  /// **'Remote Port'**
  String get dbRemotePortLabel;

  /// No description provided for @dbCustomPort.
  ///
  /// In en, this message translates to:
  /// **'Custom port'**
  String get dbCustomPort;

  /// No description provided for @dbDatabaseNameOptional.
  ///
  /// In en, this message translates to:
  /// **'Database Name (optional)'**
  String get dbDatabaseNameOptional;

  /// No description provided for @dbUsernameOptional.
  ///
  /// In en, this message translates to:
  /// **'Username (optional)'**
  String get dbUsernameOptional;

  /// No description provided for @dbSqlClientLabel.
  ///
  /// In en, this message translates to:
  /// **'SQL Client'**
  String get dbSqlClientLabel;

  /// No description provided for @dbNoCompatibleClients.
  ///
  /// In en, this message translates to:
  /// **'No compatible clients found for {dbType}.\nPlease install one of the supported clients.'**
  String dbNoCompatibleClients(String dbType);

  /// No description provided for @dbAutoClient.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get dbAutoClient;

  /// No description provided for @dbErrorLoadingClients.
  ///
  /// In en, this message translates to:
  /// **'Error loading clients: {error}'**
  String dbErrorLoadingClients(String error);

  /// No description provided for @dbConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get dbConnecting;

  /// No description provided for @dbConnectAndLaunch.
  ///
  /// In en, this message translates to:
  /// **'Connect & Launch'**
  String get dbConnectAndLaunch;

  /// No description provided for @dbSaveAsProfileLabel.
  ///
  /// In en, this message translates to:
  /// **'Save as Profile'**
  String get dbSaveAsProfileLabel;

  /// No description provided for @dbProfileNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Profile Name'**
  String get dbProfileNameLabel;

  /// No description provided for @dbProfileNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., Production MySQL'**
  String get dbProfileNameHint;

  /// No description provided for @dbNoSavedProfiles.
  ///
  /// In en, this message translates to:
  /// **'No saved profiles'**
  String get dbNoSavedProfiles;

  /// No description provided for @dbNoSavedProfilesHint.
  ///
  /// In en, this message translates to:
  /// **'Create a connection and save it as a profile for quick access'**
  String get dbNoSavedProfilesHint;

  /// No description provided for @dbDeleteProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Profile'**
  String get dbDeleteProfileTitle;

  /// No description provided for @dbDeleteProfileConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"?'**
  String dbDeleteProfileConfirm(String name);

  /// No description provided for @dbTypePortLabel.
  ///
  /// In en, this message translates to:
  /// **'{dbType} (Port {port})'**
  String dbTypePortLabel(String dbType, int port);

  /// No description provided for @dbDatabaseLabel.
  ///
  /// In en, this message translates to:
  /// **'Database: {name}'**
  String dbDatabaseLabel(String name);

  /// No description provided for @dbClientLabel.
  ///
  /// In en, this message translates to:
  /// **'Client: {clientName}'**
  String dbClientLabel(String clientName);

  /// No description provided for @dbDeleteProfileTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete profile'**
  String get dbDeleteProfileTooltip;

  /// No description provided for @winCredTitle.
  ///
  /// In en, this message translates to:
  /// **'Windows Password'**
  String get winCredTitle;

  /// No description provided for @winCredGeneratePasswordTab.
  ///
  /// In en, this message translates to:
  /// **'Generate Password'**
  String get winCredGeneratePasswordTab;

  /// No description provided for @winCredStoredCredentialsTab.
  ///
  /// In en, this message translates to:
  /// **'Stored Credentials'**
  String get winCredStoredCredentialsTab;

  /// No description provided for @winCredInfoBox.
  ///
  /// In en, this message translates to:
  /// **'Generate a new Windows password or reset an existing one. The password will be stored securely in your system keyring.'**
  String get winCredInfoBox;

  /// No description provided for @commonUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get commonUsernameLabel;

  /// No description provided for @winCredUsernameHint.
  ///
  /// In en, this message translates to:
  /// **'Windows username (e.g., Administrator)'**
  String get winCredUsernameHint;

  /// No description provided for @winCredEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get winCredEmailLabel;

  /// No description provided for @winCredEmailHint.
  ///
  /// In en, this message translates to:
  /// **'Your email address (for GCP tracking)'**
  String get winCredEmailHint;

  /// No description provided for @winCredGenerateNew.
  ///
  /// In en, this message translates to:
  /// **'Generate New'**
  String get winCredGenerateNew;

  /// No description provided for @winCredResetPassword.
  ///
  /// In en, this message translates to:
  /// **'Reset Password'**
  String get winCredResetPassword;

  /// No description provided for @winCredWaitingForAgent.
  ///
  /// In en, this message translates to:
  /// **'Waiting for Windows guest agent response…'**
  String get winCredWaitingForAgent;

  /// No description provided for @winCredMayTake60s.
  ///
  /// In en, this message translates to:
  /// **'This may take up to 60 seconds'**
  String get winCredMayTake60s;

  /// No description provided for @winCredGeneratedCredential.
  ///
  /// In en, this message translates to:
  /// **'Generated Credential'**
  String get winCredGeneratedCredential;

  /// No description provided for @winCredNoStoredCredentials.
  ///
  /// In en, this message translates to:
  /// **'No stored credentials'**
  String get winCredNoStoredCredentials;

  /// No description provided for @winCredNoStoredCredentialsHint.
  ///
  /// In en, this message translates to:
  /// **'Generate a password for a Windows VM to store it here'**
  String get winCredNoStoredCredentialsHint;

  /// No description provided for @winCredClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear All'**
  String get winCredClearAll;

  /// No description provided for @winCredUsernameField.
  ///
  /// In en, this message translates to:
  /// **'Username: '**
  String get winCredUsernameField;

  /// No description provided for @winCredPasswordField.
  ///
  /// In en, this message translates to:
  /// **'Password: '**
  String get winCredPasswordField;

  /// No description provided for @winCredCopyUsernameTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy username'**
  String get winCredCopyUsernameTooltip;

  /// No description provided for @winCredCopyPasswordTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy password'**
  String get winCredCopyPasswordTooltip;

  /// No description provided for @winCredHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get winCredHidePassword;

  /// No description provided for @winCredShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get winCredShowPassword;

  /// No description provided for @commonCurrentChip.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get commonCurrentChip;

  /// No description provided for @commonPleaseEnterUsername.
  ///
  /// In en, this message translates to:
  /// **'Please enter a username'**
  String get commonPleaseEnterUsername;

  /// No description provided for @winCredPasswordWord.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get winCredPasswordWord;

  /// No description provided for @winCredCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'{label} copied to clipboard'**
  String winCredCopiedToClipboard(String label);

  /// No description provided for @winCredCopiedToClipboardSensitive.
  ///
  /// In en, this message translates to:
  /// **'{label} copied to clipboard (clears in 30s)'**
  String winCredCopiedToClipboardSensitive(String label);

  /// No description provided for @winCredDeleteCredentialTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Credential'**
  String get winCredDeleteCredentialTitle;

  /// No description provided for @winCredDeleteCredentialConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete the stored credential for {username}@{instanceName}?'**
  String winCredDeleteCredentialConfirm(String username, String instanceName);

  /// No description provided for @winCredClearAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear All Credentials'**
  String get winCredClearAllTitle;

  /// No description provided for @winCredClearAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete ALL stored Windows credentials? This action cannot be undone.'**
  String get winCredClearAllConfirm;

  /// No description provided for @sshfsDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Mount Remote Filesystem'**
  String get sshfsDialogTitle;

  /// No description provided for @sshfsUnavailableDefaultIssue.
  ///
  /// In en, this message translates to:
  /// **'SSHFS is not available'**
  String get sshfsUnavailableDefaultIssue;

  /// No description provided for @sshfsMountAction.
  ///
  /// In en, this message translates to:
  /// **'Mount'**
  String get sshfsMountAction;

  /// No description provided for @sshfsActiveMountsTab.
  ///
  /// In en, this message translates to:
  /// **'Active Mounts'**
  String get sshfsActiveMountsTab;

  /// No description provided for @sshfsNotAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'SSHFS Not Available'**
  String get sshfsNotAvailableTitle;

  /// No description provided for @sshfsMountInfoText.
  ///
  /// In en, this message translates to:
  /// **'Mount a remote directory from {instanceName} to your local filesystem. The tunnel on port {port} will be used for the connection.'**
  String sshfsMountInfoText(String instanceName, int port);

  /// No description provided for @sshfsUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH Username'**
  String get sshfsUsernameLabel;

  /// No description provided for @sshfsUsernameHint.
  ///
  /// In en, this message translates to:
  /// **'Username on the remote VM'**
  String get sshfsUsernameHint;

  /// No description provided for @sshfsRemotePathLabel.
  ///
  /// In en, this message translates to:
  /// **'Remote Path'**
  String get sshfsRemotePathLabel;

  /// No description provided for @sshfsLocalMountPointLabel.
  ///
  /// In en, this message translates to:
  /// **'Local Mount Point'**
  String get sshfsLocalMountPointLabel;

  /// No description provided for @sshfsResetToDefaultTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get sshfsResetToDefaultTooltip;

  /// No description provided for @sshfsMountOptionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Mount Options'**
  String get sshfsMountOptionsTitle;

  /// No description provided for @sshfsReadOnlyOption.
  ///
  /// In en, this message translates to:
  /// **'Read Only'**
  String get sshfsReadOnlyOption;

  /// No description provided for @sshfsCacheOption.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get sshfsCacheOption;

  /// No description provided for @sshfsCompressionOption.
  ///
  /// In en, this message translates to:
  /// **'Compression'**
  String get sshfsCompressionOption;

  /// No description provided for @sshfsAutoReconnectOption.
  ///
  /// In en, this message translates to:
  /// **'Auto-Reconnect'**
  String get sshfsAutoReconnectOption;

  /// No description provided for @sshfsMountingButton.
  ///
  /// In en, this message translates to:
  /// **'Mounting…'**
  String get sshfsMountingButton;

  /// No description provided for @sshfsNoActiveMountsTitle.
  ///
  /// In en, this message translates to:
  /// **'No active mounts'**
  String get sshfsNoActiveMountsTitle;

  /// No description provided for @sshfsNoActiveMountsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mount a remote directory to see it here'**
  String get sshfsNoActiveMountsSubtitle;

  /// No description provided for @sshfsActiveMountsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} active mounts'**
  String sshfsActiveMountsCount(int count);

  /// No description provided for @sshfsUnmountAllButton.
  ///
  /// In en, this message translates to:
  /// **'Unmount All'**
  String get sshfsUnmountAllButton;

  /// No description provided for @sshfsThisInstance.
  ///
  /// In en, this message translates to:
  /// **'This instance ({instanceName})'**
  String sshfsThisInstance(String instanceName);

  /// No description provided for @sshfsInfoProject.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get sshfsInfoProject;

  /// No description provided for @sshfsInfoZone.
  ///
  /// In en, this message translates to:
  /// **'Zone'**
  String get sshfsInfoZone;

  /// No description provided for @sshfsInfoLocalMount.
  ///
  /// In en, this message translates to:
  /// **'Local Mount'**
  String get sshfsInfoLocalMount;

  /// No description provided for @sshfsInfoTunnelPort.
  ///
  /// In en, this message translates to:
  /// **'Tunnel Port'**
  String get sshfsInfoTunnelPort;

  /// No description provided for @sshfsOpenButton.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get sshfsOpenButton;

  /// No description provided for @sshfsUnmountButton.
  ///
  /// In en, this message translates to:
  /// **'Unmount'**
  String get sshfsUnmountButton;

  /// No description provided for @sshfsRemotePathRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a remote path'**
  String get sshfsRemotePathRequired;

  /// No description provided for @sshfsLocalPathRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a local mount point'**
  String get sshfsLocalPathRequired;

  /// No description provided for @sshfsUnmountAllConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to unmount all SSHFS mounts?'**
  String get sshfsUnmountAllConfirmMessage;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearanceTitle;

  /// No description provided for @settingsAutoRefreshTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-Refresh'**
  String get settingsAutoRefreshTitle;

  /// No description provided for @settingsEnableAutoRefresh.
  ///
  /// In en, this message translates to:
  /// **'Enable Auto-Refresh'**
  String get settingsEnableAutoRefresh;

  /// No description provided for @settingsAutoRefreshSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Automatically refresh instance list'**
  String get settingsAutoRefreshSubtitle;

  /// No description provided for @settingsRefreshIntervalLabel.
  ///
  /// In en, this message translates to:
  /// **'Refresh Interval'**
  String get settingsRefreshIntervalLabel;

  /// No description provided for @settingsUpdateEverySeconds.
  ///
  /// In en, this message translates to:
  /// **'Update every {seconds} seconds'**
  String settingsUpdateEverySeconds(int seconds);

  /// No description provided for @settingsIntervalDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get settingsIntervalDisabled;

  /// No description provided for @settingsInterval10s.
  ///
  /// In en, this message translates to:
  /// **'10 seconds'**
  String get settingsInterval10s;

  /// No description provided for @settingsInterval30s.
  ///
  /// In en, this message translates to:
  /// **'30 seconds'**
  String get settingsInterval30s;

  /// No description provided for @settingsInterval60s.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get settingsInterval60s;

  /// No description provided for @settingsInterval120s.
  ///
  /// In en, this message translates to:
  /// **'2 minutes'**
  String get settingsInterval120s;

  /// No description provided for @settingsInterval300s.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get settingsInterval300s;

  /// No description provided for @settingsCustomInterval.
  ///
  /// In en, this message translates to:
  /// **'Custom Interval'**
  String get settingsCustomInterval;

  /// No description provided for @settingsCustomIntervalSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Specify a custom interval (5-600s)'**
  String get settingsCustomIntervalSubtitle;

  /// No description provided for @settingsSecondsLabel.
  ///
  /// In en, this message translates to:
  /// **'Seconds'**
  String get settingsSecondsLabel;

  /// No description provided for @settingsSecondsHelper.
  ///
  /// In en, this message translates to:
  /// **'Min: 5, Max: 600'**
  String get settingsSecondsHelper;

  /// No description provided for @settingsInvalidNumber.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid number'**
  String get settingsInvalidNumber;

  /// No description provided for @settingsIntervalRange.
  ///
  /// In en, this message translates to:
  /// **'Interval must be between 5 and 600 seconds'**
  String get settingsIntervalRange;

  /// No description provided for @settingsRefreshIntervalSet.
  ///
  /// In en, this message translates to:
  /// **'Refresh interval set to {seconds} seconds'**
  String settingsRefreshIntervalSet(int seconds);

  /// No description provided for @settingsSetButton.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get settingsSetButton;

  /// No description provided for @settingsNotificationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotificationsTitle;

  /// No description provided for @settingsEnableNotifications.
  ///
  /// In en, this message translates to:
  /// **'Enable Desktop Notifications'**
  String get settingsEnableNotifications;

  /// No description provided for @settingsNotificationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Get notified about VM state changes and events'**
  String get settingsNotificationsSubtitle;

  /// No description provided for @settingsNotifiedAboutLabel.
  ///
  /// In en, this message translates to:
  /// **'You will be notified about:'**
  String get settingsNotifiedAboutLabel;

  /// No description provided for @settingsNotifyVmState.
  ///
  /// In en, this message translates to:
  /// **'• VM state changes (RUNNING ↔ STOPPED)'**
  String get settingsNotifyVmState;

  /// No description provided for @settingsNotifyIapFailures.
  ///
  /// In en, this message translates to:
  /// **'• IAP tunnel failures'**
  String get settingsNotifyIapFailures;

  /// No description provided for @settingsNotifyLifecycleResults.
  ///
  /// In en, this message translates to:
  /// **'• Lifecycle operation results (start/stop/reset)'**
  String get settingsNotifyLifecycleResults;

  /// No description provided for @settingsSystemDependenciesTitle.
  ///
  /// In en, this message translates to:
  /// **'System Dependencies'**
  String get settingsSystemDependenciesTitle;

  /// No description provided for @settingsRdpClientTitle.
  ///
  /// In en, this message translates to:
  /// **'RDP Client'**
  String get settingsRdpClientTitle;

  /// No description provided for @settingsVncClientTitle.
  ///
  /// In en, this message translates to:
  /// **'VNC Client'**
  String get settingsVncClientTitle;

  /// No description provided for @settingsAboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutTitle;

  /// No description provided for @settingsEditionsDescription.
  ///
  /// In en, this message translates to:
  /// **'Editions follow a half-year cadence (YYH#). 26H2 covers the second half of 2026. Builds deliver continuous fixes between editions.'**
  String get settingsEditionsDescription;

  /// No description provided for @settingsSupportDevelopmentTitle.
  ///
  /// In en, this message translates to:
  /// **'Support Development'**
  String get settingsSupportDevelopmentTitle;

  /// No description provided for @settingsSupportMessage.
  ///
  /// In en, this message translates to:
  /// **'If you find this tool useful, consider supporting its development!'**
  String get settingsSupportMessage;

  /// No description provided for @settingsChooseThemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Choose your preferred theme:'**
  String get settingsChooseThemeLabel;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System (Auto)'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLightDesc.
  ///
  /// In en, this message translates to:
  /// **'Always use light theme'**
  String get settingsThemeLightDesc;

  /// No description provided for @settingsThemeDarkDesc.
  ///
  /// In en, this message translates to:
  /// **'Always use dark theme'**
  String get settingsThemeDarkDesc;

  /// No description provided for @settingsThemeSystemDesc.
  ///
  /// In en, this message translates to:
  /// **'Follow your system preference'**
  String get settingsThemeSystemDesc;

  /// No description provided for @settingsNoRdpClients.
  ///
  /// In en, this message translates to:
  /// **'No RDP clients detected. Please install one of: Remmina, FreeRDP, KRDC, or GNOME Connections.'**
  String get settingsNoRdpClients;

  /// No description provided for @settingsSelectRdpClient.
  ///
  /// In en, this message translates to:
  /// **'Select your preferred RDP client:'**
  String get settingsSelectRdpClient;

  /// No description provided for @settingsNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Not Installed'**
  String get settingsNotInstalled;

  /// No description provided for @settingsInstallClientHint.
  ///
  /// In en, this message translates to:
  /// **'Install this client to use it'**
  String get settingsInstallClientHint;

  /// No description provided for @settingsRdpClientSet.
  ///
  /// In en, this message translates to:
  /// **'RDP client set to {name}'**
  String settingsRdpClientSet(String name);

  /// No description provided for @settingsClientTip.
  ///
  /// In en, this message translates to:
  /// **'💡 Tip: If your preferred client is unavailable, the app will automatically try other installed clients.'**
  String get settingsClientTip;

  /// No description provided for @settingsErrorDetectingRdp.
  ///
  /// In en, this message translates to:
  /// **'Error detecting RDP clients: {error}'**
  String settingsErrorDetectingRdp(String error);

  /// No description provided for @settingsNoVncClients.
  ///
  /// In en, this message translates to:
  /// **'No VNC clients detected. Please install one of: Remmina, TigerVNC, KRDC, or Vinagre.'**
  String get settingsNoVncClients;

  /// No description provided for @settingsSelectVncClient.
  ///
  /// In en, this message translates to:
  /// **'Select your preferred VNC client:'**
  String get settingsSelectVncClient;

  /// No description provided for @settingsVncClientSet.
  ///
  /// In en, this message translates to:
  /// **'VNC client set to {name}'**
  String settingsVncClientSet(String name);

  /// No description provided for @settingsErrorDetectingVnc.
  ///
  /// In en, this message translates to:
  /// **'Error detecting VNC clients: {error}'**
  String settingsErrorDetectingVnc(String error);

  /// No description provided for @settingsDependencyStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Status of tools used by the application:'**
  String get settingsDependencyStatusLabel;

  /// No description provided for @settingsDepRdpClients.
  ///
  /// In en, this message translates to:
  /// **'RDP Clients'**
  String get settingsDepRdpClients;

  /// No description provided for @settingsDepVncClients.
  ///
  /// In en, this message translates to:
  /// **'VNC Clients'**
  String get settingsDepVncClients;

  /// No description provided for @settingsDepSqlClients.
  ///
  /// In en, this message translates to:
  /// **'SQL Clients'**
  String get settingsDepSqlClients;

  /// No description provided for @settingsRequiredBadge.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get settingsRequiredBadge;

  /// No description provided for @settingsInstalledCount.
  ///
  /// In en, this message translates to:
  /// **'{count} Installed'**
  String settingsInstalledCount(int count);

  /// No description provided for @settingsInstalledLabel.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get settingsInstalledLabel;

  /// No description provided for @settingsNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not Found'**
  String get settingsNotFound;

  /// No description provided for @settingsErrorCheckingDeps.
  ///
  /// In en, this message translates to:
  /// **'Error checking dependencies: {error}'**
  String settingsErrorCheckingDeps(String error);

  /// No description provided for @settingsRdpDescRemmina.
  ///
  /// In en, this message translates to:
  /// **'Feature-rich, supports config files'**
  String get settingsRdpDescRemmina;

  /// No description provided for @settingsRdpDescFreeRdp.
  ///
  /// In en, this message translates to:
  /// **'CLI-based, widely available'**
  String get settingsRdpDescFreeRdp;

  /// No description provided for @settingsRdpDescKrdc.
  ///
  /// In en, this message translates to:
  /// **'KDE default remote desktop client'**
  String get settingsRdpDescKrdc;

  /// No description provided for @settingsRdpDescGnome.
  ///
  /// In en, this message translates to:
  /// **'Modern GNOME remote desktop app'**
  String get settingsRdpDescGnome;

  /// No description provided for @settingsRdpDescMstsc.
  ///
  /// In en, this message translates to:
  /// **'Windows native remote desktop client'**
  String get settingsRdpDescMstsc;

  /// No description provided for @settingsVncDescRemmina.
  ///
  /// In en, this message translates to:
  /// **'Feature-rich, supports both RDP and VNC'**
  String get settingsVncDescRemmina;

  /// No description provided for @settingsVncDescTigerVnc.
  ///
  /// In en, this message translates to:
  /// **'High-performance VNC viewer'**
  String get settingsVncDescTigerVnc;

  /// No description provided for @settingsVncDescKrdc.
  ///
  /// In en, this message translates to:
  /// **'KDE VNC and RDP client'**
  String get settingsVncDescKrdc;

  /// No description provided for @settingsVncDescVinagre.
  ///
  /// In en, this message translates to:
  /// **'GNOME VNC viewer'**
  String get settingsVncDescVinagre;

  /// No description provided for @commonEditionLabel.
  ///
  /// In en, this message translates to:
  /// **'Edition {version}'**
  String commonEditionLabel(String version);

  /// No description provided for @commonBuildLabel.
  ///
  /// In en, this message translates to:
  /// **'Build {build}'**
  String commonBuildLabel(String build);

  /// No description provided for @manualInstanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Instance Manually'**
  String get manualInstanceTitle;

  /// No description provided for @manualInstanceDescription.
  ///
  /// In en, this message translates to:
  /// **'Add an instance when you have view permission but not list permission.'**
  String get manualInstanceDescription;

  /// No description provided for @manualInstanceProjectIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Project ID'**
  String get manualInstanceProjectIdLabel;

  /// No description provided for @manualInstanceProjectIdHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., my-project-123'**
  String get manualInstanceProjectIdHint;

  /// No description provided for @manualInstanceProjectIdRequired.
  ///
  /// In en, this message translates to:
  /// **'Project ID is required'**
  String get manualInstanceProjectIdRequired;

  /// No description provided for @manualInstanceZoneLabel.
  ///
  /// In en, this message translates to:
  /// **'Zone'**
  String get manualInstanceZoneLabel;

  /// No description provided for @manualInstanceZoneHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., us-central1-a'**
  String get manualInstanceZoneHint;

  /// No description provided for @manualInstanceZoneRequired.
  ///
  /// In en, this message translates to:
  /// **'Zone is required'**
  String get manualInstanceZoneRequired;

  /// No description provided for @manualInstanceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Instance Name'**
  String get manualInstanceNameLabel;

  /// No description provided for @manualInstanceNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., my-vm-instance'**
  String get manualInstanceNameHint;

  /// No description provided for @manualInstanceNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Instance name is required'**
  String get manualInstanceNameRequired;

  /// No description provided for @manualInstanceSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching…'**
  String get manualInstanceSearching;

  /// No description provided for @manualInstanceSearchButton.
  ///
  /// In en, this message translates to:
  /// **'Search Instance'**
  String get manualInstanceSearchButton;

  /// No description provided for @manualInstanceFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'Instance Found!'**
  String get manualInstanceFoundTitle;

  /// No description provided for @manualInstanceViaMethod.
  ///
  /// In en, this message translates to:
  /// **'via {method}'**
  String manualInstanceViaMethod(String method);

  /// No description provided for @manualInstanceFieldName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get manualInstanceFieldName;

  /// No description provided for @manualInstanceFieldStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get manualInstanceFieldStatus;

  /// No description provided for @manualInstanceFieldMachineType.
  ///
  /// In en, this message translates to:
  /// **'Machine Type'**
  String get manualInstanceFieldMachineType;

  /// No description provided for @manualInstanceAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add Instance'**
  String get manualInstanceAddButton;

  /// No description provided for @snapshotDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'VM Snapshots'**
  String get snapshotDialogTitle;

  /// No description provided for @snapshotTabList.
  ///
  /// In en, this message translates to:
  /// **'Snapshots'**
  String get snapshotTabList;

  /// No description provided for @snapshotTabListWithCount.
  ///
  /// In en, this message translates to:
  /// **'Snapshots ({count})'**
  String snapshotTabListWithCount(int count);

  /// No description provided for @snapshotTabCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get snapshotTabCreate;

  /// No description provided for @snapshotEmptyList.
  ///
  /// In en, this message translates to:
  /// **'No snapshots for this VM'**
  String get snapshotEmptyList;

  /// No description provided for @snapshotMetaCreated.
  ///
  /// In en, this message translates to:
  /// **'Created: {date}'**
  String snapshotMetaCreated(String date);

  /// No description provided for @snapshotMetaDisk.
  ///
  /// In en, this message translates to:
  /// **'Disk: {size}'**
  String snapshotMetaDisk(String size);

  /// No description provided for @snapshotMetaStored.
  ///
  /// In en, this message translates to:
  /// **'Stored: {size}'**
  String snapshotMetaStored(String size);

  /// No description provided for @snapshotMetaSource.
  ///
  /// In en, this message translates to:
  /// **'Source: {disk}'**
  String snapshotMetaSource(String disk);

  /// No description provided for @snapshotRestoreDiskButton.
  ///
  /// In en, this message translates to:
  /// **'Restore disk'**
  String get snapshotRestoreDiskButton;

  /// No description provided for @snapshotDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete snapshot'**
  String get snapshotDeleteTitle;

  /// No description provided for @snapshotDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Permanently delete this snapshot?'**
  String get snapshotDeleteConfirm;

  /// No description provided for @snapshotDeletedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Snapshot \"{name}\" deleted.'**
  String snapshotDeletedSnackbar(String name);

  /// No description provided for @snapshotDeleteError.
  ///
  /// In en, this message translates to:
  /// **'Error deleting: {error}'**
  String snapshotDeleteError(String error);

  /// No description provided for @snapshotRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore from snapshot'**
  String get snapshotRestoreTitle;

  /// No description provided for @snapshotRestoreDescription.
  ///
  /// In en, this message translates to:
  /// **'A new disk will be created from snapshot \"{name}\".'**
  String snapshotRestoreDescription(String name);

  /// No description provided for @snapshotRestoreVmNote.
  ///
  /// In en, this message translates to:
  /// **'The VM is not modified automatically — you will get the gcloud commands to do the swap.'**
  String get snapshotRestoreVmNote;

  /// No description provided for @snapshotNewDiskNameLabel.
  ///
  /// In en, this message translates to:
  /// **'New disk name'**
  String get snapshotNewDiskNameLabel;

  /// No description provided for @snapshotCreateDiskButton.
  ///
  /// In en, this message translates to:
  /// **'Create disk'**
  String get snapshotCreateDiskButton;

  /// No description provided for @snapshotCreatingDiskFromSnapshot.
  ///
  /// In en, this message translates to:
  /// **'Creating disk from snapshot…'**
  String get snapshotCreatingDiskFromSnapshot;

  /// No description provided for @snapshotCreateDiskError.
  ///
  /// In en, this message translates to:
  /// **'Error creating disk: {error}'**
  String snapshotCreateDiskError(String error);

  /// No description provided for @snapshotDiskCreatedTitle.
  ///
  /// In en, this message translates to:
  /// **'Disk created from snapshot'**
  String get snapshotDiskCreatedTitle;

  /// No description provided for @snapshotDiskCreatedMessage.
  ///
  /// In en, this message translates to:
  /// **'Disk \"{name}\" created in {zone}.'**
  String snapshotDiskCreatedMessage(String name, String zone);

  /// No description provided for @snapshotRestoreCommandsIntro.
  ///
  /// In en, this message translates to:
  /// **'To restore the VM, run these commands:'**
  String get snapshotRestoreCommandsIntro;

  /// No description provided for @snapshotCopyCommandsButton.
  ///
  /// In en, this message translates to:
  /// **'Copy commands'**
  String get snapshotCopyCommandsButton;

  /// No description provided for @snapshotCommandsCopiedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Commands copied to clipboard'**
  String get snapshotCommandsCopiedSnackbar;

  /// No description provided for @snapshotNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get snapshotNameRequired;

  /// No description provided for @snapshotNameMaxLength.
  ///
  /// In en, this message translates to:
  /// **'Maximum 63 characters'**
  String get snapshotNameMaxLength;

  /// No description provided for @snapshotNameMustStartLowercase.
  ///
  /// In en, this message translates to:
  /// **'Must start with a lowercase letter'**
  String get snapshotNameMustStartLowercase;

  /// No description provided for @snapshotNameInvalidChars.
  ///
  /// In en, this message translates to:
  /// **'Only lowercase letters, digits and hyphens'**
  String get snapshotNameInvalidChars;

  /// No description provided for @snapshotNameNoTrailingHyphen.
  ///
  /// In en, this message translates to:
  /// **'Cannot end with a hyphen'**
  String get snapshotNameNoTrailingHyphen;

  /// No description provided for @snapshotCreatedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Snapshot \"{name}\" created. It may take a few minutes to appear as READY.'**
  String snapshotCreatedSnackbar(String name);

  /// No description provided for @snapshotCreateError.
  ///
  /// In en, this message translates to:
  /// **'Error creating snapshot: {error}'**
  String snapshotCreateError(String error);

  /// No description provided for @snapshotNameFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Snapshot name *'**
  String get snapshotNameFieldLabel;

  /// No description provided for @snapshotNameFieldHelper.
  ///
  /// In en, this message translates to:
  /// **'Only lowercase letters, digits and hyphens. Max 63 chars.'**
  String get snapshotNameFieldHelper;

  /// No description provided for @snapshotDescriptionFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get snapshotDescriptionFieldLabel;

  /// No description provided for @snapshotCreateButton.
  ///
  /// In en, this message translates to:
  /// **'Create Snapshot'**
  String get snapshotCreateButton;

  /// No description provided for @snapshotCreateDurationNote.
  ///
  /// In en, this message translates to:
  /// **'Snapshots may take 2–5 minutes to complete.'**
  String get snapshotCreateDurationNote;

  /// No description provided for @snapshotCreatingOverlay.
  ///
  /// In en, this message translates to:
  /// **'Creating snapshot…\nThis may take several minutes.'**
  String get snapshotCreatingOverlay;

  /// No description provided for @snapshotDetectingBootDisk.
  ///
  /// In en, this message translates to:
  /// **'Detecting boot disk…'**
  String get snapshotDetectingBootDisk;

  /// No description provided for @snapshotBootDiskDetectError.
  ///
  /// In en, this message translates to:
  /// **'Could not detect boot disk: {error}'**
  String snapshotBootDiskDetectError(String error);

  /// No description provided for @snapshotBootDiskLabel.
  ///
  /// In en, this message translates to:
  /// **'Boot disk:'**
  String get snapshotBootDiskLabel;

  /// No description provided for @clientTestTitle.
  ///
  /// In en, this message translates to:
  /// **'Client Libraries Testing'**
  String get clientTestTitle;

  /// No description provided for @clientTestTabApi.
  ///
  /// In en, this message translates to:
  /// **'API Testing'**
  String get clientTestTabApi;

  /// No description provided for @clientTestTabLifecycle.
  ///
  /// In en, this message translates to:
  /// **'Lifecycle Ops'**
  String get clientTestTabLifecycle;

  /// No description provided for @clientTestTabPerformance.
  ///
  /// In en, this message translates to:
  /// **'Performance'**
  String get clientTestTabPerformance;

  /// No description provided for @clientTestRunAllTooltip.
  ///
  /// In en, this message translates to:
  /// **'Run All Tests'**
  String get clientTestRunAllTooltip;

  /// No description provided for @clientTestRunningAll.
  ///
  /// In en, this message translates to:
  /// **'Running all tests…'**
  String get clientTestRunningAll;

  /// No description provided for @clientTestLabelClientLibs.
  ///
  /// In en, this message translates to:
  /// **'Client Libraries'**
  String get clientTestLabelClientLibs;

  /// No description provided for @clientTestHeaderTitle.
  ///
  /// In en, this message translates to:
  /// **'Google Cloud Client Libraries Integration'**
  String get clientTestHeaderTitle;

  /// No description provided for @clientTestHeaderDescription.
  ///
  /// In en, this message translates to:
  /// **'Test and compare the new Client Libraries integration with traditional gcloud CLI. Client Libraries use direct REST API calls for better performance.'**
  String get clientTestHeaderDescription;

  /// No description provided for @clientTestAuthTitle.
  ///
  /// In en, this message translates to:
  /// **'Authentication Test'**
  String get clientTestAuthTitle;

  /// No description provided for @clientTestRetryAuth.
  ///
  /// In en, this message translates to:
  /// **'Retry Authentication'**
  String get clientTestRetryAuth;

  /// No description provided for @clientTestProjectsComparisonTitle.
  ///
  /// In en, this message translates to:
  /// **'Projects Listing Comparison'**
  String get clientTestProjectsComparisonTitle;

  /// No description provided for @clientTestNoProjectsFound.
  ///
  /// In en, this message translates to:
  /// **'No projects found'**
  String get clientTestNoProjectsFound;

  /// No description provided for @clientTestFoundProjectsCount.
  ///
  /// In en, this message translates to:
  /// **'Found {count} projects'**
  String clientTestFoundProjectsCount(int count);

  /// No description provided for @clientTestAndMoreCount.
  ///
  /// In en, this message translates to:
  /// **'… and {count} more'**
  String clientTestAndMoreCount(int count);

  /// No description provided for @clientTestAuthenticateFirst.
  ///
  /// In en, this message translates to:
  /// **'Please authenticate with gcloud first'**
  String get clientTestAuthenticateFirst;

  /// No description provided for @clientTestPerfBenchmarkTitle.
  ///
  /// In en, this message translates to:
  /// **'Performance Benchmark'**
  String get clientTestPerfBenchmarkTitle;

  /// No description provided for @clientTestBenchmarkDescription.
  ///
  /// In en, this message translates to:
  /// **'Measures the time to list all projects using both methods.'**
  String get clientTestBenchmarkDescription;

  /// No description provided for @clientTestRunningBenchmark.
  ///
  /// In en, this message translates to:
  /// **'Running benchmark…'**
  String get clientTestRunningBenchmark;

  /// No description provided for @clientTestRunBenchmarkButton.
  ///
  /// In en, this message translates to:
  /// **'Run Benchmark'**
  String get clientTestRunBenchmarkButton;

  /// No description provided for @clientTestComputeInstancesTitle.
  ///
  /// In en, this message translates to:
  /// **'Compute Engine Instances'**
  String get clientTestComputeInstancesTitle;

  /// No description provided for @clientTestSelectProjectHint.
  ///
  /// In en, this message translates to:
  /// **'Please select a project from the main dashboard to test instance listing.'**
  String get clientTestSelectProjectHint;

  /// No description provided for @clientTestNoInstancesFound.
  ///
  /// In en, this message translates to:
  /// **'No instances found'**
  String get clientTestNoInstancesFound;

  /// No description provided for @clientTestFoundInstancesCount.
  ///
  /// In en, this message translates to:
  /// **'Found {count} instances'**
  String clientTestFoundInstancesCount(int count);

  /// No description provided for @clientTestRefreshBothButton.
  ///
  /// In en, this message translates to:
  /// **'Refresh Both'**
  String get clientTestRefreshBothButton;

  /// No description provided for @clientTestLifecycleTitle.
  ///
  /// In en, this message translates to:
  /// **'Lifecycle Operations Testing'**
  String get clientTestLifecycleTitle;

  /// No description provided for @clientTestLifecycleDescription.
  ///
  /// In en, this message translates to:
  /// **'Test VM lifecycle operations (start/stop/reset) using both CLI and Client Libraries. Select an instance from the main dashboard to begin testing.'**
  String get clientTestLifecycleDescription;

  /// No description provided for @clientTestSelectProjectInstanceHint.
  ///
  /// In en, this message translates to:
  /// **'Please select a project and instance from the main dashboard'**
  String get clientTestSelectProjectInstanceHint;

  /// No description provided for @clientTestInstanceStatusZone.
  ///
  /// In en, this message translates to:
  /// **'Status: {status} • Zone: {zone}'**
  String clientTestInstanceStatusZone(String status, String zone);

  /// No description provided for @clientTestCurrentlyTestingWith.
  ///
  /// In en, this message translates to:
  /// **'Currently testing with: {method}'**
  String clientTestCurrentlyTestingWith(String method);

  /// No description provided for @clientTestTestOperationsLabel.
  ///
  /// In en, this message translates to:
  /// **'Test Operations:'**
  String get clientTestTestOperationsLabel;

  /// No description provided for @clientTestStartingInstance.
  ///
  /// In en, this message translates to:
  /// **'Starting instance…'**
  String get clientTestStartingInstance;

  /// No description provided for @clientTestInstanceStartedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Instance started successfully!'**
  String get clientTestInstanceStartedSuccess;

  /// No description provided for @clientTestStartInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Start Instance'**
  String get clientTestStartInstanceButton;

  /// No description provided for @clientTestStoppingInstance.
  ///
  /// In en, this message translates to:
  /// **'Stopping instance…'**
  String get clientTestStoppingInstance;

  /// No description provided for @clientTestInstanceStoppedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Instance stopped successfully!'**
  String get clientTestInstanceStoppedSuccess;

  /// No description provided for @clientTestStopInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Stop Instance'**
  String get clientTestStopInstanceButton;

  /// No description provided for @clientTestResettingInstance.
  ///
  /// In en, this message translates to:
  /// **'Resetting instance…'**
  String get clientTestResettingInstance;

  /// No description provided for @clientTestInstanceResetSuccess.
  ///
  /// In en, this message translates to:
  /// **'Instance reset successfully!'**
  String get clientTestInstanceResetSuccess;

  /// No description provided for @clientTestResetInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Reset Instance'**
  String get clientTestResetInstanceButton;

  /// No description provided for @clientTestTestingTipsTitle.
  ///
  /// In en, this message translates to:
  /// **'Testing Tips'**
  String get clientTestTestingTipsTitle;

  /// No description provided for @clientTestTestingTipsBody.
  ///
  /// In en, this message translates to:
  /// **'• Switch the API method in the main dashboard AppBar to test both implementations\n• Operations take 30-120 seconds to complete\n• Watch the console for detailed timing information\n• Client Libraries should be slightly faster due to direct API calls'**
  String get clientTestTestingTipsBody;

  /// No description provided for @clientTestPerfStatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Performance Statistics'**
  String get clientTestPerfStatsTitle;

  /// No description provided for @clientTestPerfStatsDescription.
  ///
  /// In en, this message translates to:
  /// **'Aggregate performance data comparing gcloud CLI and Client Libraries. Run benchmarks from the API Testing tab to populate statistics.'**
  String get clientTestPerfStatsDescription;

  /// No description provided for @clientTestBenchmarkSummaryTitle.
  ///
  /// In en, this message translates to:
  /// **'Benchmark Results Summary'**
  String get clientTestBenchmarkSummaryTitle;

  /// No description provided for @clientTestMetricSpeedup.
  ///
  /// In en, this message translates to:
  /// **'Speedup'**
  String get clientTestMetricSpeedup;

  /// No description provided for @clientTestMetricImprovement.
  ///
  /// In en, this message translates to:
  /// **'Improvement'**
  String get clientTestMetricImprovement;

  /// No description provided for @clientTestRunBenchmarkHint.
  ///
  /// In en, this message translates to:
  /// **'Run benchmark from API Testing tab to see results'**
  String get clientTestRunBenchmarkHint;

  /// No description provided for @clientTestExpectedGainsTitle.
  ///
  /// In en, this message translates to:
  /// **'Expected Performance Gains'**
  String get clientTestExpectedGainsTitle;

  /// No description provided for @clientTestOpListProjects.
  ///
  /// In en, this message translates to:
  /// **'List Projects'**
  String get clientTestOpListProjects;

  /// No description provided for @clientTestOpListInstances.
  ///
  /// In en, this message translates to:
  /// **'List Instances'**
  String get clientTestOpListInstances;

  /// No description provided for @clientTestOpStartStopInstance.
  ///
  /// In en, this message translates to:
  /// **'Start/Stop Instance'**
  String get clientTestOpStartStopInstance;

  /// No description provided for @clientTestReasonListProjects.
  ///
  /// In en, this message translates to:
  /// **'Faster API calls, no process overhead'**
  String get clientTestReasonListProjects;

  /// No description provided for @clientTestReasonListInstances.
  ///
  /// In en, this message translates to:
  /// **'Direct REST API vs CLI JSON parsing'**
  String get clientTestReasonListInstances;

  /// No description provided for @clientTestReasonStartStop.
  ///
  /// In en, this message translates to:
  /// **'Reduced latency from direct API'**
  String get clientTestReasonStartStop;

  /// No description provided for @clientTestReasonReset.
  ///
  /// In en, this message translates to:
  /// **'Minimal overhead difference'**
  String get clientTestReasonReset;

  /// No description provided for @clientTestExpectedGainsFooter.
  ///
  /// In en, this message translates to:
  /// **'Client Libraries excel in high-frequency operations. The more API calls, the larger the cumulative time savings.'**
  String get clientTestExpectedGainsFooter;

  /// No description provided for @diagTitle.
  ///
  /// In en, this message translates to:
  /// **'VM Diagnostics'**
  String get diagTitle;

  /// No description provided for @diagSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{instanceName} ({zone})'**
  String diagSubtitle(String instanceName, String zone);

  /// No description provided for @diagTabSerialConsole.
  ///
  /// In en, this message translates to:
  /// **'Serial Console'**
  String get diagTabSerialConsole;

  /// No description provided for @diagTabDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagTabDiagnostics;

  /// No description provided for @diagTabAuditLogs.
  ///
  /// In en, this message translates to:
  /// **'Audit Logs'**
  String get diagTabAuditLogs;

  /// No description provided for @diagLogsExportedTo.
  ///
  /// In en, this message translates to:
  /// **'Logs exported to: {path}'**
  String diagLogsExportedTo(String path);

  /// No description provided for @diagOpenAction.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get diagOpenAction;

  /// No description provided for @diagExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String diagExportFailed(String error);

  /// No description provided for @diagPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Port: '**
  String get diagPortLabel;

  /// No description provided for @diagSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search logs…'**
  String get diagSearchHint;

  /// No description provided for @diagAutoScrollTooltip.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll'**
  String get diagAutoScrollTooltip;

  /// No description provided for @diagStopAutoRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop auto-refresh'**
  String get diagStopAutoRefreshTooltip;

  /// No description provided for @diagAutoRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Auto-refresh (5s)'**
  String get diagAutoRefreshTooltip;

  /// No description provided for @diagExportLogsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Export logs'**
  String get diagExportLogsTooltip;

  /// No description provided for @diagCopyToClipboardTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy to clipboard'**
  String get diagCopyToClipboardTooltip;

  /// No description provided for @diagCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get diagCopiedToClipboard;

  /// No description provided for @diagFetchedAt.
  ///
  /// In en, this message translates to:
  /// **'Fetched: {timestamp}'**
  String diagFetchedAt(String timestamp);

  /// No description provided for @diagLinesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} lines'**
  String diagLinesCount(int count);

  /// No description provided for @diagLinesCountFiltered.
  ///
  /// In en, this message translates to:
  /// **'{count} lines (filtered)'**
  String diagLinesCountFiltered(int count);

  /// No description provided for @diagSerialPortDisabledTitle.
  ///
  /// In en, this message translates to:
  /// **'Serial Port Logging Disabled'**
  String get diagSerialPortDisabledTitle;

  /// No description provided for @diagErrorLoadingSerialTitle.
  ///
  /// In en, this message translates to:
  /// **'Error Loading Serial Output'**
  String get diagErrorLoadingSerialTitle;

  /// No description provided for @diagCopyEnableCommandButton.
  ///
  /// In en, this message translates to:
  /// **'Copy Enable Command'**
  String get diagCopyEnableCommandButton;

  /// No description provided for @diagCommandCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Command copied to clipboard'**
  String get diagCommandCopiedToClipboard;

  /// No description provided for @diagNoData.
  ///
  /// In en, this message translates to:
  /// **'No data'**
  String get diagNoData;

  /// No description provided for @diagInstanceStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Instance Status'**
  String get diagInstanceStatusTitle;

  /// No description provided for @diagLabelStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get diagLabelStatus;

  /// No description provided for @diagLabelMachineType.
  ///
  /// In en, this message translates to:
  /// **'Machine Type'**
  String get diagLabelMachineType;

  /// No description provided for @diagLabelZone.
  ///
  /// In en, this message translates to:
  /// **'Zone'**
  String get diagLabelZone;

  /// No description provided for @diagLabelProject.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get diagLabelProject;

  /// No description provided for @diagLabelCreated.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get diagLabelCreated;

  /// No description provided for @diagLabelLastStarted.
  ///
  /// In en, this message translates to:
  /// **'Last Started'**
  String get diagLabelLastStarted;

  /// No description provided for @diagLabelLastStopped.
  ///
  /// In en, this message translates to:
  /// **'Last Stopped'**
  String get diagLabelLastStopped;

  /// No description provided for @diagGuestAgentTitle.
  ///
  /// In en, this message translates to:
  /// **'Guest Agent'**
  String get diagGuestAgentTitle;

  /// No description provided for @diagStatusReporting.
  ///
  /// In en, this message translates to:
  /// **'Reporting'**
  String get diagStatusReporting;

  /// No description provided for @diagStatusNotReporting.
  ///
  /// In en, this message translates to:
  /// **'Not Reporting'**
  String get diagStatusNotReporting;

  /// No description provided for @diagLabelOsType.
  ///
  /// In en, this message translates to:
  /// **'OS Type'**
  String get diagLabelOsType;

  /// No description provided for @diagLabelOsVersion.
  ///
  /// In en, this message translates to:
  /// **'OS Version'**
  String get diagLabelOsVersion;

  /// No description provided for @diagLabelLastHeartbeat.
  ///
  /// In en, this message translates to:
  /// **'Last Heartbeat'**
  String get diagLabelLastHeartbeat;

  /// No description provided for @diagGuestAgentWarning.
  ///
  /// In en, this message translates to:
  /// **'The guest agent may not be installed or running.'**
  String get diagGuestAgentWarning;

  /// No description provided for @diagNetworkInterfacesTitle.
  ///
  /// In en, this message translates to:
  /// **'Network Interfaces'**
  String get diagNetworkInterfacesTitle;

  /// No description provided for @diagInterfaceNumber.
  ///
  /// In en, this message translates to:
  /// **'Interface {number}'**
  String diagInterfaceNumber(int number);

  /// No description provided for @diagLabelNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get diagLabelNetwork;

  /// No description provided for @diagLabelSubnetwork.
  ///
  /// In en, this message translates to:
  /// **'Subnetwork'**
  String get diagLabelSubnetwork;

  /// No description provided for @diagLabelInternalIp.
  ///
  /// In en, this message translates to:
  /// **'Internal IP'**
  String get diagLabelInternalIp;

  /// No description provided for @diagLabelExternalIp.
  ///
  /// In en, this message translates to:
  /// **'External IP'**
  String get diagLabelExternalIp;

  /// No description provided for @diagValueNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get diagValueNone;

  /// No description provided for @diagLabelTier.
  ///
  /// In en, this message translates to:
  /// **'Tier'**
  String get diagLabelTier;

  /// No description provided for @diagDisksTitle.
  ///
  /// In en, this message translates to:
  /// **'Disks'**
  String get diagDisksTitle;

  /// No description provided for @diagBootChip.
  ///
  /// In en, this message translates to:
  /// **'Boot'**
  String get diagBootChip;

  /// No description provided for @diagLabelType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get diagLabelType;

  /// No description provided for @diagLabelSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get diagLabelSize;

  /// No description provided for @diagSizeGb.
  ///
  /// In en, this message translates to:
  /// **'{size} GB'**
  String diagSizeGb(int size);

  /// No description provided for @diagLabelMode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get diagLabelMode;

  /// No description provided for @diagLabelAutoDelete.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete'**
  String get diagLabelAutoDelete;

  /// No description provided for @diagLabelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Labels'**
  String get diagLabelsTitle;

  /// No description provided for @diagLabelKeyValue.
  ///
  /// In en, this message translates to:
  /// **'{key}: {value}'**
  String diagLabelKeyValue(String key, String value);

  /// No description provided for @diagLastLabel.
  ///
  /// In en, this message translates to:
  /// **'Last: '**
  String get diagLastLabel;

  /// No description provided for @diagHours1.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get diagHours1;

  /// No description provided for @diagHours6.
  ///
  /// In en, this message translates to:
  /// **'6 hours'**
  String get diagHours6;

  /// No description provided for @diagHours24.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get diagHours24;

  /// No description provided for @diagDays3.
  ///
  /// In en, this message translates to:
  /// **'3 days'**
  String get diagDays3;

  /// No description provided for @diagDays7.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get diagDays7;

  /// No description provided for @diagThisInstanceOnly.
  ///
  /// In en, this message translates to:
  /// **'This instance only'**
  String get diagThisInstanceOnly;

  /// No description provided for @diagPermissionDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'Permission Denied'**
  String get diagPermissionDeniedTitle;

  /// No description provided for @diagErrorLoadingAuditLogsTitle.
  ///
  /// In en, this message translates to:
  /// **'Error Loading Audit Logs'**
  String get diagErrorLoadingAuditLogsTitle;

  /// No description provided for @diagNoAuditLogsFound.
  ///
  /// In en, this message translates to:
  /// **'No audit logs found in the selected time range'**
  String get diagNoAuditLogsFound;

  /// No description provided for @diagUnknownOperation.
  ///
  /// In en, this message translates to:
  /// **'Unknown operation'**
  String get diagUnknownOperation;

  /// No description provided for @diagSystemFallback.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get diagSystemFallback;

  /// No description provided for @diagLogSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{timestamp} - {principal}'**
  String diagLogSubtitle(String timestamp, String principal);

  /// No description provided for @diagLabelSeverity.
  ///
  /// In en, this message translates to:
  /// **'Severity'**
  String get diagLabelSeverity;

  /// No description provided for @diagLabelResource.
  ///
  /// In en, this message translates to:
  /// **'Resource'**
  String get diagLabelResource;

  /// No description provided for @diagValueNa.
  ///
  /// In en, this message translates to:
  /// **'N/A'**
  String get diagValueNa;

  /// No description provided for @diagLabelResourceType.
  ///
  /// In en, this message translates to:
  /// **'Resource Type'**
  String get diagLabelResourceType;

  /// No description provided for @diagLabelLog.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get diagLabelLog;

  /// No description provided for @diagLabelRequest.
  ///
  /// In en, this message translates to:
  /// **'Request'**
  String get diagLabelRequest;

  /// No description provided for @sftpErrorLoadDirectory.
  ///
  /// In en, this message translates to:
  /// **'Failed to load directory \"{path}\": {error}\n\nCheck permissions and network connectivity.'**
  String sftpErrorLoadDirectory(String path, String error);

  /// No description provided for @sftpUploadingFile.
  ///
  /// In en, this message translates to:
  /// **'Uploading {fileName}…'**
  String sftpUploadingFile(String fileName);

  /// No description provided for @sftpErrorUploadFile.
  ///
  /// In en, this message translates to:
  /// **'Failed to upload \"{fileName}\": {error}\n\nCheck file permissions and disk space.'**
  String sftpErrorUploadFile(String fileName, String error);

  /// No description provided for @sftpUploadingBatch.
  ///
  /// In en, this message translates to:
  /// **'Uploading {current}/{total}: {fileName}…'**
  String sftpUploadingBatch(int current, int total, String fileName);

  /// No description provided for @sftpUploadingFolder.
  ///
  /// In en, this message translates to:
  /// **'Uploading folder {folderName}…'**
  String sftpUploadingFolder(String folderName);

  /// No description provided for @sftpUploadingFolderProgress.
  ///
  /// In en, this message translates to:
  /// **'Uploading {current}/{total}: {fileName}…'**
  String sftpUploadingFolderProgress(int current, int total, String fileName);

  /// No description provided for @sftpErrorUploadFolder.
  ///
  /// In en, this message translates to:
  /// **'Failed to upload folder: {error}\n\nSome files may have been uploaded successfully.'**
  String sftpErrorUploadFolder(String error);

  /// No description provided for @sftpErrorFolderNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid folder name.'**
  String get sftpErrorFolderNameInvalid;

  /// No description provided for @sftpErrorUploadBatch.
  ///
  /// In en, this message translates to:
  /// **'Failed to upload files: {error}\n\nSome files may have been uploaded successfully.'**
  String sftpErrorUploadBatch(String error);

  /// No description provided for @sftpDownloadingFile.
  ///
  /// In en, this message translates to:
  /// **'Downloading {fileName}…'**
  String sftpDownloadingFile(String fileName);

  /// No description provided for @sftpErrorDownloadFile.
  ///
  /// In en, this message translates to:
  /// **'Failed to download \"{fileName}\": {error}\n\nCheck local disk space and permissions.'**
  String sftpErrorDownloadFile(String fileName, String error);

  /// No description provided for @sftpErrorDirNameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Directory name cannot be empty.'**
  String get sftpErrorDirNameEmpty;

  /// No description provided for @sftpErrorDirNameSeparators.
  ///
  /// In en, this message translates to:
  /// **'Directory name cannot contain path separators (/ or \\).'**
  String get sftpErrorDirNameSeparators;

  /// No description provided for @sftpErrorDirNameParentRef.
  ///
  /// In en, this message translates to:
  /// **'Directory name cannot contain \"..\" (parent directory references).'**
  String get sftpErrorDirNameParentRef;

  /// No description provided for @sftpErrorDirNameTooLong.
  ///
  /// In en, this message translates to:
  /// **'Directory name too long (max 255 characters).'**
  String get sftpErrorDirNameTooLong;

  /// No description provided for @sftpCreatingDirectory.
  ///
  /// In en, this message translates to:
  /// **'Creating directory…'**
  String get sftpCreatingDirectory;

  /// No description provided for @sftpErrorCreateDirectory.
  ///
  /// In en, this message translates to:
  /// **'Failed to create directory \"{dirName}\": {error}\n\nCheck remote permissions.'**
  String sftpErrorCreateDirectory(String dirName, String error);

  /// No description provided for @sftpDeletingFile.
  ///
  /// In en, this message translates to:
  /// **'Deleting {fileName}…'**
  String sftpDeletingFile(String fileName);

  /// No description provided for @sftpErrorDeleteFile.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete \"{fileName}\": {error}\n\nCheck remote permissions and ensure it is not in use.'**
  String sftpErrorDeleteFile(String fileName, String error);

  /// No description provided for @sftpLoadingPreview.
  ///
  /// In en, this message translates to:
  /// **'Loading preview…'**
  String get sftpLoadingPreview;

  /// No description provided for @sftpErrorLoadPreview.
  ///
  /// In en, this message translates to:
  /// **'Failed to load preview: {error}'**
  String sftpErrorLoadPreview(String error);

  /// No description provided for @sftpFileBrowserTitle.
  ///
  /// In en, this message translates to:
  /// **'File Browser - {instanceName}'**
  String sftpFileBrowserTitle(String instanceName);

  /// No description provided for @sftpSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search files and folders…'**
  String get sftpSearchHint;

  /// No description provided for @sftpParentDirectoryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Go to parent directory'**
  String get sftpParentDirectoryTooltip;

  /// No description provided for @sftpUploadButton.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get sftpUploadButton;

  /// No description provided for @sftpUploadFileButton.
  ///
  /// In en, this message translates to:
  /// **'Upload File'**
  String get sftpUploadFileButton;

  /// No description provided for @sftpUploadFolderButton.
  ///
  /// In en, this message translates to:
  /// **'Upload Folder'**
  String get sftpUploadFolderButton;

  /// No description provided for @sftpNewFolderButton.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get sftpNewFolderButton;

  /// No description provided for @sftpDropFilesHere.
  ///
  /// In en, this message translates to:
  /// **'Drop files here to upload'**
  String get sftpDropFilesHere;

  /// No description provided for @sftpEmptyFolder.
  ///
  /// In en, this message translates to:
  /// **'This folder is empty\n\nDrag & drop files here to upload'**
  String get sftpEmptyFolder;

  /// No description provided for @sftpNoFilesMatch.
  ///
  /// In en, this message translates to:
  /// **'No files match \"{query}\"'**
  String sftpNoFilesMatch(String query);

  /// No description provided for @sftpCreateFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'Create New Folder'**
  String get sftpCreateFolderTitle;

  /// No description provided for @sftpFolderNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Folder Name'**
  String get sftpFolderNameLabel;

  /// No description provided for @sftpCreateButton.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get sftpCreateButton;

  /// No description provided for @sftpConfirmDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm Delete'**
  String get sftpConfirmDeleteTitle;

  /// No description provided for @sftpConfirmDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{fileName}\"?'**
  String sftpConfirmDeleteMessage(String fileName);

  /// No description provided for @sftpFolderLabel.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get sftpFolderLabel;

  /// No description provided for @sftpPreviewTooltip.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get sftpPreviewTooltip;

  /// No description provided for @sftpDownloadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get sftpDownloadTooltip;

  /// No description provided for @sftpErrorLoadFile.
  ///
  /// In en, this message translates to:
  /// **'Failed to load file: {error}'**
  String sftpErrorLoadFile(String error);

  /// No description provided for @sftpErrorLoadImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to load image'**
  String get sftpErrorLoadImage;

  /// No description provided for @dashboardLoadingAccountsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Loading accounts…'**
  String get dashboardLoadingAccountsTooltip;

  /// No description provided for @appLogoutButton.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get appLogoutButton;

  /// No description provided for @appConnectionHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection History'**
  String get appConnectionHistoryTitle;

  /// No description provided for @appExportLogsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Export Logs'**
  String get appExportLogsTooltip;

  /// No description provided for @appAboutTooltip.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get appAboutTooltip;

  /// No description provided for @dashboardGcloudRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Google Cloud CLI Required'**
  String get dashboardGcloudRequiredTitle;

  /// No description provided for @dashboardGcloudRequiredDescription.
  ///
  /// In en, this message translates to:
  /// **'Lightweight Cloud Connector requires the Google Cloud CLI (gcloud) to connect to your GCP resources.'**
  String get dashboardGcloudRequiredDescription;

  /// No description provided for @dashboardInstallInstructionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Installation Instructions'**
  String get dashboardInstallInstructionsTitle;

  /// No description provided for @dashboardInstallInstructionsBody.
  ///
  /// In en, this message translates to:
  /// **'Please go to the following site and follow the instructions to install the Google Cloud SDK for your operating system:'**
  String get dashboardInstallInstructionsBody;

  /// No description provided for @dashboardOpenInstructionsButton.
  ///
  /// In en, this message translates to:
  /// **'Open Instructions in Browser'**
  String get dashboardOpenInstructionsButton;

  /// No description provided for @dashboardCheckAgainButton.
  ///
  /// In en, this message translates to:
  /// **'Check Again'**
  String get dashboardCheckAgainButton;

  /// No description provided for @dashboardLaunchingBrowserLogin.
  ///
  /// In en, this message translates to:
  /// **'Launching browser for login…'**
  String get dashboardLaunchingBrowserLogin;

  /// No description provided for @dashboardLoginFailed.
  ///
  /// In en, this message translates to:
  /// **'Login Failed: {error}'**
  String dashboardLoginFailed(String error);

  /// No description provided for @dashboardLoginButton.
  ///
  /// In en, this message translates to:
  /// **'Login to Google Cloud'**
  String get dashboardLoginButton;

  /// No description provided for @appExportingLogs.
  ///
  /// In en, this message translates to:
  /// **'Exporting logs…'**
  String get appExportingLogs;

  /// No description provided for @appLogsExportedTitle.
  ///
  /// In en, this message translates to:
  /// **'Logs Exported Successfully'**
  String get appLogsExportedTitle;

  /// No description provided for @appLogsExportedBody.
  ///
  /// In en, this message translates to:
  /// **'All logs have been consolidated and exported to:'**
  String get appLogsExportedBody;

  /// No description provided for @appLogsExportedHint.
  ///
  /// In en, this message translates to:
  /// **'You can share this file for troubleshooting.'**
  String get appLogsExportedHint;

  /// No description provided for @appExportLogsFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to export logs: {error}'**
  String appExportLogsFailed(String error);

  /// No description provided for @appLogoutMultiAccountCount.
  ///
  /// In en, this message translates to:
  /// **'You have {count} authenticated accounts.'**
  String appLogoutMultiAccountCount(int count);

  /// No description provided for @appLogoutActiveAccount.
  ///
  /// In en, this message translates to:
  /// **'Active: {email}'**
  String appLogoutActiveAccount(String email);

  /// No description provided for @appLogoutThisAccount.
  ///
  /// In en, this message translates to:
  /// **'Logout {email}'**
  String appLogoutThisAccount(String email);

  /// No description provided for @appLogoutAllAccounts.
  ///
  /// In en, this message translates to:
  /// **'Logout All'**
  String get appLogoutAllAccounts;

  /// No description provided for @appLogoutConfirmSingle.
  ///
  /// In en, this message translates to:
  /// **'This will revoke your Google Cloud credentials from this machine. Are you sure?'**
  String get appLogoutConfirmSingle;

  /// No description provided for @appLoggedOutAccount.
  ///
  /// In en, this message translates to:
  /// **'Logged out {email}.'**
  String appLoggedOutAccount(String email);

  /// No description provided for @appLogoutError.
  ///
  /// In en, this message translates to:
  /// **'Logout Error: {error}'**
  String appLogoutError(String error);

  /// No description provided for @appLoggedOutFullMessage.
  ///
  /// In en, this message translates to:
  /// **'Logged out successfully. All cached data cleared.'**
  String get appLoggedOutFullMessage;

  /// No description provided for @dashboardAutoRefreshEnabledTooltip.
  ///
  /// In en, this message translates to:
  /// **'Auto-refresh enabled ({seconds}s)'**
  String dashboardAutoRefreshEnabledTooltip(int seconds);

  /// No description provided for @dashboardEnableAutoRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Enable auto-refresh'**
  String get dashboardEnableAutoRefreshTooltip;

  /// No description provided for @dashboardAutoRefreshDisabledSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Auto-refresh disabled'**
  String get dashboardAutoRefreshDisabledSnackbar;

  /// No description provided for @dashboardAutoRefreshEnabledSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Auto-refresh enabled ({seconds}s interval)'**
  String dashboardAutoRefreshEnabledSnackbar(int seconds);

  /// No description provided for @appAddedInstanceSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Added instance: {name}'**
  String appAddedInstanceSnackbar(String name);

  /// No description provided for @appCopyright.
  ///
  /// In en, this message translates to:
  /// **'© 2026 Jordi Lopez Reyes'**
  String get appCopyright;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'A native tool to simplify Google Cloud IAP connections on Linux.'**
  String get appTagline;

  /// No description provided for @appEditionsCalverTitle.
  ///
  /// In en, this message translates to:
  /// **'LCC Editions — CalVer'**
  String get appEditionsCalverTitle;

  /// No description provided for @appEditionsCalverBody.
  ///
  /// In en, this message translates to:
  /// **'Editions follow a half-year cadence (YYH#):\n  • 26H1 — First half of 2026\n  • 26H2 — Second half of 2026 (current)\nBuilds provide continuous fixes between editions.'**
  String get appEditionsCalverBody;

  /// No description provided for @appWhatsNewTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s new in Edition {edition}:'**
  String appWhatsNewTitle(String edition);

  /// No description provided for @appWhatsNewItem1.
  ///
  /// In en, this message translates to:
  /// **'• VM Labels display & label-based search'**
  String get appWhatsNewItem1;

  /// No description provided for @appWhatsNewItem2.
  ///
  /// In en, this message translates to:
  /// **'• Suspend/Resume VM state'**
  String get appWhatsNewItem2;

  /// No description provided for @appWhatsNewItem3.
  ///
  /// In en, this message translates to:
  /// **'• OS Login & Windows VM auto-detection'**
  String get appWhatsNewItem3;

  /// No description provided for @appWhatsNewItem4.
  ///
  /// In en, this message translates to:
  /// **'• Global Tunnel Manager + Auto-Reconnect'**
  String get appWhatsNewItem4;

  /// No description provided for @appWhatsNewItem5.
  ///
  /// In en, this message translates to:
  /// **'• Multi-account & Project Explorer'**
  String get appWhatsNewItem5;

  /// No description provided for @appWhatsNewItem6.
  ///
  /// In en, this message translates to:
  /// **'• Connectivity Doctor (10 diagnostic checks)'**
  String get appWhatsNewItem6;

  /// No description provided for @appWhatsNewItem7.
  ///
  /// In en, this message translates to:
  /// **'• SSHFS Mount, Database Clients, Windows Credentials'**
  String get appWhatsNewItem7;

  /// No description provided for @appDeveloperLabel.
  ///
  /// In en, this message translates to:
  /// **'Developer:'**
  String get appDeveloperLabel;

  /// No description provided for @appSourceCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Source Code:'**
  String get appSourceCodeLabel;

  /// No description provided for @appTechStackLabel.
  ///
  /// In en, this message translates to:
  /// **'Tech Stack:'**
  String get appTechStackLabel;

  /// No description provided for @appTechStackValue.
  ///
  /// In en, this message translates to:
  /// **'Flutter • Rust • Google Cloud Client Libraries'**
  String get appTechStackValue;

  /// No description provided for @dashboardSearchInstancesHint.
  ///
  /// In en, this message translates to:
  /// **'Search instances…'**
  String get dashboardSearchInstancesHint;

  /// No description provided for @dashboardFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get dashboardFilterAll;

  /// No description provided for @dashboardAllProjectsHint.
  ///
  /// In en, this message translates to:
  /// **'All Projects'**
  String get dashboardAllProjectsHint;

  /// No description provided for @dashboardNoProjectsSelected.
  ///
  /// In en, this message translates to:
  /// **'No projects selected'**
  String get dashboardNoProjectsSelected;

  /// No description provided for @dashboardSelectProjectsHint.
  ///
  /// In en, this message translates to:
  /// **'Click \"Select Projects\" above to choose GCP projects'**
  String get dashboardSelectProjectsHint;

  /// No description provided for @dashboardProjectsErrorsTitle.
  ///
  /// In en, this message translates to:
  /// **'Some projects had errors'**
  String get dashboardProjectsErrorsTitle;

  /// No description provided for @dashboardPermissionDeniedParen.
  ///
  /// In en, this message translates to:
  /// **'(Permission denied)'**
  String get dashboardPermissionDeniedParen;

  /// No description provided for @dashboardErrorParen.
  ///
  /// In en, this message translates to:
  /// **'(Error)'**
  String get dashboardErrorParen;

  /// No description provided for @dashboardNoInstancesFoundProjects.
  ///
  /// In en, this message translates to:
  /// **'No instances found in selected projects.'**
  String get dashboardNoInstancesFoundProjects;

  /// No description provided for @dashboardNoMatchingInstances.
  ///
  /// In en, this message translates to:
  /// **'No matching instances.'**
  String get dashboardNoMatchingInstances;

  /// No description provided for @dashboardFavoritesCount.
  ///
  /// In en, this message translates to:
  /// **'Favorites ({count})'**
  String dashboardFavoritesCount(int count);

  /// No description provided for @dashboardRemoveFavoriteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get dashboardRemoveFavoriteTooltip;

  /// No description provided for @dashboardAddFavoriteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get dashboardAddFavoriteTooltip;

  /// No description provided for @dashboardPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Permission denied'**
  String get dashboardPermissionDenied;

  /// No description provided for @dashboardErrorLoadingShort.
  ///
  /// In en, this message translates to:
  /// **'Error loading'**
  String get dashboardErrorLoadingShort;

  /// No description provided for @dashboardRunningTunnelActive.
  ///
  /// In en, this message translates to:
  /// **'RUNNING • Tunnel Active • {machineType}'**
  String dashboardRunningTunnelActive(String machineType);

  /// No description provided for @dashboardMenuMountSshfs.
  ///
  /// In en, this message translates to:
  /// **'Mount SSHFS'**
  String get dashboardMenuMountSshfs;

  /// No description provided for @dashboardMenuStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get dashboardMenuStop;

  /// No description provided for @dashboardMenuStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get dashboardMenuStart;

  /// No description provided for @dashboardMenuSuspend.
  ///
  /// In en, this message translates to:
  /// **'Suspend'**
  String get dashboardMenuSuspend;

  /// No description provided for @dashboardMenuReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get dashboardMenuReset;

  /// No description provided for @dashboardMenuResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get dashboardMenuResume;

  /// No description provided for @dashboardMenuDoctor.
  ///
  /// In en, this message translates to:
  /// **'Doctor'**
  String get dashboardMenuDoctor;

  /// No description provided for @dashboardOpeningSftp.
  ///
  /// In en, this message translates to:
  /// **'Opening SFTP…'**
  String get dashboardOpeningSftp;

  /// No description provided for @dashboardOpeningSshfsMount.
  ///
  /// In en, this message translates to:
  /// **'Opening SSHFS mount…'**
  String get dashboardOpeningSshfsMount;

  /// No description provided for @dashboardStartingInstanceShort.
  ///
  /// In en, this message translates to:
  /// **'Starting instance…'**
  String get dashboardStartingInstanceShort;

  /// No description provided for @dashboardStoppingInstanceShort.
  ///
  /// In en, this message translates to:
  /// **'Stopping instance…'**
  String get dashboardStoppingInstanceShort;

  /// No description provided for @dashboardSuspendingInstanceShort.
  ///
  /// In en, this message translates to:
  /// **'Suspending instance…'**
  String get dashboardSuspendingInstanceShort;

  /// No description provided for @dashboardResumingInstanceShort.
  ///
  /// In en, this message translates to:
  /// **'Resuming instance…'**
  String get dashboardResumingInstanceShort;

  /// No description provided for @dashboardResettingInstanceShort.
  ///
  /// In en, this message translates to:
  /// **'Resetting instance…'**
  String get dashboardResettingInstanceShort;

  /// No description provided for @dashboardSelectInstanceHint.
  ///
  /// In en, this message translates to:
  /// **'Select an instance to view details'**
  String get dashboardSelectInstanceHint;

  /// No description provided for @dashboardInstanceResourcesTitle.
  ///
  /// In en, this message translates to:
  /// **'Instance Resources'**
  String get dashboardInstanceResourcesTitle;

  /// No description provided for @dashboardCpuLabel.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get dashboardCpuLabel;

  /// No description provided for @dashboardVcpusValue.
  ///
  /// In en, this message translates to:
  /// **'{count} vCPUs'**
  String dashboardVcpusValue(int count);

  /// No description provided for @dashboardRamLabel.
  ///
  /// In en, this message translates to:
  /// **'RAM'**
  String get dashboardRamLabel;

  /// No description provided for @dashboardSizeGbValue.
  ///
  /// In en, this message translates to:
  /// **'{size} GB'**
  String dashboardSizeGbValue(String size);

  /// No description provided for @dashboardDiskLabel.
  ///
  /// In en, this message translates to:
  /// **'Disk'**
  String get dashboardDiskLabel;

  /// No description provided for @dashboardOsLoginChip.
  ///
  /// In en, this message translates to:
  /// **'OS Login'**
  String get dashboardOsLoginChip;

  /// No description provided for @dashboardActiveTunnelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Active Tunnels'**
  String get dashboardActiveTunnelsTitle;

  /// No description provided for @dashboardActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get dashboardActionsTitle;

  /// No description provided for @dashboardConnectRdpButton.
  ///
  /// In en, this message translates to:
  /// **'Connect RDP'**
  String get dashboardConnectRdpButton;

  /// No description provided for @dashboardConnectVncButton.
  ///
  /// In en, this message translates to:
  /// **'Connect VNC'**
  String get dashboardConnectVncButton;

  /// No description provided for @dashboardConnectSshButton.
  ///
  /// In en, this message translates to:
  /// **'Connect SSH'**
  String get dashboardConnectSshButton;

  /// No description provided for @dashboardLaunchingTerminal.
  ///
  /// In en, this message translates to:
  /// **'Launching Terminal…'**
  String get dashboardLaunchingTerminal;

  /// No description provided for @dashboardSshError.
  ///
  /// In en, this message translates to:
  /// **'SSH Error: {error}'**
  String dashboardSshError(String error);

  /// No description provided for @dashboardOpenSftpButton.
  ///
  /// In en, this message translates to:
  /// **'Open SFTP'**
  String get dashboardOpenSftpButton;

  /// No description provided for @dashboardOpeningTunnelSftp.
  ///
  /// In en, this message translates to:
  /// **'Opening tunnel for SFTP…'**
  String get dashboardOpeningTunnelSftp;

  /// No description provided for @dashboardSftpTunnelFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to create SSH tunnel for SFTP.\n\nPlease verify:\n• Instance is RUNNING\n• You have IAP tunnel permissions\n• Network connectivity is working\n• gcloud CLI is authenticated'**
  String get dashboardSftpTunnelFailed;

  /// No description provided for @dashboardStateError.
  ///
  /// In en, this message translates to:
  /// **'State error: {error}\nPlease restart the app.'**
  String dashboardStateError(String error);

  /// No description provided for @dashboardSftpBrowserFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to open SFTP browser: {error}'**
  String dashboardSftpBrowserFailed(String error);

  /// No description provided for @dashboardUnexpectedError.
  ///
  /// In en, this message translates to:
  /// **'An unexpected error occurred.\nPlease check console logs and report this bug.'**
  String get dashboardUnexpectedError;

  /// No description provided for @dashboardCustomTunnelButton.
  ///
  /// In en, this message translates to:
  /// **'Custom Tunnel'**
  String get dashboardCustomTunnelButton;

  /// No description provided for @dashboardDatabaseButton.
  ///
  /// In en, this message translates to:
  /// **'Database'**
  String get dashboardDatabaseButton;

  /// No description provided for @dashboardCreatingSshTunnelSshfs.
  ///
  /// In en, this message translates to:
  /// **'Creating SSH tunnel for SSHFS mount…'**
  String get dashboardCreatingSshTunnelSshfs;

  /// No description provided for @dashboardSshfsTunnelFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to create SSH tunnel for SSHFS mount.'**
  String get dashboardSshfsTunnelFailed;

  /// No description provided for @dashboardDisconnectAllTunnelsButton.
  ///
  /// In en, this message translates to:
  /// **'Disconnect All Tunnels'**
  String get dashboardDisconnectAllTunnelsButton;

  /// No description provided for @dashboardTestIapConnectionButton.
  ///
  /// In en, this message translates to:
  /// **'Test IAP Connection'**
  String get dashboardTestIapConnectionButton;

  /// No description provided for @dashboardTestingIapConnection.
  ///
  /// In en, this message translates to:
  /// **'Testing IAP connection… This verifies if IAP is properly configured.'**
  String get dashboardTestingIapConnection;

  /// No description provided for @dashboardStartInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Start Instance'**
  String get dashboardStartInstanceButton;

  /// No description provided for @dashboardStartingInstanceProgress.
  ///
  /// In en, this message translates to:
  /// **'Starting instance… This may take a few minutes.'**
  String get dashboardStartingInstanceProgress;

  /// No description provided for @dashboardStartInstanceFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to start instance: {error}'**
  String dashboardStartInstanceFailed(String error);

  /// No description provided for @dashboardStopInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Stop Instance'**
  String get dashboardStopInstanceButton;

  /// No description provided for @dashboardStopInstanceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to stop {name}?\n\nThis will disconnect all active tunnels and shut down the instance.'**
  String dashboardStopInstanceConfirm(String name);

  /// No description provided for @dashboardStoppingInstanceProgress.
  ///
  /// In en, this message translates to:
  /// **'Stopping instance… This may take a few minutes.'**
  String get dashboardStoppingInstanceProgress;

  /// No description provided for @dashboardStopInstanceFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to stop instance: {error}'**
  String dashboardStopInstanceFailed(String error);

  /// No description provided for @dashboardResetInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Reset Instance'**
  String get dashboardResetInstanceButton;

  /// No description provided for @dashboardResetInstanceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to reset {name}?\n\nThis will forcefully restart the instance and disconnect all active tunnels.'**
  String dashboardResetInstanceConfirm(String name);

  /// No description provided for @dashboardResettingInstanceProgress.
  ///
  /// In en, this message translates to:
  /// **'Resetting instance… This may take a few minutes.'**
  String get dashboardResettingInstanceProgress;

  /// No description provided for @dashboardResetInstanceFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to reset instance: {error}'**
  String dashboardResetInstanceFailed(String error);

  /// No description provided for @dashboardSuspendInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Suspend Instance'**
  String get dashboardSuspendInstanceButton;

  /// No description provided for @dashboardSuspendInstanceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to suspend {name}?\n\nThis will save the VM state to disk and disconnect all active tunnels. You can resume it later.'**
  String dashboardSuspendInstanceConfirm(String name);

  /// No description provided for @dashboardSuspendingInstanceProgress.
  ///
  /// In en, this message translates to:
  /// **'Suspending instance… This may take a few minutes.'**
  String get dashboardSuspendingInstanceProgress;

  /// No description provided for @dashboardInstanceSuspendedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Instance suspended successfully!'**
  String get dashboardInstanceSuspendedSuccess;

  /// No description provided for @dashboardSuspendInstanceFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to suspend instance: {error}'**
  String dashboardSuspendInstanceFailed(String error);

  /// No description provided for @dashboardResumeInstanceButton.
  ///
  /// In en, this message translates to:
  /// **'Resume Instance'**
  String get dashboardResumeInstanceButton;

  /// No description provided for @dashboardResumingInstanceProgress.
  ///
  /// In en, this message translates to:
  /// **'Resuming instance… This may take a few minutes.'**
  String get dashboardResumingInstanceProgress;

  /// No description provided for @dashboardInstanceResumedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Instance resumed successfully!'**
  String get dashboardInstanceResumedSuccess;

  /// No description provided for @dashboardResumeInstanceFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to resume instance: {error}'**
  String dashboardResumeInstanceFailed(String error);

  /// No description provided for @appCustomTunnelTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom Tunnel Configuration'**
  String get appCustomTunnelTitle;

  /// No description provided for @appCustomTunnelDescription.
  ///
  /// In en, this message translates to:
  /// **'Select a service preset or enter a custom port:'**
  String get appCustomTunnelDescription;

  /// No description provided for @appCustomPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom Port'**
  String get appCustomPortLabel;

  /// No description provided for @appCustomPortHint.
  ///
  /// In en, this message translates to:
  /// **'Enter port (1-65535)'**
  String get appCustomPortHint;

  /// No description provided for @appSelectedPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Selected port: {port}'**
  String appSelectedPortLabel(int port);

  /// No description provided for @appConnectionSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection Settings'**
  String get appConnectionSettingsTitle;

  /// No description provided for @appDomainOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Domain (Optional)'**
  String get appDomainOptionalLabel;

  /// No description provided for @appSaveCredentialsLabel.
  ///
  /// In en, this message translates to:
  /// **'Save Credentials'**
  String get appSaveCredentialsLabel;

  /// No description provided for @appFullscreenLabel.
  ///
  /// In en, this message translates to:
  /// **'Fullscreen'**
  String get appFullscreenLabel;

  /// No description provided for @appWidthLabel.
  ///
  /// In en, this message translates to:
  /// **'Width'**
  String get appWidthLabel;

  /// No description provided for @appHeightLabel.
  ///
  /// In en, this message translates to:
  /// **'Height'**
  String get appHeightLabel;

  /// No description provided for @appVncConnectionSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'VNC Connection Settings'**
  String get appVncConnectionSettingsTitle;

  /// No description provided for @appPasswordOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Password (Optional)'**
  String get appPasswordOptionalLabel;

  /// No description provided for @appVncPasswordHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty if VNC server has no password'**
  String get appVncPasswordHelper;

  /// No description provided for @appDisplayOptionsLabel.
  ///
  /// In en, this message translates to:
  /// **'Display Options'**
  String get appDisplayOptionsLabel;

  /// No description provided for @appViewOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'View Only'**
  String get appViewOnlyLabel;

  /// No description provided for @appViewOnlyHelper.
  ///
  /// In en, this message translates to:
  /// **'Read-only mode (no keyboard/mouse input)'**
  String get appViewOnlyHelper;

  /// No description provided for @appQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get appQualityLabel;

  /// No description provided for @appConnectionQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Connection Quality'**
  String get appConnectionQualityLabel;

  /// No description provided for @appQualityAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto (Recommended)'**
  String get appQualityAuto;

  /// No description provided for @appQualityHigh.
  ///
  /// In en, this message translates to:
  /// **'High Quality'**
  String get appQualityHigh;

  /// No description provided for @appQualityMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium Quality'**
  String get appQualityMedium;

  /// No description provided for @appQualityLow.
  ///
  /// In en, this message translates to:
  /// **'Low Quality (Faster)'**
  String get appQualityLow;

  /// No description provided for @dashboardTunnelUnhealthy.
  ///
  /// In en, this message translates to:
  /// **'Unhealthy'**
  String get dashboardTunnelUnhealthy;

  /// No description provided for @dashboardTunnelDegraded.
  ///
  /// In en, this message translates to:
  /// **'Degraded'**
  String get dashboardTunnelDegraded;

  /// No description provided for @dashboardTunnelPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Tunnel → :{port}'**
  String dashboardTunnelPortLabel(String port);

  /// No description provided for @dashboardDisconnectTunnelTooltip.
  ///
  /// In en, this message translates to:
  /// **'Disconnect this tunnel'**
  String get dashboardDisconnectTunnelTooltip;

  /// No description provided for @dashboardUptimeLabel.
  ///
  /// In en, this message translates to:
  /// **'Uptime'**
  String get dashboardUptimeLabel;

  /// No description provided for @dashboardLastCheckLabel.
  ///
  /// In en, this message translates to:
  /// **'Last Check'**
  String get dashboardLastCheckLabel;

  /// No description provided for @dashboardLatencyLabel.
  ///
  /// In en, this message translates to:
  /// **'Latency'**
  String get dashboardLatencyLabel;

  /// No description provided for @dashboardAttemptLabel.
  ///
  /// In en, this message translates to:
  /// **'Attempt {current}/{max}'**
  String dashboardAttemptLabel(int current, int max);

  /// No description provided for @dashboardRetryConnectionButton.
  ///
  /// In en, this message translates to:
  /// **'Retry Connection'**
  String get dashboardRetryConnectionButton;

  /// No description provided for @dashboardOnState.
  ///
  /// In en, this message translates to:
  /// **'ON'**
  String get dashboardOnState;

  /// No description provided for @dashboardOffState.
  ///
  /// In en, this message translates to:
  /// **'OFF'**
  String get dashboardOffState;

  /// No description provided for @dashboardAutoMonitoringLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-monitoring every 30s | Auto-reconnect: {state}'**
  String dashboardAutoMonitoringLabel(String state);

  /// No description provided for @appNoProjectsFound.
  ///
  /// In en, this message translates to:
  /// **'No projects found.'**
  String get appNoProjectsFound;

  /// No description provided for @appSelectProjectLabel.
  ///
  /// In en, this message translates to:
  /// **'Select Project'**
  String get appSelectProjectLabel;

  /// No description provided for @appErrorLoadingProjects.
  ///
  /// In en, this message translates to:
  /// **'Error loading projects: {error}'**
  String appErrorLoadingProjects(String error);

  /// No description provided for @appSelectProjectsButton.
  ///
  /// In en, this message translates to:
  /// **'Select Projects'**
  String get appSelectProjectsButton;

  /// No description provided for @appProjectsSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} Project} other{{count} Projects}} ({total} VMs)'**
  String appProjectsSelectedCount(int count, int total);

  /// No description provided for @appProjectsErrorsTooltip.
  ///
  /// In en, this message translates to:
  /// **'{count} project(s) with errors'**
  String appProjectsErrorsTooltip(int count);

  /// No description provided for @appManageProjectsTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage Projects'**
  String get appManageProjectsTitle;

  /// No description provided for @appRefreshAllProjectsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh all projects'**
  String get appRefreshAllProjectsTooltip;

  /// No description provided for @appSearchProjectsHint.
  ///
  /// In en, this message translates to:
  /// **'Search projects…'**
  String get appSearchProjectsHint;

  /// No description provided for @appProjectsSelectedOfMax.
  ///
  /// In en, this message translates to:
  /// **'{count} of {max} projects selected'**
  String appProjectsSelectedOfMax(int count, int max);

  /// No description provided for @appTotalVmsLabel.
  ///
  /// In en, this message translates to:
  /// **'{total} total VMs'**
  String appTotalVmsLabel(int total);

  /// No description provided for @appNoProjectsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No projects available'**
  String get appNoProjectsAvailable;

  /// No description provided for @appNoMatchingProjects.
  ///
  /// In en, this message translates to:
  /// **'No matching projects'**
  String get appNoMatchingProjects;

  /// No description provided for @appInstanceCountVms.
  ///
  /// In en, this message translates to:
  /// **'{count} VMs'**
  String appInstanceCountVms(int count);

  /// No description provided for @appClearAllButton.
  ///
  /// In en, this message translates to:
  /// **'Clear All'**
  String get appClearAllButton;

  /// No description provided for @appDoneButton.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get appDoneButton;

  /// No description provided for @appClearButton.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get appClearButton;

  /// No description provided for @appClearHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear History'**
  String get appClearHistoryTitle;

  /// No description provided for @appClearHistoryConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear all connection history?'**
  String get appClearHistoryConfirm;

  /// No description provided for @appNoConnectionHistory.
  ///
  /// In en, this message translates to:
  /// **'No connection history'**
  String get appNoConnectionHistory;

  /// No description provided for @appNoConnectionHistoryHint.
  ///
  /// In en, this message translates to:
  /// **'Your recent connections will appear here'**
  String get appNoConnectionHistoryHint;

  /// No description provided for @appConnectAgainTooltip.
  ///
  /// In en, this message translates to:
  /// **'Connect again'**
  String get appConnectAgainTooltip;

  /// No description provided for @appVmNotFoundTooltip.
  ///
  /// In en, this message translates to:
  /// **'VM not found in current projects'**
  String get appVmNotFoundTooltip;

  /// No description provided for @appJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get appJustNow;

  /// No description provided for @appMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m ago'**
  String appMinutesAgo(int minutes);

  /// No description provided for @appHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{hours}h ago'**
  String appHoursAgo(int hours);

  /// No description provided for @appDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{days}d ago'**
  String appDaysAgo(int days);

  /// No description provided for @tunnelErrorNotAuthenticated.
  ///
  /// In en, this message translates to:
  /// **'Not signed in to Google Cloud. Run \'gcloud auth login\'.'**
  String get tunnelErrorNotAuthenticated;

  /// No description provided for @tunnelErrorPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Permission denied. The account needs the IAP-secured Tunnel User role.'**
  String get tunnelErrorPermissionDenied;

  /// No description provided for @tunnelErrorInstanceNotFound.
  ///
  /// In en, this message translates to:
  /// **'The instance no longer exists in this project and zone.'**
  String get tunnelErrorInstanceNotFound;

  /// No description provided for @tunnelErrorInstanceNotRunning.
  ///
  /// In en, this message translates to:
  /// **'The instance is not running.'**
  String get tunnelErrorInstanceNotRunning;

  /// No description provided for @tunnelErrorFirewallBlocked.
  ///
  /// In en, this message translates to:
  /// **'A firewall rule is blocking IAP. Allow ingress from 35.235.240.0/20.'**
  String get tunnelErrorFirewallBlocked;

  /// No description provided for @tunnelErrorRelayUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the IAP relay. Check the network or proxy settings.'**
  String get tunnelErrorRelayUnreachable;

  /// No description provided for @tunnelErrorProtocolError.
  ///
  /// In en, this message translates to:
  /// **'Unexpected response from the IAP relay.'**
  String get tunnelErrorProtocolError;

  /// No description provided for @tunnelErrorLocalPortUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No local port available for the tunnel.'**
  String get tunnelErrorLocalPortUnavailable;

  /// No description provided for @tunnelErrorUnknown.
  ///
  /// In en, this message translates to:
  /// **'The tunnel could not be established.'**
  String get tunnelErrorUnknown;

  /// No description provided for @sftpFolderProgressLabel.
  ///
  /// In en, this message translates to:
  /// **'{percent}% — {done}/{total} MB, {filesDone}/{filesTotal} files'**
  String sftpFolderProgressLabel(
    int percent,
    int done,
    int total,
    int filesDone,
    int filesTotal,
  );
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
