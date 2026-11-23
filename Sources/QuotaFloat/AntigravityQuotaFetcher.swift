import CodexBarCore
import Foundation

struct AntigravityQuotaFetcher: Sendable {
  let environment: [String: String]
  var dataLoader: GoogleOAuth.Transport = GoogleOAuth.transport
  var refresh: @Sendable (AntigravityOAuthCredentials) async throws -> AntigravityOAuthCredentials =
    {
      try await GoogleOAuth.refresh($0)
    }
  var userEmail: @Sendable (String) async throws -> String = {
    try await GoogleOAuth.userEmail(accessToken: $0)
  }

  func fetch(manager: GoogleAccountManager?) async throws -> QuotaSnapshot {
    try Task.checkCancellation()
    guard let manager, let account = try await manager.accountForFetch() else {
      let snapshot = try await self.fetchCLI(grant: nil, plan: nil)
      try Task.checkCancellation()
      guard try await manager?.accountForFetch() == nil else { throw CancellationError() }
      return snapshot
    }

    let grant = await SelectedGoogleGrant(account: account, manager: manager, userEmail: self.userEmail)
    let credentials = try await self.freshCredentials(for: grant)
    let value = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
    let remote = AntigravityRemoteUsageFetcher(
      timeout: 12, environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: value],
      dataLoader: { request in
        try Task.checkCancellation()
        // A passive quota check must never enroll the user in a Cloud Code tier.
        guard request.url?.path != "/v1internal:onboardUser" else { throw URLError(.unsupportedURL) }
        return try await self.dataLoader(request)
      }, oauthClientResolver: { nil },
      credentialsUpdateHandler: { updated in try await grant.save(updated) })

    var partial: QuotaSnapshot?
    var remoteError: Error?
    var plan: String?
    do {
      let status = try await remote.fetch()
      try await grant.checkSelection()
      try grant.validateEmail(status.accountEmail)
      plan = status.accountPlan
      let snapshot = try CodexBarQuotaFetcher.mapAntigravityUsage(
        status.toUsageSnapshot(), email: grant.email)
      if snapshot.session != nil && snapshot.weekly != nil { return snapshot }
      partial = snapshot
    } catch {
      try await grant.checkSelection()
      if Self.isCancellation(error) { throw error }
      if case GoogleAccountError.invalidIdentity = error { throw error }
      remoteError = error
    }

