import CodexBarCore
import Combine
import Darwin
import Foundation

struct ManagedGoogleAccount: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let email: String
  var credentials: AntigravityOAuthCredentials
  let addedAt: Date
  var lastUpdatedAt: Date
}

enum GoogleAccountError: LocalizedError {
  case unavailable, invalidIdentity, missingAccount, staleCredentials, loginInProgress, writeFailed

  var errorDescription: String? {
    switch self {
    case .unavailable: "无法读取 QuotaFloat 的 Google 账号文件。请检查文件内容和读取权限。"
    case .invalidIdentity: "Google 凭据的邮箱与账号不匹配，请重新登录。"
    case .missingAccount: "Google 账号已移除。"
    case .staleCredentials: "账号凭据已更新，请重新刷新。"
    case .loginInProgress: "已有 Google 登录正在进行。"
    case .writeFailed: "无法保存 Google 账号。请检查 QuotaFloat 数据目录的写入权限。"
    }
  }
}

@MainActor
final class GoogleAccountManager: ObservableObject {
  private struct State: Codable {
    var accounts: [ManagedGoogleAccount] = []
    var selectedAccountID: UUID?
  }

  @Published private var state = State()
  @Published private(set) var isBusy = false
  private var verifiedBearer: (id: UUID, token: String)?
  private(set) var loadError: String?
  var onSelectionChange: (@MainActor () -> Void)?
  private let fileURL: URL
  private let login: @MainActor () async throws -> AntigravityOAuthCredentials

  var accounts: [ManagedGoogleAccount] { state.accounts }
  var selectedAccountID: UUID? { state.selectedAccountID }
  var selectedAccount: ManagedGoogleAccount? { accounts.first { $0.id == selectedAccountID } }

  init(
    fileURL: URL = URL.applicationSupportDirectory.appending(
      path: "QuotaFloat/google-accounts.json"),
    login: @escaping @MainActor () async throws -> AntigravityOAuthCredentials = {
      try await GoogleOAuth.login()
    }
  ) {
    self.fileURL = fileURL
    self.login = login
    do {
      if let saved = try Self.read(fileURL) { state = saved }
    } catch {
      loadError = GoogleAccountError.unavailable.localizedDescription
    }
  }

  func accountForFetch() throws -> ManagedGoogleAccount? {
    guard loadError == nil else { throw GoogleAccountError.unavailable }
    return selectedAccount
  }

  // Only Google userinfo can establish which mailbox an opaque access token belongs to.
  func verifyBearer(
    _ token: String?, for id: UUID, force: Bool = false,
    lookup: @Sendable (String) async throws -> String
  ) async throws {
    guard let token, !token.isEmpty, let selectedAccount, selectedAccount.id == id else {
      throw GoogleAccountError.invalidIdentity
    }
    if !force, verifiedBearer?.id == id, verifiedBearer?.token == token { return }
    let email = try await lookup(token)
    try Task.checkCancellation()
    guard self.selectedAccountID == id else { throw CancellationError() }
    guard email.caseInsensitiveCompare(selectedAccount.email) == .orderedSame else {
      throw GoogleAccountError.invalidIdentity
    }
    verifiedBearer = (id, token)
  }

  func addAccount() async throws {
    guard loadError == nil else { throw GoogleAccountError.unavailable }
    guard !isBusy else { throw GoogleAccountError.loginInProgress }
    isBusy = true
    defer { isBusy = false }
    let credentials = try await login()
    guard let email = credentials.email?.trimmingCharacters(in: .whitespacesAndNewlines),
      Self.matches(credentials, email: email)
    else { throw GoogleAccountError.invalidIdentity }

    var next = state
    let now = Date()
    if let index = next.accounts.firstIndex(where: {
      $0.email.caseInsensitiveCompare(email) == .orderedSame
    }) {
      next.accounts[index].credentials = credentials
      next.accounts[index].lastUpdatedAt = now
      next.selectedAccountID = next.accounts[index].id
    } else {
      let account = ManagedGoogleAccount(
        id: UUID(), email: email, credentials: credentials, addedAt: now, lastUpdatedAt: now)
      next.accounts.append(account)
      next.selectedAccountID = account.id
    }
    try save(next)
    // login() has just obtained this email from Google's userinfo endpoint.
    if let id = next.selectedAccountID, let token = credentials.accessToken {
      verifiedBearer = (id, token)
    }
    onSelectionChange?()
  }

