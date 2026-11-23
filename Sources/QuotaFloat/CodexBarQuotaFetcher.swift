import CodexBarCore
import Foundation

protocol QuotaFetching: Sendable {
  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot
}

enum QuotaFetchError: LocalizedError, Sendable {
  case noQuotaWindows(QuotaProvider)
  case unsupportedAgyVersion

  var errorDescription: String? {
    switch self {
    case .unsupportedAgyVersion:
      "查询额度需要 agy 1.1.11 或以上版本，请更新 Antigravity CLI。"
    case .noQuotaWindows(let provider):
      "\(provider.displayName) 没有返回 5 小时或周额度。"
    }
  }
}

struct CodexBarQuotaFetcher: QuotaFetching {
  private let baseEnvironment: [String: String]

  private let googleAccountManager: GoogleAccountManager?

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    googleAccountManager: GoogleAccountManager? = nil
  ) {
    self.baseEnvironment = environment
    self.googleAccountManager = googleAccountManager
  }

  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot {
    switch provider {
    case .codex:
      return try await self.fetchCodex()
    case .antigravity:
      return try await AntigravityQuotaFetcher(environment: self.baseEnvironment).fetch(
        manager: self.googleAccountManager)
    }
  }

  private func fetchCodex() async throws -> QuotaSnapshot {
    let environment = self.baseEnvironment
    let authURL = CodexAuthIdentityReader.defaultAuthFileURL(environment: environment)
    let reader = CodexAuthIdentityReader(fileURL: authURL)
    guard let initialState = reader.readState(), let accountKey = initialState.identity?.cacheKey
    else {
      throw CodexOAuthCredentialsError.missingTokens
    }
    var credentials = try CodexOAuthCredentialsStore.load(env: environment)
    var didRefresh = false
    var fingerprint = initialState.fingerprint
    if credentials.needsRefresh, !credentials.refreshToken.isEmpty {
      credentials = try await CodexTokenRefresher.refresh(credentials)
      try Task.checkCancellation()
      // Never write refreshed credentials over an externally switched or rotated login.
      try await Self.persistRefreshedCredentials(
        credentials, authURL: authURL, expectedFingerprint: fingerprint, expectedKey: accountKey)
      fingerprint = reader.readState()?.fingerprint
      didRefresh = true
    }
    let response: CodexUsageResponse
    do {
      response = try await CodexOAuthUsageFetcher.fetchUsage(
        accessToken: credentials.accessToken, accountId: credentials.accountId, env: environment)
    } catch CodexOAuthFetchError.unauthorized where !didRefresh && !credentials.refreshToken.isEmpty
    {
      guard reader.readState()?.fingerprint == fingerprint else { throw CancellationError() }
      credentials = try await CodexTokenRefresher.refresh(credentials)
      try Task.checkCancellation()
      try await Self.persistRefreshedCredentials(
        credentials, authURL: authURL, expectedFingerprint: fingerprint, expectedKey: accountKey)
      response = try await CodexOAuthUsageFetcher.fetchUsage(
        accessToken: credentials.accessToken, accountId: credentials.accountId, env: environment)
    }
    let resets = try? await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
      accessToken: credentials.accessToken, accountId: credentials.accountId, env: environment)
    try Task.checkCancellation()
    guard reader.read()?.cacheKey == accountKey else { throw CancellationError() }
    var snapshot = try Self.mapResponse(
      response, credentials: credentials, resets: resets, accountKey: accountKey)
    if let accountID = credentials.accountId {
      snapshot.subscriptionCheck = try await CodexSubscriptionFetcher.shared.fetch(
        accessToken: credentials.accessToken, accountID: accountID, accountKey: accountKey)
    }
    try Task.checkCancellation()
    guard reader.read()?.cacheKey == accountKey else { throw CancellationError() }
    return snapshot
  }

  private struct AgyUsageEnvelope: Decodable {
    struct CommandPayload: Decodable {
      struct DataPayload: Decodable {
        struct Group: Decodable {
          struct Bucket: Decodable {
            let id: String
            let name: String
            let disabled: Bool?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?

          }
          let name: String
          let buckets: [Bucket]
        }
        let groups: [Group]
        let email: String?
        let accountEmail: String?
      }
      let name: String?
      let data: DataPayload?
    }
    let status: String?
    let email: String?
    let accountEmail: String?
    let command: CommandPayload?
  }

  static func parseAgyUsageJSON(
    _ stdout: String, email: String? = nil, plan: String? = nil, now: Date = Date()
  ) throws -> QuotaSnapshot {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let startIdx = trimmed.firstIndex(of: "{"), let endIdx = trimmed.lastIndex(of: "}"),
      startIdx <= endIdx else {
      throw QuotaFetchError.noQuotaWindows(.antigravity)
    }
    let jsonSlice = String(trimmed[startIdx...endIdx])
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let envelope = try decoder.decode(AgyUsageEnvelope.self, from: Data(jsonSlice.utf8))
    guard envelope.status?.uppercased() == "SUCCESS", envelope.command?.name == "usage",
      let groups = envelope.command?.data?.groups, !groups.isEmpty
    else {
      throw QuotaFetchError.noQuotaWindows(.antigravity)
    }

    if let email {
      let identities = [envelope.email, envelope.accountEmail, envelope.command?.data?.email,
        envelope.command?.data?.accountEmail].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      guard identities.allSatisfy({ $0.isEmpty || $0.caseInsensitiveCompare(email) == .orderedSame }) else {
        throw GoogleAccountError.invalidIdentity
      }
    }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallbackISO = ISO8601DateFormatter()
    fallbackISO.formatOptions = [.withInternetDateTime]

    func makeWindow(_ bucket: AgyUsageEnvelope.CommandPayload.DataPayload.Group.Bucket) -> QuotaWindow? {
      guard bucket.disabled != true, let fraction = bucket.remainingFraction,
        (0...1).contains(fraction) else { return nil }
      // agy /usage and the Antigravity settings page show the nearest whole percent.
      let remaining = (fraction * 100).rounded()
      let resetDate = bucket.resetTime.flatMap { isoFormatter.date(from: $0) ?? fallbackISO.date(from: $0) }
      let minutes: Int? =
        switch (bucket.window?.lowercased(), bucket.id.lowercased()) {
        case ("5h", _), (nil, "gemini-5h"): 300
        case ("weekly", _), (nil, "gemini-weekly"): 10_080
        default: nil
        }
      return QuotaWindow(usedPercent: 100 - remaining, resetsAt: resetDate, windowMinutes: minutes)
    }

    var session: QuotaWindow?
    var weekly: QuotaWindow?
    var extras: [QuotaNamedWindow] = []

    for group in groups {
      for bucket in group.buckets {
        guard let window = makeWindow(bucket) else { continue }
        let id = bucket.id.lowercased()
        if id == "gemini-5h", window.windowMinutes == 300 {
          session = window
        } else if id == "gemini-weekly", window.windowMinutes == 10_080 {
          weekly = window
        } else {
          let rawTitle = "\(group.name) \(bucket.name)"
          extras.append(
            QuotaNamedWindow(
              id: bucket.id,
              title: Self.localizedAntigravityTitle(id: bucket.id, rawTitle: rawTitle),
              window: window))
        }
      }
    }

    let snapshot = QuotaSnapshot(
      provider: .antigravity,
      session: session,
      weekly: weekly,
      extraWindows: extras.isEmpty ? nil : extras,
      resetCredits: nil,
      accountEmail: email,
      accountKey: email?.lowercased() ?? "antigravity-cli",
      accountPlan: plan,
      source: email == nil ? GoogleQuotaSource.ambientCLI : GoogleQuotaSource.scopedCLI,
      updatedAt: now,
      freshness: .fresh,
      message: nil)
    guard session != nil || weekly != nil else { throw QuotaFetchError.noQuotaWindows(.antigravity) }
    return snapshot
  }

  static func mapAntigravityUsage(_ usage: UsageSnapshot, email: String) throws -> QuotaSnapshot {
    let windows = (usage.extraRateWindows ?? []).filter { $0.usageKnown }
    var session: QuotaWindow?
    var weekly: QuotaWindow?
    var extras: [QuotaNamedWindow] = []
    for named in windows {
      guard let valid = Self.mapWindow(named.window, assumedMinutes: nil) else { continue }
      let window = QuotaWindow(
        usedPercent: 100 - valid.remainingPercent.rounded(), resetsAt: valid.resetsAt,
        windowMinutes: valid.windowMinutes)
      // CodexBar's primary/secondary may represent a model family, not a time window.
      let id = named.id.lowercased().replacingOccurrences(of: "_", with: "-")
      switch (id, window.windowMinutes) {
      case ("antigravity-quota-summary-gemini-5h", 300),
           ("antigravity-quota-summary-gemini-session", 300),
           ("antigravity-quota-summary-gemini-5-hour", 300),
           ("antigravity-quota-summary-gemini-five-hour", 300):
        session = window
      case ("antigravity-quota-summary-gemini-weekly", 10_080):
        weekly = window
      default:
        extras.append(QuotaNamedWindow(
          id: named.id, title: Self.localizedAntigravityTitle(id: named.id, rawTitle: named.title),
          window: window))
      }
    }
    guard session != nil || weekly != nil else { throw QuotaFetchError.noQuotaWindows(.antigravity) }
    return QuotaSnapshot(
      provider: .antigravity, session: session, weekly: weekly,
      extraWindows: extras.isEmpty ? nil : extras, resetCredits: nil,
      accountEmail: email, accountKey: email.lowercased(), accountPlan: usage.identity?.loginMethod,
      source: GoogleQuotaSource.remote, updatedAt: usage.updatedAt, freshness: .fresh, message: nil)
  }

  private static func localizedAntigravityTitle(id: String, rawTitle: String) -> String {
    let lowerID = id.lowercased()
    let lowerTitle = rawTitle.lowercased()
    if lowerID.contains("3p-5h")
      || ((lowerTitle.contains("claude") || lowerTitle.contains("gpt")) && lowerTitle.contains("five hour"))
    {
      return "Claude / GPT 5 小时"
    }
    if lowerID.contains("3p-weekly")
      || ((lowerTitle.contains("claude") || lowerTitle.contains("gpt")) && lowerTitle.contains("weekly"))
    {
      return "Claude / GPT 周额度"
    }
    if lowerTitle.contains("argon") && lowerTitle.contains("weekly") {
      return "Gemini 4 Argon 周额度"
    }
    if lowerTitle.contains("argon") && lowerTitle.contains("five hour") {
      return "Gemini 4 Argon 5 小时"
    }
    return rawTitle
  }

  @MainActor
  static func persistRefreshedCredentials(
    _ credentials: CodexOAuthCredentials, authURL: URL,
    expectedFingerprint: String?, expectedKey: String
  ) throws {
    guard let expectedFingerprint, let original = try? Data(contentsOf: authURL),
      CodexAuthFingerprint.fingerprint(data: original) == expectedFingerprint,
      var json = try JSONSerialization.jsonObject(with: original) as? [String: Any],
      var tokens = json["tokens"] as? [String: Any]
    else { throw CancellationError() }
    tokens["access_token"] = credentials.accessToken
    tokens["refresh_token"] = credentials.refreshToken
    if let idToken = credentials.idToken { tokens["id_token"] = idToken }
    if let accountID = credentials.accountId { tokens["account_id"] = accountID }
    json["tokens"] = tokens
    json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    guard CodexAuthIdentityReader.identity(from: data)?.cacheKey == expectedKey,
      (try? Data(contentsOf: authURL)) == original
    else { throw CancellationError() }
    try CodexAccountManager.atomicReplaceAuth(
      data, liveHomeURL: authURL.deletingLastPathComponent(), fileManager: .default)
  }

  static func mapResponse(
    _ response: CodexUsageResponse, credentials: CodexOAuthCredentials,
    resets: CodexRateLimitResetCreditsSnapshot?, accountKey: String, now: Date = Date()
  ) throws -> QuotaSnapshot {
    let reconciled = CodexReconciledState.fromOAuth(
      response: response, credentials: credentials, updatedAt: now)
    let usage = reconciled?.toUsageSnapshot()
    let sparkWindows = usage.map(Self.mapSparkWindows) ?? Self.mapStandaloneSpark(response)
    let identity = CodexReconciledState.oauthIdentity(response: response, credentials: credentials)
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: reconciled?.session.flatMap { Self.mapWindow($0, assumedMinutes: nil) },
      weekly: reconciled?.weekly.flatMap { Self.mapWindow($0, assumedMinutes: nil) },
      sparkSession: sparkWindows.session,
      sparkWeekly: sparkWindows.weekly,
      creditsRemaining: response.credits?.balance,
      creditsUnlimited: response.credits?.unlimited,
      creditsUpdatedAt: response.credits == nil ? nil : now,
      resetCredits: Self.mapResetCredits(resets),
      accountEmail: identity.accountEmail,
      accountKey: accountKey,
      accountPlan: identity.loginMethod,
      source: "oauth",
      updatedAt: now,
      freshness: .fresh,
      message: resets == nil ? "重置券读取失败或未提供，次数未知" : nil)
    guard snapshot.hasQuotaData else { throw QuotaFetchError.noQuotaWindows(.codex) }
    return snapshot
  }

  static func mapWindows(
    _ usage: UsageSnapshot,
    definition: QuotaProviderDefinition
  ) -> (
    session: QuotaWindow?, weekly: QuotaWindow?
  ) {
    let candidates = [usage.primary, usage.secondary, usage.tertiary].compactMap { $0 }

    let sessionSource: (window: RateWindow, assumedMinutes: Int?)? =
      candidates.first { window in
        guard let minutes = window.windowMinutes else { return false }
        return minutes > 0 && minutes <= 6 * 60
      }
      .map { ($0, nil) }
      ?? Self.fallbackWindow(
        usage: usage,
        fallback: definition.sessionFallback)

    let weeklySource: (window: RateWindow, assumedMinutes: Int?)? =
      candidates.first { window in
        guard let minutes = window.windowMinutes else { return false }
        return minutes >= 6 * 24 * 60 && minutes <= 8 * 24 * 60
      }
      .map { ($0, nil) }
      ?? Self.fallbackWindow(
        usage: usage,
        fallback: definition.weeklyFallback)

    return (
      session: sessionSource.flatMap {
        Self.mapWindow($0.window, assumedMinutes: $0.assumedMinutes)
      },
      weekly: weeklySource.flatMap { Self.mapWindow($0.window, assumedMinutes: $0.assumedMinutes) }
    )
  }

  private static func mapStandaloneSpark(_ response: CodexUsageResponse) -> (
    session: QuotaWindow?, weekly: QuotaWindow?
  ) {
    let entries = (response.additionalRateLimits ?? []).filter {
      [$0.limitName, $0.meteredFeature].compactMap { $0 }.joined(separator: " ").lowercased()
        .contains("spark")
    }
    var session: QuotaWindow?
    var weekly: QuotaWindow?
    for entry in entries {
      for value in [entry.rateLimit?.primaryWindow, entry.rateLimit?.secondaryWindow].compactMap({
        $0
      }) {
        guard (0...100).contains(value.usedPercent), value.limitWindowSeconds > 0 else { continue }
        let window = QuotaWindow(
          usedPercent: Double(value.usedPercent),
          resetsAt: value.resetAt > 0 ? Date(timeIntervalSince1970: Double(value.resetAt)) : nil,
          windowMinutes: value.limitWindowSeconds / 60)
        if value.limitWindowSeconds <= 6 * 3600 {
          session = session ?? window
        } else if value.limitWindowSeconds >= 6 * 86400 {
          weekly = weekly ?? window
        }
      }
    }
    return (session, weekly)
  }

  private static func fallbackWindow(
    usage: UsageSnapshot,
    fallback: QuotaWindowFallback
  ) -> (window: RateWindow, assumedMinutes: Int?)? {
    let window: RateWindow? =
      switch fallback.lane {
      case .primary: usage.primary
      case .secondary: usage.secondary
      case .tertiary: usage.tertiary
      }
    guard let window, window.windowMinutes == nil else { return nil }
    return (window, fallback.assumedMinutes)
  }

  private static func mapWindow(
    _ window: RateWindow,
    assumedMinutes: Int?
  ) -> QuotaWindow? {
    guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { return nil }
    return QuotaWindow(
      usedPercent: window.usedPercent,
      resetsAt: window.resetsAt.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil },
      windowMinutes: window.windowMinutes ?? assumedMinutes)
  }

  static func mapSparkWindows(_ usage: UsageSnapshot) -> (
    session: QuotaWindow?, weekly: QuotaWindow?
  ) {
    let candidates = (usage.extraRateWindows ?? []).filter { window in
      [window.id, window.title]
        .joined(separator: " ")
        .lowercased()
        .contains("spark")
    }

    func identity(for window: NamedRateWindow) -> String {
      [window.id, window.title]
        .joined(separator: " ")
        .lowercased()
    }

    var weekly: NamedRateWindow?
    var session: NamedRateWindow?
    for candidate in candidates {
      let value = identity(for: candidate)
      if weekly == nil, value.contains("weekly") || value.contains("week") {
        weekly = candidate
      }
      if session == nil,
        value.contains("5-hour") || value.contains("5 hour") || value.contains("5h")
      {
        session = candidate
      }
    }
    if weekly == nil {
      for candidate in candidates {
        guard let minutes = candidate.window.windowMinutes else { continue }
        if minutes >= 6 * 24 * 60 {
          weekly = candidate
          break
        }
      }
    }
    if session == nil {
      for candidate in candidates {
        guard let minutes = candidate.window.windowMinutes else { continue }
        if minutes > 0, minutes <= 6 * 60 {
          session = candidate
          break
        }
      }
    }

    return (
      session: session.flatMap { Self.mapWindow($0.window, assumedMinutes: nil) },
      weekly: weekly.flatMap { Self.mapWindow($0.window, assumedMinutes: nil) }
    )
  }

  private static func mapResetCredits(
    _ snapshot: CodexRateLimitResetCreditsSnapshot?
  ) -> QuotaResetCredits? {
    guard let snapshot else { return nil }
    let expirationDates = snapshot.credits.compactMap { credit -> Date? in
      guard
        credit.status == .available,
        let expiresAt = credit.expiresAt,
        expiresAt > snapshot.updatedAt
      else {
        return nil
      }
      return expiresAt
    }
    var result = QuotaResetCredits(
      availableCount: snapshot.availableCount,
      expirationDates: expirationDates)
    result.details = snapshot.credits.map {
      QuotaResetCredit(
        id: $0.id, status: $0.status.rawValue, expiresAt: $0.expiresAt,
        scope: $0.title ?? $0.resetType)
    }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    return result
  }

}
