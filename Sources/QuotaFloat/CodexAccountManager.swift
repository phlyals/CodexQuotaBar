import AppKit
import CodexBarCore
import Darwin
import Foundation

struct CodexManagedAccountViewModel: Identifiable, Equatable, Sendable {
  let id: UUID
  let email: String
  let workspaceLabel: String?
  let isCurrentSystemAccount: Bool
  let subscription: CodexSubscriptionMetadata?
  var accountKey: String? = nil
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
  case targetIdentityMismatch
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
    case .targetIdentityMismatch: "该账号的凭据与保存的信息不一致，请重新添加账号。"
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
  @Published private(set) var currentSubscription: CodexSubscriptionMetadata?
  @Published private(set) var lastErrorMessage: String?

  private let paths: CodexAccountPaths
  private let fileManager: FileManager
  private let environment: [String: String]
  private let store: FileManagedCodexAccountStore
  private let loginRunner: LoginRunner
  private var lastKnownSubscriptions: [UUID: CodexSubscriptionMetadata] = [:]

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
      let liveState = Self.readAuthState(homeURL: self.paths.liveHomeURL)
      let liveFingerprint =
        liveState?.fingerprint
        ?? CodexAuthFingerprint.fingerprint(
          homePath: self.paths.liveHomeURL.path,
          fileManager: self.fileManager)
      self.currentSystemEmail = live?.email
      var currentAccountID: UUID?
      self.accounts = stored.accounts.sorted { $0.updatedAt > $1.updatedAt }.map { account in
        let isCurrent = Self.matchesLiveAccount(
          account,
          live: live,
          liveFingerprint: liveFingerprint)
        if isCurrent { currentAccountID = account.id }

        let accountState: CodexAuthState?
        if isCurrent {
          accountState = liveState
        } else {
          accountState = Self.readAuthState(
            homeURL: URL(fileURLWithPath: account.managedHomePath, isDirectory: true))
        }
        let subscription = self.subscription(
          for: account.id,
          state: accountState)
        return CodexManagedAccountViewModel(
          id: account.id,
          email: account.email,
          workspaceLabel: account.workspaceLabel,
          isCurrentSystemAccount: isCurrent,
          subscription: subscription,
          accountKey: accountState?.identity?.cacheKey)
      }
      self.currentSubscription =
        liveState?.subscription
        ?? currentAccountID.flatMap { self.lastKnownSubscriptions[$0]?.markingCached() }
      self.lastErrorMessage = nil
    } catch {
      self.accounts = []
      self.currentSubscription = nil
      self.lastErrorMessage = error.localizedDescription
    }
  }

  func synchronizeLiveCredentials() {
    guard !self.isBusy else { return }
    do {
      let stored = try self.store.loadAccounts()
      let liveURL = self.paths.liveHomeURL.appendingPathComponent("auth.json")
      guard let liveData = try? Data(contentsOf: liveURL),
        let key = CodexAuthIdentityReader.identity(from: liveData)?.cacheKey,
        let existing = stored.accounts.first(where: {
          guard let id = $0.providerAccountID else { return false }
          return CodexAuthIdentity.cacheKey(accountID: id, workspaceID: $0.workspaceAccountID)
            == key
        })
      else { return }
      try self.validateManagedHome(existing.managedHomePath)
      let backupURL = URL(fileURLWithPath: existing.managedHomePath).appendingPathComponent(
        "auth.json")
      guard (try? Data(contentsOf: backupURL)) != liveData else { return }
      guard (try? Data(contentsOf: liveURL)) == liveData else { return }
      try Self.atomicReplaceAuth(
        liveData, liveHomeURL: backupURL.deletingLastPathComponent(), fileManager: self.fileManager)
      guard (try? Data(contentsOf: liveURL)) == liveData,
        CodexAuthIdentityReader(fileURL: backupURL).read()?.cacheKey == key
      else { return }
      let now = Date().timeIntervalSince1970
      let refreshed = ManagedCodexAccount(
        id: existing.id, email: existing.email, providerAccountID: existing.providerAccountID,
        workspaceLabel: existing.workspaceLabel, workspaceAccountID: existing.workspaceAccountID,
        authFingerprint: CodexAuthFingerprint.fingerprint(data: liveData),
        managedHomePath: existing.managedHomePath,
        createdAt: existing.createdAt, updatedAt: now, lastAuthenticatedAt: now)
      try self.store.storeAccounts(
        ManagedCodexAccountSet(
          version: FileManagedCodexAccountStore.currentVersion,
          accounts: stored.accounts.map { $0.id == existing.id ? refreshed : $0 }))
    } catch {
      self.lastErrorMessage = "登录副本同步失败，原登录保持不变"
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

    guard
      let targetIdentity = Self.readIdentity(
        homeURL: URL(fileURLWithPath: target.managedHomePath, isDirectory: true),
        environment: self.environment),
      Self.matchesLiveAccount(target, live: targetIdentity, liveFingerprint: nil)
    else {
      throw CodexAccountManagerError.targetIdentityMismatch
    }

    let liveAuthURL = self.paths.liveHomeURL.appendingPathComponent("auth.json")
    let previousLiveData: Data?
    if self.fileManager.fileExists(atPath: liveAuthURL.path) {
      guard let data = try? Data(contentsOf: liveAuthURL), !data.isEmpty else {
        throw CodexAccountManagerError.liveAuthUnreadable
      }
      previousLiveData = data
    } else {
      previousLiveData = nil
    }

    let targetFingerprint = CodexAuthFingerprint.fingerprint(data: targetData)
    let liveFingerprint = previousLiveData.map { CodexAuthFingerprint.fingerprint(data: $0) }
    if targetFingerprint == liveFingerprint {
      self.reload()
      return
    }

    var updatedAccounts = snapshot.accounts
    var createdLiveAccountHomePath: String?
    if liveFingerprint != nil {
      let preserved = try self.preserveLiveAccount(in: updatedAccounts)
      updatedAccounts = preserved.accounts
      createdLiveAccountHomePath = preserved.createdHomePath
    }

    do {
      try Self.atomicReplaceAuth(
        targetData,
        liveHomeURL: self.paths.liveHomeURL,
        fileManager: self.fileManager)

      guard
        let activeIdentity = Self.readIdentity(
          homeURL: self.paths.liveHomeURL, environment: self.environment),
        Self.matchesLiveAccount(target, live: activeIdentity, liveFingerprint: targetFingerprint)
      else {
        throw CodexAccountManagerError.targetIdentityMismatch
      }

      if liveFingerprint != nil {
        try self.store.storeAccounts(
          ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: updatedAccounts))
      }
    } catch {
      if let previousLiveData {
        try? Self.atomicReplaceAuth(
          previousLiveData,
          liveHomeURL: self.paths.liveHomeURL,
          fileManager: self.fileManager)
      }
      if let createdLiveAccountHomePath {
        try? self.removeManagedHomeIfSafe(createdLiveAccountHomePath)
      }
      if let accountError = error as? CodexAccountManagerError,
        accountError == .targetIdentityMismatch
      {
        throw accountError
      }
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
    -> (accounts: [ManagedCodexAccount], createdHomePath: String?)
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
      try self.validateManagedHome(existing.managedHomePath)
      let managedHomeURL = URL(
        fileURLWithPath: existing.managedHomePath,
        isDirectory: true)
      try Self.atomicReplaceAuth(
        liveData,
        liveHomeURL: managedHomeURL,
        fileManager: self.fileManager)
      let now = Date().timeIntervalSince1970
      let refreshed = ManagedCodexAccount(
        id: existing.id,
        email: existing.email,
        providerAccountID: existing.providerAccountID ?? providerID,
        workspaceLabel: existing.workspaceLabel,
        workspaceAccountID: existing.workspaceAccountID,
        authFingerprint: liveFingerprint,
        managedHomePath: existing.managedHomePath,
        createdAt: existing.createdAt,
        updatedAt: now,
        lastAuthenticatedAt: now)
      let updatedAccounts = accounts.map { $0.id == existing.id ? refreshed : $0 }
      return (updatedAccounts, nil)
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
      return (accounts + [account], homeURL.path)
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
    let fetcher = UsageFetcher(environment: env)
    let account: CodexAuthBackedAccount
    if CodexCredentialFileAccess.isTestContext {
      let authURL = homeURL.appendingPathComponent("auth.json")
      account = CodexCredentialFileAccess.withFixtureScope(.init(files: [authURL])) {
        fetcher.loadAuthBackedCodexAccount()
      }
    } else {
      account = fetcher.loadAuthBackedCodexAccount()
    }
    guard account.identity != .unresolved || account.email != nil else { return nil }
    return account
  }

  nonisolated private static func readAuthState(homeURL: URL) -> CodexAuthState? {
    CodexSubscriptionMetadataReader.read(
      authFileURL: homeURL.appendingPathComponent("auth.json", isDirectory: false))
  }

  private func subscription(
    for accountID: UUID,
    state: CodexAuthState?
  ) -> CodexSubscriptionMetadata? {
    if let subscription = state?.subscription {
      self.lastKnownSubscriptions[accountID] = subscription
      return subscription
    }
    return self.lastKnownSubscriptions[accountID]?.markingCached()
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
    timeout: TimeInterval = 30
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

private final class CodexProcessOutputCapture: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()
  private var data = Data()

  init(pipe: Pipe) {
    self.handle = pipe.fileHandleForReading
  }

  func start() {
    self.handle.readabilityHandler = { [weak self] handle in
      self?.appendAvailableData(from: handle)
    }
  }

  func finish() -> Data {
    self.handle.readabilityHandler = nil
    let remaining = self.handle.readDataToEndOfFile()
    self.append(remaining)
    self.lock.lock()
    let result = self.data
    self.lock.unlock()
    return result
  }

  private func appendAvailableData(from handle: FileHandle) {
    let data = handle.availableData
    guard !data.isEmpty else { return }
    self.append(data)
  }

  private func append(_ data: Data) {
    guard !data.isEmpty else { return }
    self.lock.lock()
    self.data.append(data)
    self.lock.unlock()
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
      env["PATH"] = PathBuilder.effectivePATH(
        purposes: [.rpc, .tty, .nodeTooling],
        env: env)
      guard let executable = Self.findCodex(environment: env) else {
        return Result(outcome: .missingBinary, output: "")
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable, "login"]
      process.environment = env
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      let stdoutCapture = CodexProcessOutputCapture(pipe: stdout)
      let stderrCapture = CodexProcessOutputCapture(pipe: stderr)
      do {
        try process.run()
      } catch {
        return Result(outcome: .launchFailed, output: error.localizedDescription)
      }
      let processGroup = Self.attachProcessGroup(process)
      stdoutCapture.start()
      stderrCapture.start()

      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if process.isRunning {
        Self.terminate(process, processGroup: processGroup)
        return Result(
          outcome: .timedOut,
          output: Self.combinedOutput(
            stdout: stdoutCapture.finish(), stderr: stderrCapture.finish()))
      }
      let text = Self.combinedOutput(
        stdout: stdoutCapture.finish(), stderr: stderrCapture.finish())
      return Result(
        outcome: process.terminationStatus == 0 ? .success : .failed,
        output: text)
    }.value
  }

  private static func combinedOutput(stdout: Data, stderr: Data) -> String {
    let out = String(decoding: stdout, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let err = String(decoding: stderr, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let combined: String
    if !out.isEmpty, !err.isEmpty {
      combined = [out, err].joined(separator: "\n")
    } else {
      combined = out + err
    }
    return String(combined.prefix(4000))
  }

  private static func attachProcessGroup(_ process: Process) -> pid_t? {
    let pid = process.processIdentifier
    return setpgid(pid, pid) == 0 ? pid : nil
  }

  private static func terminate(_ process: Process, processGroup: pid_t?) {
    if let processGroup {
      kill(-processGroup, SIGTERM)
    }
    if process.isRunning {
      process.terminate()
    }

    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline {
      usleep(100_000)
    }

    if process.isRunning {
      if let processGroup {
        kill(-processGroup, SIGKILL)
      }
      kill(process.processIdentifier, SIGKILL)
    }
  }

  private static func findCodex(environment: [String: String]) -> String? {
    if let resolved = BinaryLocator.resolveCodexBinary(env: environment) {
      return resolved
    }
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
