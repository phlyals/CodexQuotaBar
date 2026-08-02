import XCTest

@testable import QuotaFloat

@MainActor
final class PreferencesTests: XCTestCase {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "QuotaFloatTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  func testLegacyScopedDisplayModeMigratesSelectedApps() {
    let defaults = self.makeDefaults()
    defaults.set("scoped", forKey: DisplayPreferences.legacyStorageKey)

    let preferences = DisplayPreferences(defaults: defaults)

    XCTAssertFalse(preferences.alwaysDisplay)
    XCTAssertEqual(
      preferences.selectedApps,
      ["com.openai.codex"])
  }

  func testVersionUpgradePreservesExistingSelection() {
    let defaults = self.makeDefaults()
    defaults.set(1, forKey: DisplayPreferences.configurationVersionKey)
    defaults.set(false, forKey: DisplayPreferences.alwaysStorageKey)
    defaults.set(["com.apple.Terminal"], forKey: DisplayPreferences.selectedAppsStorageKey)

    let preferences = DisplayPreferences(defaults: defaults)

    XCTAssertFalse(preferences.alwaysDisplay)
    XCTAssertEqual(preferences.selectedApps, ["com.apple.Terminal"])
  }

}
