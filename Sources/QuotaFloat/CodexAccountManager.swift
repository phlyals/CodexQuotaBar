import AppKit
import CodexBarCore
import Darwin
import Foundation

struct CodexManagedAccountViewModel: Identifiable, Equatable, Sendable {
  let id: UUID
  let email: String
  let workspaceLabel: String?
  let isCurrentSystemAccount: Bool
}

enum CodexAccountManagerError: LocalizedError, Equatable {
  case loginAlreadyRunning
  case codexBinaryMissing
  case loginFailed(String)
  case loginTimedOut
  case missingLoginIdentity
  case accountNotFound
  case targetAuthMissing
  case targetAuthUnreadable
  case liveAuthUnreadable
  case keyringCredentialStoreUnsupported
  case unsafeManagedHome
  case switchFailed

  var errorDescription: String? {
    switch self {
    case .loginAlreadyRunning: "已有 Codex 登录正在进行。"
    case .codexBinaryMissing: "找不到 codex CLI。请先安装 Codex CLI，再重试。"
    case .loginFailed(let output): "Codex 登录失败。\(output.isEmpty ? "" : "\n\n\(output)")"
    case .loginTimedOut: "Codex 登录等待超时，请重试。"
    case .missingLoginIdentity: "登录完成，但无法识别账号邮箱或账号 ID。"
    case .accountNotFound: "该账号已不存在，请刷新后重试。"
    case .targetAuthMissing: "该账号缺少 auth.json，请重新添加账号。"
    case .targetAuthUnreadable: "无法读取该账号的 auth.json。"
    case .liveAuthUnreadable: "当前系统 Codex 凭据无法安全备份，因此没有执行切换。"
    case .keyringCredentialStoreUnsupported:
      "当前 Codex 使用 macOS 钥匙串凭据。多账号同步切换需要在 ~/.codex/config.toml 中设置 cli_auth_credentials_store = \"file\"，然后重新登录。"
    case .unsafeManagedHome: "账号目录不在 QuotaFloat 管理范围内，已拒绝操作。"
    case .switchFailed: "无法原子替换系统 Codex 登录凭据，原账号保持不变。"
    }
  }
}

struct CodexAccountPaths: Sendable {
  let applicationSupportRoot: URL
  let managedHomesRoot: URL
  let accountStoreURL: URL
  let liveHomeURL: URL

  static func defaults(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> CodexAccountPaths {
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support")
    let root = support.appendingPathComponent("QuotaFloat", isDirectory: true)
    return CodexAccountPaths(
      applicationSupportRoot: root,
      managedHomesRoot: root.appendingPathComponent("CodexHomes", isDirectory: true),
      accountStoreURL: root.appendingPathComponent("managed-codex-accounts.json"),
      liveHomeURL: CodexHomeScope.ambientHomeURL(env: environment, fileManager: fileManager))
  }
}

@MainActor
final class CodexAccountManager: ObservableObject {
  typealias LoginRunner =
    @Sendable (
      _ homePath: String, _ environment: [String: String]
    ) async -> CodexAccountLoginRunner.Result

  @Published private(set) var accounts: [CodexManagedAccountViewModel] = []
  @Published private(set) var isBusy = false
  @Published private(set) var currentSystemEmail: String?
  @Published private(set) var lastErrorMessage: String?

  private let paths: CodexAccountPaths
  private let fileManager: FileManager
  private let environment: [String: String]
  private let store: FileManagedCodexAccountStore
  private let loginRunner: LoginRunner

  init(
    paths: CodexAccountPaths = .defaults(),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    loginRunner: @escaping LoginRunner = { homePath, environment in
      await CodexAccountLoginRunner.run(homePath: homePath, environment: environment)
    }
  ) {
    self.paths = paths
    self.fileManager = fileManager
    self.environment = environment
    self.loginRunner = loginRunner
    self.store = FileManagedCodexAccountStore(
      fileURL: paths.accountStoreURL, fileManager: fileManager)
    self.reload()
  }

