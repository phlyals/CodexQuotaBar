import AppKit
import Foundation
import Security

struct ClaudeOAuthEnvironmentCredentials: Equatable, Sendable {
  let accessToken: String
  let scopes: [String]
}

struct ClaudeOAuthSecurityCLILoader: Sendable {
  private static let service = "Claude Code-credentials"
  private static let securityBinary = "/usr/bin/security"

  func load() async -> ClaudeOAuthEnvironmentCredentials? {
    await Task.detached(priority: .utility) {
      Self.loadSynchronously()
    }.value
  }

  static func parse(_ data: Data) -> ClaudeOAuthEnvironmentCredentials? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let oauth = root["claudeAiOauth"] as? [String: Any],
      let rawToken = oauth["accessToken"] as? String
    else {
      return nil
    }

    let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accessToken.isEmpty else { return nil }

    let scopes =
      (oauth["scopes"] as? [String])?
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      ?? []

    return ClaudeOAuthEnvironmentCredentials(
      accessToken: accessToken,
      scopes: scopes.isEmpty ? ["user:profile"] : scopes)
  }

  private static func loadSynchronously() -> ClaudeOAuthEnvironmentCredentials? {
    guard FileManager.default.isExecutableFile(atPath: Self.securityBinary) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.securityBinary)
    process.arguments = [
      "find-generic-password",
      "-s",
      Self.service,
      "-w",
    ]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil
    }

    let deadline = Date().addingTimeInterval(3)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }

    return Self.parse(output.fileHandleForReading.readDataToEndOfFile())
  }
}

protocol KimiAPIKeyStoring: Sendable {
  func load() -> String?
  func save(_ apiKey: String) throws
  func clear() throws
}

protocol KeychainPasswordStoring: Sendable {
  func load() throws -> String?
  func save(_ value: String) throws
  func clear() throws
}

struct KimiAPIKeyStore: KimiAPIKeyStoring {
  let fileURL: URL

  init(fileURL: URL = Self.defaultFileURL()) {
    self.fileURL = fileURL
  }

  func load() -> String? {
    guard let data = try? Data(contentsOf: self.fileURL),
      let raw = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  func save(_ apiKey: String) throws {
    let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw KimiAPIKeyStoreError.emptyKey }

    let directory = self.fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data((value + "\n").utf8).write(to: self.fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: self.fileURL.path)
  }

  func clear() throws {
    guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
    try FileManager.default.removeItem(at: self.fileURL)
  }

  private static func defaultFileURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    return root
      .appendingPathComponent("QuotaFloat", isDirectory: true)
      .appendingPathComponent("kimi-code-api-key", isDirectory: false)
  }
}

struct SecureKimiAPIKeyStore: KimiAPIKeyStoring {
  private let keychain: any KeychainPasswordStoring
  private let fileFallback: KimiAPIKeyStore

  init(
    keychain: any KeychainPasswordStoring = KeychainPasswordStore(
      service: "local.channoey.quotafloat.kimi",
      account: "coding-plan-api-key"),
    fileFallback: KimiAPIKeyStore = KimiAPIKeyStore()
  ) {
    self.keychain = keychain
    self.fileFallback = fileFallback
  }

  func load() -> String? {
    if let keychainValue = try? self.keychain.load() {
      return keychainValue
    }

    guard let fileValue = self.fileFallback.load() else { return nil }
    try? self.save(fileValue)
    return fileValue
  }

  func save(_ apiKey: String) throws {
    let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw KimiAPIKeyStoreError.emptyKey }
    try self.keychain.save(value)
  }

  func clear() throws {
    try self.keychain.clear()
    try self.fileFallback.clear()
  }
}

struct KeychainPasswordStore: KeychainPasswordStoring {
  let service: String
  let account: String

  func load() throws -> String? {
    var query = self.baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KimiAPIKeyStoreError.keychainStatus(status) }
    guard
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func save(_ value: String) throws {
    let data = Data(value.utf8)
    var query = self.baseQuery()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let updateStatus = SecItemUpdate(
        self.baseQuery() as CFDictionary,
        [kSecValueData as String: data] as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw KimiAPIKeyStoreError.keychainStatus(updateStatus)
      }
      return
    }
    guard status == errSecSuccess else { throw KimiAPIKeyStoreError.keychainStatus(status) }
  }

  func clear() throws {
    let status = SecItemDelete(self.baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KimiAPIKeyStoreError.keychainStatus(status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: self.service,
      kSecAttrAccount as String: self.account,
    ]
  }
}

enum KimiAPIKeyStoreError: LocalizedError {
  case emptyKey
  case keychainStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .emptyKey:
      "Kimi Coding Plan API Key不能为空。"
    case .keychainStatus(let status):
      "无法访问 macOS 钥匙串（状态码 \(status)）。"
    }
  }
}

@MainActor
final class ProviderCredentialPreferences: ObservableObject {
  let kimiAPIKeyStore: any KimiAPIKeyStoring
  @Published private(set) var hasKimiAPIKey: Bool

  init(kimiAPIKeyStore: any KimiAPIKeyStoring = SecureKimiAPIKeyStore()) {
    self.kimiAPIKeyStore = kimiAPIKeyStore
    self.hasKimiAPIKey = kimiAPIKeyStore.load() != nil
  }

  @discardableResult
  func promptForKimiAPIKey() -> Bool {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = self.hasKimiAPIKey ? "输入新的 API Key以替换现有配置" : "KIMI_CODE_API_KEY"

    let alert = NSAlert()
    alert.messageText = "设置 Kimi Coding Plan API Key"
    alert.informativeText =
      "API Key仅保存在本机 macOS 钥匙串中；旧版本文件密钥会在首次读取时自动迁移。"
    alert.alertStyle = .informational
    alert.accessoryView = field
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")

    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    do {
      try self.kimiAPIKeyStore.save(field.stringValue)
      self.hasKimiAPIKey = true
      return true
    } catch {
      Self.showError(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  func confirmAndClearKimiAPIKey() -> Bool {
    let alert = NSAlert()
    alert.messageText = "清除 Kimi API Key？"
    alert.informativeText = "清除后 Kimi额度将停止刷新，直到重新设置 API Key。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "清除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    do {
      try self.kimiAPIKeyStore.clear()
      self.hasKimiAPIKey = false
      return true
    } catch {
      Self.showError(error.localizedDescription)
      return false
    }
  }

  private static func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "无法保存 Kimi API Key"
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.runModal()
  }
}
