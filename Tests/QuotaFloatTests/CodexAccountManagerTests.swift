import CodexBarCore
import Foundation
import XCTest

@testable import QuotaFloat

final class CodexAccountManagerTests: XCTestCase {
  func testCredentialStoreModeParsesSupportedValuesAndComments() {
    XCTAssertEqual(
      CodexAccountManager.credentialStoreMode(
        in: "cli_auth_credentials_store = \"file\" # portable"),
      "file")
    XCTAssertEqual(
      CodexAccountManager.credentialStoreMode(
        in: "# cli_auth_credentials_store = \"file\"\ncli_auth_credentials_store='keyring'"),
      "keyring")
  }

  func testKeyringModeIsRejectedBeforeMutation() throws {
    let home = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("original".utf8).write(to: home.appendingPathComponent("auth.json"))
    try Data("cli_auth_credentials_store = \"keyring\"".utf8)
      .write(to: home.appendingPathComponent("config.toml"))

    XCTAssertThrowsError(try CodexAccountManager.validateFileCredentialMode(liveHomeURL: home)) {
      XCTAssertEqual($0 as? CodexAccountManagerError, .keyringCredentialStoreUnsupported)
    }
    XCTAssertEqual(
      try Data(contentsOf: home.appendingPathComponent("auth.json")),
      Data("original".utf8))
  }

  func testAtomicAuthReplacementUsesSecurePermissions() throws {
    let home = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("old".utf8).write(to: home.appendingPathComponent("auth.json"))

    try CodexAccountManager.atomicReplaceAuth(Data("new".utf8), liveHomeURL: home)

    let authURL = home.appendingPathComponent("auth.json")
    XCTAssertEqual(try Data(contentsOf: authURL), Data("new".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: home.path)
        .allSatisfy { !$0.hasPrefix(".auth.json.quotafloat-") })
  }