  func reload() {
    do {
      let stored = try self.store.loadAccounts()
      let live = Self.readIdentity(homeURL: self.paths.liveHomeURL, environment: self.environment)
      let liveFingerprint = CodexAuthFingerprint.fingerprint(
        homePath: self.paths.liveHomeURL.path,
        fileManager: self.fileManager)
      self.currentSystemEmail = live?.email
      self.accounts = stored.accounts
        .sorted { $0.updatedAt > $1.updatedAt }
        .map { account in
          CodexManagedAccountViewModel(
            id: account.id,
            email: account.email,
            workspaceLabel: account.workspaceLabel,
            isCurrentSystemAccount: Self.matchesLiveAccount(
              account,
              live: live,
              liveFingerprint: liveFingerprint))
        }
      self.lastErrorMessage = nil
    } catch {
      self.accounts = []
      self.lastErrorMessage = error.localizedDescription
    }
  }

  func addAccount() async throws {
    guard !self.isBusy else { throw CodexAccountManagerError.loginAlreadyRunning }
    self.isBusy = true
    defer { self.isBusy = false }

    let id = UUID()
    let homeURL = self.paths.managedHomesRoot.appendingPathComponent(
      id.uuidString, isDirectory: true)
    try self.createSecureDirectory(homeURL)
    do {
      try Self.prepareManagedLoginHome(homeURL, fileManager: self.fileManager)
      let result = await self.loginRunner(homeURL.path, self.environment)
      switch result.outcome {
      case .success: break
      case .missingBinary: throw CodexAccountManagerError.codexBinaryMissing
      case .timedOut: throw CodexAccountManagerError.loginTimedOut
      case .failed, .launchFailed:
        throw CodexAccountManagerError.loginFailed(result.output)
      }

      guard
        let identity = await Self.waitForLoginIdentity(
          homeURL: homeURL,
          environment: self.environment,
          fileManager: self.fileManager),
        let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
        !email.isEmpty
      else {
        throw CodexAccountManagerError.missingLoginIdentity
      }
      let providerID: String? =
        if case .providerAccount(let value) = identity.identity {
          value
        } else {
          nil
        }
      let now = Date().timeIntervalSince1970
      let snapshot = try self.store.loadAccounts()
      let existing = snapshot.account(email: email, providerAccountID: providerID)
      let account = ManagedCodexAccount(
        id: existing?.id ?? id,
        email: email,
        providerAccountID: providerID,
        workspaceLabel: nil,
        workspaceAccountID: providerID,
        authFingerprint: CodexAuthFingerprint.fingerprint(
          homePath: homeURL.path,
          fileManager: self.fileManager),
        managedHomePath: homeURL.path,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        lastAuthenticatedAt: now)
      let accounts = snapshot.accounts.filter { $0.id != existing?.id } + [account]
      try self.store.storeAccounts(
        ManagedCodexAccountSet(
          version: FileManagedCodexAccountStore.currentVersion,
          accounts: accounts))
      if let existing, existing.managedHomePath != homeURL.path {
        try? self.removeManagedHomeIfSafe(existing.managedHomePath)
      }
      self.reload()
    } catch {
      try? self.removeManagedHomeIfSafe(homeURL.path)
      throw error
    }
  }

  func switchSystemAccount(id: UUID) async throws {
    guard !self.isBusy else { throw CodexAccountManagerError.loginAlreadyRunning }
    self.isBusy = true
    defer { self.isBusy = false }

    try Self.validateFileCredentialMode(
      liveHomeURL: self.paths.liveHomeURL,
      fileManager: self.fileManager)
    let snapshot = try self.store.loadAccounts()
    guard let target = snapshot.account(id: id) else {
      throw CodexAccountManagerError.accountNotFound
    }
    try self.validateManagedHome(target.managedHomePath)
    let targetAuthURL = CodexAuthFingerprint.authFileURL(homePath: target.managedHomePath)
    guard self.fileManager.fileExists(atPath: targetAuthURL.path) else {
      throw CodexAccountManagerError.targetAuthMissing
    }
    guard let targetData = try? Data(contentsOf: targetAuthURL), !targetData.isEmpty else {
      throw CodexAccountManagerError.targetAuthUnreadable
    }

    let targetFingerprint = CodexAuthFingerprint.fingerprint(data: targetData)
    let liveFingerprint = CodexAuthFingerprint.fingerprint(
      homePath: self.paths.liveHomeURL.path,
      fileManager: self.fileManager)
    if targetFingerprint == liveFingerprint {
      self.reload()
      return
    }

    var updatedAccounts = snapshot.accounts
    if liveFingerprint != nil {
      updatedAccounts = try self.preserveLiveAccount(in: updatedAccounts)
      try self.store.storeAccounts(
        ManagedCodexAccountSet(
          version: FileManagedCodexAccountStore.currentVersion,
          accounts: updatedAccounts))
    }
    do {
      try Self.atomicReplaceAuth(
        targetData,
        liveHomeURL: self.paths.liveHomeURL,
        fileManager: self.fileManager)
    } catch {
      throw CodexAccountManagerError.switchFailed
    }
    self.reload()
  }