  func selectAccount(id: UUID?) throws {
    guard loadError == nil else { throw GoogleAccountError.unavailable }
    guard id == nil || accounts.contains(where: { $0.id == id }) else {
      throw GoogleAccountError.missingAccount
    }
    guard selectedAccountID != id else { return }
    var next = state
    next.selectedAccountID = id
    try save(next)
    onSelectionChange?()
  }

  func removeAccount(id: UUID) throws {
    guard loadError == nil else { throw GoogleAccountError.unavailable }
    guard let index = accounts.firstIndex(where: { $0.id == id }) else {
      throw GoogleAccountError.missingAccount
    }
    var next = state
    next.accounts.remove(at: index)
    let removedSelection = next.selectedAccountID == id
    if removedSelection { next.selectedAccountID = nil }
    try save(next)
    if verifiedBearer?.id == id { verifiedBearer = nil }
    if removedSelection { onSelectionChange?() }
  }

  func updateCredentials(for id: UUID, credentials: AntigravityOAuthCredentials) throws {
    try replaceCredentials(for: id, credentials: credentials, expected: nil)
  }

  func updateCredentials(
    for id: UUID, credentials: AntigravityOAuthCredentials,
    replacing expected: AntigravityOAuthCredentials
  ) throws {
    try replaceCredentials(for: id, credentials: credentials, expected: expected)
  }

  private func replaceCredentials(
    for id: UUID, credentials: AntigravityOAuthCredentials, expected: AntigravityOAuthCredentials?
  ) throws {
    guard loadError == nil else { throw GoogleAccountError.unavailable }
    guard let index = accounts.firstIndex(where: { $0.id == id }) else {
      throw GoogleAccountError.missingAccount
    }
    let account = accounts[index]
    guard expected == nil || expected == account.credentials else {
      throw GoogleAccountError.staleCredentials
    }
    guard Self.matches(credentials, email: account.email) else {
      throw GoogleAccountError.invalidIdentity
    }
    var next = state
    next.accounts[index].credentials = credentials
    next.accounts[index].lastUpdatedAt = Date()
    try save(next)
  }

  private static func matches(_ credentials: AntigravityOAuthCredentials, email: String) -> Bool {
    !email.isEmpty && credentials.email?.caseInsensitiveCompare(email) == .orderedSame
      && credentials.resolvedAccountEmail?.caseInsensitiveCompare(email) == .orderedSame
  }

  private static func read(_ file: URL) throws -> State? {
    let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else {
      if errno == ENOENT { return nil }
      throw GoogleAccountError.unavailable
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      let data = try handle.readToEnd()
    else { throw GoogleAccountError.unavailable }
    let saved = try JSONDecoder().decode(State.self, from: data)
    let ids = Set(saved.accounts.map(\.id))
    guard ids.count == saved.accounts.count,
      Set(saved.accounts.map { $0.email.lowercased() }).count == saved.accounts.count,
      saved.accounts.allSatisfy({ matches($0.credentials, email: $0.email) }),
      saved.selectedAccountID.map(ids.contains) ?? true,
      info.st_mode & 0o777 == 0o600 || fchmod(fd, 0o600) == 0
    else { throw GoogleAccountError.unavailable }
    return saved
  }

  private func save(_ next: State) throws {
    let directory = fileURL.deletingLastPathComponent()
    let temporary = directory.appending(path: ".google-accounts-\(UUID().uuidString).tmp")
    do {
      let data = try JSONEncoder().encode(next)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw GoogleAccountError.writeFailed }
      defer { unlink(temporary.path) }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.close()
      guard rename(temporary.path, fileURL.path) == 0 else { throw GoogleAccountError.writeFailed }
    } catch {
      throw GoogleAccountError.writeFailed
    }
    state = next
  }
}
