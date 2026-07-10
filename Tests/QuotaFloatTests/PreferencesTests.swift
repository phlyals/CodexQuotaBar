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
      ["com.openai.codex", "com.anthropic.claudefordesktop"])
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

  func testKimiCredentialPreferencesUseInjectedStore() throws {
    let store = MemoryKimiAPIKeyStore()
    try store.save("key-from-test")

    let preferences = ProviderCredentialPreferences(kimiAPIKeyStore: store)

    XCTAssertTrue(preferences.hasKimiAPIKey)
  }

  func testSecureKimiStoreMigratesExistingFileValueIntoKeychain() throws {
    let fileStore = KimiAPIKeyStore(fileURL: self.makeTemporaryKeyURL())
    try fileStore.save("file-key")
    let keychain = MemoryKeychainPasswordStore()
    let secureStore = SecureKimiAPIKeyStore(keychain: keychain, fileFallback: fileStore)

    XCTAssertEqual(secureStore.load(), "file-key")
    XCTAssertEqual(keychain.value, "file-key")
  }

  func testSecureKimiStoreClearRemovesKeychainAndFallbackFile() throws {
    let fileStore = KimiAPIKeyStore(fileURL: self.makeTemporaryKeyURL())
    try fileStore.save("file-key")
    let keychain = MemoryKeychainPasswordStore()
    try keychain.save("keychain-key")
    let secureStore = SecureKimiAPIKeyStore(keychain: keychain, fileFallback: fileStore)

    try secureStore.clear()

    XCTAssertNil(keychain.value)
    XCTAssertNil(fileStore.load())
  }

  private func makeTemporaryKeyURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaFloatTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("kimi-api-key", isDirectory: false)
  }
}

private final class MemoryKimiAPIKeyStore: KimiAPIKeyStoring, @unchecked Sendable {
  private var value: String?

  func load() -> String? {
    self.value
  }

  func save(_ apiKey: String) throws {
    self.value = apiKey
  }

  func clear() throws {
    self.value = nil
  }
}

private final class MemoryKeychainPasswordStore: KeychainPasswordStoring, @unchecked Sendable {
  var value: String?

  func load() throws -> String? {
    self.value
  }

  func save(_ value: String) throws {
    self.value = value
  }

  func clear() throws {
    self.value = nil
  }
}