  func removeAccount(id: UUID) throws {
    let snapshot = try self.store.loadAccounts()
    guard let target = snapshot.account(id: id) else { return }
    guard !self.accounts.contains(where: { $0.id == id && $0.isCurrentSystemAccount }) else {
      throw CodexAccountManagerError.liveAuthUnreadable
    }
    try self.store.storeAccounts(
      ManagedCodexAccountSet(
        version: FileManagedCodexAccountStore.currentVersion,
        accounts: snapshot.accounts.filter { $0.id != id }))
    try? self.removeManagedHomeIfSafe(target.managedHomePath)
    self.reload()
  }

  private func preserveLiveAccount(in accounts: [ManagedCodexAccount]) throws
    -> [ManagedCodexAccount]
  {
    let liveAuthURL = self.paths.liveHomeURL.appendingPathComponent("auth.json")
    guard let liveData = try? Data(contentsOf: liveAuthURL), !liveData.isEmpty,
      let identity = Self.readIdentity(
        homeURL: self.paths.liveHomeURL, environment: self.environment),
      let email = identity.email, !email.isEmpty
    else {
      throw CodexAccountManagerError.liveAuthUnreadable
    }
    let providerID: String? =
      if case .providerAccount(let value) = identity.identity { value } else { nil }
    let liveFingerprint = CodexAuthFingerprint.fingerprint(data: liveData)
    if let existing = accounts.first(where: {
      Self.matchesLiveAccount($0, live: identity, liveFingerprint: liveFingerprint)
    }) {
      _ = existing
      return accounts
    }

    let id = UUID()
    let homeURL = self.paths.managedHomesRoot.appendingPathComponent(
      id.uuidString, isDirectory: true)
    try self.createSecureDirectory(homeURL)
    do {
      try Self.atomicReplaceAuth(liveData, liveHomeURL: homeURL, fileManager: self.fileManager)
      let now = Date().timeIntervalSince1970
      let account = ManagedCodexAccount(
        id: id,
        email: email,
        providerAccountID: providerID,
        workspaceLabel: nil,
        workspaceAccountID: providerID,
        authFingerprint: CodexAuthFingerprint.fingerprint(data: liveData),
        managedHomePath: homeURL.path,
        createdAt: now,
        updatedAt: now,
        lastAuthenticatedAt: now)
      return accounts + [account]
    } catch {
      try? self.removeManagedHomeIfSafe(homeURL.path)
      throw error
    }
  }

  nonisolated private static func readIdentity(
    homeURL: URL,
    environment: [String: String]
  ) -> CodexAuthBackedAccount? {
    let env = CodexHomeScope.scopedEnvironment(base: environment, codexHome: homeURL.path)
    let account = UsageFetcher(environment: env).loadAuthBackedCodexAccount()
    guard account.identity != .unresolved || account.email != nil else { return nil }
    return account
  }

  private static func matchesLiveAccount(
    _ stored: ManagedCodexAccount,
    live: CodexAuthBackedAccount?,
    liveFingerprint: String?
  ) -> Bool {
    if let liveFingerprint, stored.authFingerprint == liveFingerprint { return true }
    guard let live else { return false }
    if case .providerAccount(let liveID) = live.identity,
      stored.providerAccountID == ManagedCodexAccount.normalizeProviderAccountID(liveID)
    {
      return true
    }
    return stored.providerAccountID == nil
      && stored.email == CodexIdentityResolver.normalizeEmail(live.email)
  }

  nonisolated static func validateFileCredentialMode(
    liveHomeURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let configURL = liveHomeURL.appendingPathComponent("config.toml")
    if let config = try? String(contentsOf: configURL, encoding: .utf8),
      let mode = Self.credentialStoreMode(in: config),
      mode == "keyring"
    {
      throw CodexAccountManagerError.keyringCredentialStoreUnsupported
    }
    let authURL = liveHomeURL.appendingPathComponent("auth.json")
    if !fileManager.fileExists(atPath: authURL.path),
      (try? String(contentsOf: configURL, encoding: .utf8)).map(Self.credentialStoreMode(in:))
        == "auto"
    {
      throw CodexAccountManagerError.keyringCredentialStoreUnsupported
    }
  }

