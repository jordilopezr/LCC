import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// The bundle id up to build 20261105.55. Preferences (selected projects,
  /// RDP/VNC client choice…) live in a defaults domain named after it.
  private static let legacyBundleId = "com.example.linuxCloudConnector"

  override func applicationWillFinishLaunching(_ notification: Notification) {
    migrateLegacyPreferences()
    super.applicationWillFinishLaunching(notification)
  }

  /// Copies the preferences saved under the old bundle id, once, before
  /// Flutter reads them. Only an empty new domain is filled, so a preference
  /// set after the rename always wins; the old domain is left in place.
  private func migrateLegacyPreferences() {
    let current = UserDefaults.standard
    let migratedKey = "lcc.migrated_from_legacy_bundle_id"
    guard !current.bool(forKey: migratedKey) else { return }
    defer { current.set(true, forKey: migratedKey) }

    let hasOwnPrefs = current.dictionaryRepresentation().keys.contains { $0.hasPrefix("flutter.") }
    guard !hasOwnPrefs,
          let legacy = UserDefaults(suiteName: AppDelegate.legacyBundleId)?
            .persistentDomain(forName: AppDelegate.legacyBundleId)
    else { return }
    for (key, value) in legacy where key.hasPrefix("flutter.") {
      current.set(value, forKey: key)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