  func testManagedLoginHomeForcesFileCredentialStorage() throws {
    let home = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    try CodexAccountManager.prepareManagedLoginHome(home)

    let configURL = home.appendingPathComponent("config.toml")
    let config = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssertEqual(CodexAccountManager.credentialStoreMode(in: config), "file")
    let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  @MainActor
  func testSuccessfulManagedLoginPersistsAndPublishesAccount() async throws {
    let root = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let liveHome = root.appendingPathComponent("live", isDirectory: true)
    let homesRoot = root.appendingPathComponent("homes", isDirectory: true)
    let storeURL = root.appendingPathComponent("accounts.json")
    try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
    let auth = try Self.authJSON(email: "added@example.com", accountID: "added-account")
    let paths = CodexAccountPaths(
      applicationSupportRoot: root,
      managedHomesRoot: homesRoot,
      accountStoreURL: storeURL,
      liveHomeURL: liveHome)
    let manager = CodexAccountManager(
      paths: paths,
      environment: [:],
      loginRunner: { homePath, _ in
        do {
          try auth.write(to: URL(fileURLWithPath: homePath).appendingPathComponent("auth.json"))
          return CodexAccountLoginRunner.Result(outcome: .success, output: "")
        } catch {
          return CodexAccountLoginRunner.Result(
            outcome: .failed, output: error.localizedDescription)
        }
      })

    try await manager.addAccount()

    XCTAssertEqual(manager.accounts.map(\.email), ["added@example.com"])
    let stored = try FileManagedCodexAccountStore(fileURL: storeURL).loadAccounts()
    XCTAssertEqual(stored.accounts.count, 1)
    XCTAssertEqual(stored.accounts.first?.providerAccountID, "added-account")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: stored.accounts[0].managedHomePath + "/auth.json"))
  }

  @MainActor
  func testSwitchPreservesLiveAccountAndActivatesTarget() async throws {
    let root = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let liveHome = root.appendingPathComponent("live", isDirectory: true)
    let homesRoot = root.appendingPathComponent("homes", isDirectory: true)
    let targetHome = homesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
    let liveAuth = try Self.authJSON(email: "old@example.com", accountID: "old-account")
    let targetAuth = try Self.authJSON(email: "new@example.com", accountID: "new-account")
    try liveAuth.write(to: liveHome.appendingPathComponent("auth.json"))
    try targetAuth.write(to: targetHome.appendingPathComponent("auth.json"))

    let targetID = UUID()
    let now = Date().timeIntervalSince1970
    let storeURL = root.appendingPathComponent("accounts.json")
    let store = FileManagedCodexAccountStore(fileURL: storeURL)
    try store.storeAccounts(
      ManagedCodexAccountSet(
        version: FileManagedCodexAccountStore.currentVersion,
        accounts: [
          ManagedCodexAccount(
            id: targetID,
            email: "new@example.com",
            providerAccountID: "new-account",
            authFingerprint: CodexAuthFingerprint.fingerprint(data: targetAuth),
            managedHomePath: targetHome.path,
            createdAt: now,
            updatedAt: now,
            lastAuthenticatedAt: now)
        ]))
    let paths = CodexAccountPaths(
      applicationSupportRoot: root,
      managedHomesRoot: homesRoot,
      accountStoreURL: storeURL,
      liveHomeURL: liveHome)
    let manager = CodexAccountManager(paths: paths, environment: [:])

    try await manager.switchSystemAccount(id: targetID)

    XCTAssertEqual(try Data(contentsOf: liveHome.appendingPathComponent("auth.json")), targetAuth)
    XCTAssertEqual(manager.currentSystemEmail, "new@example.com")
    XCTAssertTrue(
      manager.accounts.first(where: { $0.id == targetID })?.isCurrentSystemAccount == true)
    let stored = try store.loadAccounts()
    XCTAssertEqual(stored.accounts.count, 2)
    XCTAssertNotNil(stored.account(email: "old@example.com", providerAccountID: "old-account"))
  }

  @MainActor
  func testSwitchRejectsMismatchedTargetWithoutMutatingLiveAuth() async throws {
    let root = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let liveHome = root.appendingPathComponent("live", isDirectory: true)
    let homesRoot = root.appendingPathComponent("homes", isDirectory: true)
    let targetHome = homesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)

    let liveAuth = try Self.authJSON(email: "old@example.com", accountID: "old-account")
    let targetAuth = try Self.authJSON(email: "actual@example.com", accountID: "actual-account")
    try liveAuth.write(to: liveHome.appendingPathComponent("auth.json"))
    try targetAuth.write(to: targetHome.appendingPathComponent("auth.json"))

    let targetID = UUID()
    let now = Date().timeIntervalSince1970
    let storeURL = root.appendingPathComponent("accounts.json")
    let store = FileManagedCodexAccountStore(fileURL: storeURL)
    try store.storeAccounts(
      ManagedCodexAccountSet(
        version: FileManagedCodexAccountStore.currentVersion,
        accounts: [
          ManagedCodexAccount(
            id: targetID,
            email: "saved@example.com",
            providerAccountID: "saved-account",
            authFingerprint: CodexAuthFingerprint.fingerprint(data: targetAuth),
            managedHomePath: targetHome.path,
            createdAt: now,
            updatedAt: now,
            lastAuthenticatedAt: now)
        ]))

    let paths = CodexAccountPaths(
      applicationSupportRoot: root,
      managedHomesRoot: homesRoot,
      accountStoreURL: storeURL,
      liveHomeURL: liveHome)
    let manager = CodexAccountManager(paths: paths, environment: [:])

    do {
      try await manager.switchSystemAccount(id: targetID)
      XCTFail("Expected target identity mismatch")
    } catch {
      XCTAssertEqual(error as? CodexAccountManagerError, .targetIdentityMismatch)
    }

    XCTAssertEqual(
      try Data(contentsOf: liveHome.appendingPathComponent("auth.json")), liveAuth)
    XCTAssertEqual(try store.loadAccounts().accounts.count, 1)
  }

  @MainActor
  func testSwitchSynchronizesRefreshedLiveCredentialsToExistingManagedAccount() async throws {
    let root = try self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let liveHome = root.appendingPathComponent("live", isDirectory: true)
    let homesRoot = root.appendingPathComponent("homes", isDirectory: true)
    let oldHome = homesRoot.appendingPathComponent("old", isDirectory: true)
    let targetHome = homesRoot.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: oldHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)

    let staleOldAuth = try Self.authJSON(
      email: "old@example.com", accountID: "old-account", marker: "stale")
    let refreshedOldAuth = try Self.authJSON(
      email: "old@example.com", accountID: "old-account", marker: "refreshed")
    let targetAuth = try Self.authJSON(email: "new@example.com", accountID: "new-account")
    try staleOldAuth.write(to: oldHome.appendingPathComponent("auth.json"))
    try refreshedOldAuth.write(to: liveHome.appendingPathComponent("auth.json"))
    try targetAuth.write(to: targetHome.appendingPathComponent("auth.json"))

    let oldID = UUID()
    let targetID = UUID()
    let now = Date().timeIntervalSince1970
    let storeURL = root.appendingPathComponent("accounts.json")
    let store = FileManagedCodexAccountStore(fileURL: storeURL)
    try store.storeAccounts(
      ManagedCodexAccountSet(
        version: FileManagedCodexAccountStore.currentVersion,
        accounts: [
          ManagedCodexAccount(
            id: oldID,
            email: "old@example.com",
            providerAccountID: "old-account",
            authFingerprint: CodexAuthFingerprint.fingerprint(data: staleOldAuth),
            managedHomePath: oldHome.path,
            createdAt: now,
            updatedAt: now,
            lastAuthenticatedAt: now),
          ManagedCodexAccount(
            id: targetID,
            email: "new@example.com",
            providerAccountID: "new-account",
            authFingerprint: CodexAuthFingerprint.fingerprint(data: targetAuth),
            managedHomePath: targetHome.path,
            createdAt: now,
            updatedAt: now,
            lastAuthenticatedAt: now),
        ]))

    let paths = CodexAccountPaths(
      applicationSupportRoot: root,
      managedHomesRoot: homesRoot,
      accountStoreURL: storeURL,
      liveHomeURL: liveHome)
    let manager = CodexAccountManager(paths: paths, environment: [:])

    manager.synchronizeLiveCredentials()
    manager.synchronizeLiveCredentials()
    XCTAssertEqual(
      try Data(contentsOf: oldHome.appendingPathComponent("auth.json")), refreshedOldAuth)
    XCTAssertEqual(
      try Data(contentsOf: liveHome.appendingPathComponent("auth.json")), refreshedOldAuth)
    try await manager.switchSystemAccount(id: targetID)

    XCTAssertEqual(
      try Data(contentsOf: oldHome.appendingPathComponent("auth.json")), refreshedOldAuth)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexAccountManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func authJSON(email: String, accountID: String) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: [
      "email": email,
      "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
    ])
    let encodedPayload = payload.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try JSONSerialization.data(withJSONObject: [
      "tokens": [
        "access_token": "access-\(accountID)",
        "refresh_token": "refresh-\(accountID)",
        "id_token": "header.\(encodedPayload).signature",
        "account_id": accountID,
      ]
    ])
  }

  private static func authJSON(email: String, accountID: String, marker: String) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: [
      "email": email,
      "session_marker": marker,
      "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
    ])
    let encodedPayload = payload.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try JSONSerialization.data(withJSONObject: [
      "tokens": [
        "access_token": "access-\(accountID)-\(marker)",
        "refresh_token": "refresh-\(accountID)-\(marker)",
        "id_token": "header.\(encodedPayload).signature",
        "account_id": accountID,
      ]
    ])
  }
}