    do {
      let snapshot = try await self.fetchCLI(grant: grant, plan: plan)
      try await grant.checkSelection()
      guard let partial, snapshot.session == nil || snapshot.weekly == nil else { return snapshot }
      if (snapshot.session == nil) == (partial.session == nil) { return partial }
      // Both sources proved the same email. Timestamp the pair by its older observation.
      return QuotaSnapshot(
        provider: .antigravity, session: partial.session ?? snapshot.session,
        weekly: partial.weekly ?? snapshot.weekly, extraWindows: partial.extraWindows ?? snapshot.extraWindows,
        resetCredits: nil, accountEmail: grant.email, accountKey: grant.email.lowercased(),
        accountPlan: plan, source: GoogleQuotaSource.remoteAndScopedCLI,
        updatedAt: min(partial.updatedAt, snapshot.updatedAt), freshness: .fresh, message: nil)
    } catch {
      try await grant.checkSelection()
      if Self.isCancellation(error) { throw error }
      if let partial { return partial }
      if case SubprocessRunnerError.binaryNotFound = error, let remoteError { throw remoteError }
      throw error
    }
  }

  private func freshCredentials(for grant: SelectedGoogleGrant) async throws
    -> AntigravityOAuthCredentials
  {
    let current = try await grant.current()
    if let expiry = current.expiryDate, expiry.timeIntervalSinceNow > 60,
      current.accessToken?.isEmpty == false
    {
      try await grant.verifyBearer(current.accessToken)
      return current
    }
    let updated = try await self.refresh(current)
    try await grant.save(updated)
    return try await grant.current()
  }

  private func fetchCLI(grant: SelectedGoogleGrant?, plan: String?) async throws -> QuotaSnapshot {
    let binary = try self.agyBinary()
    let credentials: AntigravityOAuthCredentials?
    if let grant {
      credentials = try await self.freshCredentials(for: grant)
    } else {
      credentials = nil
    }
    try Task.checkCancellation()
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "QuotaFloat-agy-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let tokenFile = root.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    var child = self.environment
    var staged: AgyFileToken?
    if let credentials {
      let token = try AgyFileToken(credentials: credentials)
      staged = token
      try fm.createDirectory(
        at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoded = try JSONEncoder().encode(token)
      guard
        fm.createFile(atPath: tokenFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else {
        throw CocoaError(.fileWriteUnknown)
      }
      let file = try FileHandle(forWritingTo: tokenFile)
      do { try file.write(contentsOf: encoded) } catch {
        try? file.close()
        throw error
      }
      try file.close()
      let allowed = [
        "PATH", "LANG", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
      ]
      child = self.environment.filter { allowed.contains($0.key) }
      child["HOME"] = root.path
      child["PWD"] = root.path
      child["SSH_TTY"] = "quotafloat-scoped"
    }
    for name in ["open", "xdg-open"] {
      let path = root.appendingPathComponent(name).path
      guard
        fm.createFile(
          atPath: path, contents: Data("#!/bin/sh\nexit 1\n".utf8),
          attributes: [.posixPermissions: 0o700])
      else { throw CocoaError(.fileWriteUnknown) }
    }
    child["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
    child["BROWSER"] = "/usr/bin/false"
    let inheritedPath = child["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    child["PATH"] = ([root.path, inheritedPath, "/opt/homebrew/bin", "/usr/local/bin"]).joined(
      separator: ":")
    let output: SubprocessResult
    do {
      let version = try await SubprocessRunner.run(
        binary: binary, arguments: ["--version"], environment: child, timeout: 3,
        maxOutputBytes: 4096, standardInput: FileHandle.nullDevice, currentDirectoryURL: root,
        reapDescendants: true, label: "antigravity-agy-version")
      let components = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ".", omittingEmptySubsequences: false)
      guard components.count == 3, let major = UInt(components[0]), let minor = UInt(components[1]),
        let patch = UInt(components[2]), (major, minor, patch) >= (1, 1, 11)
      else { throw QuotaFetchError.unsupportedAgyVersion }
      output = try await SubprocessRunner.run(
        binary: binary, arguments: ["-p", "/usage", "--output-format", "json"],
        environment: child, timeout: 30, maxOutputBytes: 2_000_000,
        standardInput: FileHandle.nullDevice, currentDirectoryURL: grant == nil ? nil : root,
        reapDescendants: true, label: "antigravity-agy-usage")
    } catch SubprocessRunnerError.nonZeroExit(let code, _) {
      // The CLI owns stderr and could include authentication details.
      throw SubprocessRunnerError.nonZeroExit(code: code, stderr: "")
    }
    try Task.checkCancellation()
    let snapshot = try CodexBarQuotaFetcher.parseAgyUsageJSON(
      output.stdout, email: grant?.email, plan: plan)
    if let grant, let credentials, let staged {
      let effective = try JSONDecoder().decode(AgyFileToken.self, from: Data(contentsOf: tokenFile))
      try await grant.verifyBearer(effective.token.accessToken, force: true)
      if effective != staged {
        let updated = try effective.updating(credentials)
        try await grant.save(updated)
      }
    }
    return snapshot
  }

  private func agyBinary() throws -> String {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    if let explicit = self.environment["ANTIGRAVITY_CLI_PATH"], !explicit.isEmpty {
      guard explicit.hasPrefix("/"), fm.isExecutableFile(atPath: explicit)
      else { throw SubprocessRunnerError.binaryNotFound("agy") }
      return explicit
    }
    var candidates = [
      "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
      home.appendingPathComponent(".local/bin/agy").path,
    ]
    candidates += (self.environment["PATH"] ?? "").split(separator: ":")
      .filter { $0.hasPrefix("/") }.map { "\($0)/agy" }
    guard
      let binary = candidates.first(where: { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) })
    else { throw SubprocessRunnerError.binaryNotFound("agy") }
    return binary
  }

  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }
}