  nonisolated static func credentialStoreMode(in config: String) -> String? {
    for rawLine in config.split(whereSeparator: \.isNewline) {
      let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLine.hasPrefix("#") else { continue }
      let line = trimmedLine.components(separatedBy: "#").first ?? ""
      let parts = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard parts.count == 2, parts[0] == "cli_auth_credentials_store" else { continue }
      return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
    }
    return nil
  }

  nonisolated static func prepareManagedLoginHome(
    _ homeURL: URL,
    fileManager: FileManager = .default
  ) throws {
    try fileManager.createDirectory(
      at: homeURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homeURL.path)

    let configURL = homeURL.appendingPathComponent("config.toml")
    let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    let config: String
    if Self.credentialStoreMode(in: existing) == nil {
      let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
      config = existing + separator + "cli_auth_credentials_store = \"file\"\n"
    } else {
      config = existing
    }
    try config.write(to: configURL, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
  }

  static func waitForLoginIdentity(
    homeURL: URL,
    environment: [String: String],
    fileManager: FileManager = .default,
    timeout: TimeInterval = 10
  ) async -> CodexAuthBackedAccount? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let authURL = homeURL.appendingPathComponent("auth.json")
      if fileManager.fileExists(atPath: authURL.path),
        let data = try? Data(contentsOf: authURL),
        !data.isEmpty,
        let identity = Self.readIdentity(homeURL: homeURL, environment: environment),
        identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      {
        return identity
      }
      try? await Task.sleep(for: .milliseconds(150))
    } while Date() < deadline && !Task.isCancelled
    return nil
  }

  nonisolated static func atomicReplaceAuth(
    _ data: Data,
    liveHomeURL: URL,
    fileManager: FileManager = .default
  ) throws {
    try fileManager.createDirectory(
      at: liveHomeURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = liveHomeURL.appendingPathComponent("auth.json")
    let staged = liveHomeURL.appendingPathComponent(".auth.json.quotafloat-\(UUID().uuidString)")
    do {
      try data.write(to: staged, options: [.atomic])
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
      guard rename(staged.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }

  private func createSecureDirectory(_ url: URL) throws {
    try self.fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try self.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private func validateManagedHome(_ path: String) throws {
    let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let root = self.paths.managedHomesRoot.standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/"), candidate.deletingLastPathComponent() == root
    else {
      throw CodexAccountManagerError.unsafeManagedHome
    }
  }

  private func removeManagedHomeIfSafe(_ path: String) throws {
    try self.validateManagedHome(path)
    if self.fileManager.fileExists(atPath: path) {
      try self.fileManager.removeItem(atPath: path)
    }
  }
}

struct CodexAccountLoginRunner {
  struct Result: Sendable {
    enum Outcome: Sendable { case success, timedOut, failed, missingBinary, launchFailed }
    let outcome: Outcome
    let output: String
  }

  static func run(
    homePath: String,
    timeout: TimeInterval = 180,
    environment: [String: String]
  ) async -> Result {
    await Task.detached(priority: .userInitiated) {
      var env = CodexHomeScope.scopedEnvironment(base: environment, codexHome: homePath)
      let commonPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
      env["PATH"] = ([env["PATH"]].compactMap { $0 } + commonPaths).joined(separator: ":")
      guard let executable = Self.findCodex(environment: env) else {
        return Result(outcome: .missingBinary, output: "")
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["login"]
      process.environment = env
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      do {
        try process.run()
      } catch {
        return Result(outcome: .launchFailed, output: error.localizedDescription)
      }

      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if process.isRunning {
        process.terminate()
        return Result(outcome: .timedOut, output: "")
      }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return Result(
        outcome: process.terminationStatus == 0 ? .success : .failed,
        output: String(text.prefix(2000)))
    }.value
  }

  private static func findCodex(environment: [String: String]) -> String? {
    for directory in environment["PATH", default: ""].split(separator: ":") {
      let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex").path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    let bundledCandidates = [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
    ]
    if let bundled = bundledCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
      return bundled
    }
    return nil
  }
}