@MainActor
private final class SelectedGoogleGrant {
  nonisolated let email: String
  private let id: UUID
  private let manager: GoogleAccountManager
  private var credentials: AntigravityOAuthCredentials
  private var writeError: Error?

  private let userEmail: @Sendable (String) async throws -> String

  init(account: ManagedGoogleAccount, manager: GoogleAccountManager,
    userEmail: @escaping @Sendable (String) async throws -> String) {
    self.email = account.email
    self.userEmail = userEmail
    self.id = account.id
    self.manager = manager
    self.credentials = account.credentials
  }

  nonisolated func validateEmail(_ value: String?) throws {
    guard let value,
      value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(self.email)
        == .orderedSame
    else { throw GoogleAccountError.invalidIdentity }
  }

  func checkSelection() throws {
    try Task.checkCancellation()
    if let writeError { throw writeError }
    guard let current = try self.manager.accountForFetch(), current.id == self.id,
      current.credentials == self.credentials
    else { throw CancellationError() }
    try self.validateEmail(current.credentials.resolvedAccountEmail)
  }

  func verifyBearer(_ token: String?, force: Bool = false) async throws {
    try self.checkSelection()
    try await self.manager.verifyBearer(token, for: self.id, force: force, lookup: self.userEmail)
    try self.checkSelection()
  }

  func current() throws -> AntigravityOAuthCredentials {
    try self.checkSelection()
    return self.credentials
  }

  // CodexBar may save a refresh and a newly discovered project in the same fetch.
  func save(_ updated: AntigravityOAuthCredentials) async throws {
    do {
      try await self.verifyBearer(updated.accessToken)
      try self.validateEmail(updated.resolvedAccountEmail)
      try self.manager.updateCredentials(
        for: self.id, credentials: updated, replacing: self.credentials)
      self.credentials = updated
    } catch {
      self.writeError = error
      throw error
    }
  }
}

// Mirrors agy's file-token wire format. The CLI can rewrite this file when it refreshes the grant.
private struct AgyFileToken: Codable, Equatable {
  struct Token: Codable, Equatable {
    let accessToken: String
    let tokenType: String
    let refreshToken: String
    let expiry: String
    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case tokenType = "token_type"
      case refreshToken = "refresh_token"
      case expiry
    }
  }

  let token: Token
  let authMethod: String
  let idToken: String?
  enum CodingKeys: String, CodingKey {
    case token
    case authMethod = "auth_method"
    case idToken = "id_token"
  }

  init(credentials: AntigravityOAuthCredentials) throws {
    guard let access = credentials.accessToken, !access.isEmpty,
      let refresh = credentials.refreshToken, !refresh.isEmpty,
      let expiry = credentials.expiryDate
    else { throw AntigravityRemoteFetchError.notLoggedIn }
    self.token = Token(
      accessToken: access, tokenType: "Bearer", refreshToken: refresh,
      expiry: expiry.ISO8601Format())
    self.authMethod = "consumer"
    self.idToken = credentials.idToken
  }

  func updating(_ original: AntigravityOAuthCredentials) throws -> AntigravityOAuthCredentials {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard self.authMethod == "consumer",
      self.token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
      !self.token.accessToken.isEmpty, !self.token.refreshToken.isEmpty,
      let expiry = fractional.date(from: self.token.expiry)
        ?? ISO8601DateFormatter().date(from: self.token.expiry)
    else { throw AntigravityRemoteFetchError.notLoggedIn }
    var updated = original
    updated.accessToken = self.token.accessToken
    updated.refreshToken = self.token.refreshToken
    updated.expiryDateMilliseconds = expiry.timeIntervalSince1970 * 1000
    updated.idToken = self.idToken ?? original.idToken
    return updated
  }
}
