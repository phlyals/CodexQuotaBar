import Foundation

private struct QuotaRefreshOutcome: Sendable {
  let provider: QuotaProvider
  let snapshot: QuotaSnapshot?
  let errorDescription: String?
  let wasCancelled: Bool
}

enum GoogleQuotaBinding: Equatable {
  case ambient
  case saved(email: String)
  case unreadable

  var accountKey: String? {
    if case .saved(let email) = self { return email.lowercased() }
    return nil
  }

  func accepts(_ snapshot: QuotaSnapshot) -> Bool {
    guard snapshot.provider == .antigravity else { return false }
    switch self {
    case .ambient:
      return snapshot.source == GoogleQuotaSource.ambientCLI && snapshot.accountEmail == nil
    case .saved:
      return [GoogleQuotaSource.remote, GoogleQuotaSource.scopedCLI, GoogleQuotaSource.remoteAndScopedCLI].contains(snapshot.source)
        && snapshot.accountKey == self.accountKey
        && snapshot.accountEmail?.lowercased() == self.accountKey
    case .unreadable:
      return false
    }
  }

  @MainActor
  init(manager: GoogleAccountManager) {
    if manager.loadError != nil {
      self = .unreadable
    } else if let account = manager.selectedAccount {
      self = .saved(email: account.email)
    } else {
      self = .ambient
    }
  }
}

enum QuotaRefreshPolicy {
  static func isDue(
    lastAttemptAt: Date?,
    now: Date,
    refreshInterval: TimeInterval
  ) -> Bool {
    guard let lastAttemptAt else { return true }
    return now.timeIntervalSince(lastAttemptAt) >= refreshInterval
  }
}

@MainActor
final class QuotaStore: ObservableObject {
  static let defaultRefreshInterval: TimeInterval = 60
  static let ambientGoogleRefreshInterval: TimeInterval = 300
  static let defaultStaleAfter: TimeInterval = 300

  @Published private(set) var snapshots: [QuotaProvider: QuotaSnapshot] = [:]
  @Published private(set) var refreshingProviders: Set<QuotaProvider> = []
  @Published private(set) var lastRefreshAttempt: Date?

  var isRefreshing: Bool { !self.refreshingProviders.isEmpty }

  private let fetcher: any QuotaFetching
  private let cacheStore: QuotaCacheStore
  private let refreshInterval: TimeInterval
  private let staleAfter: TimeInterval
  private let identityProvider: @MainActor () -> String?
  private let googleBinding: @MainActor () -> GoogleQuotaBinding
  private var failureCounts: [QuotaProvider: Int] = [:]
  private var activeProviders: Set<QuotaProvider> = [.codex]
  private var lastAttemptByProvider: [QuotaProvider: Date] = [:]
  private var lastCompletionByProvider: [QuotaProvider: Date] = [:]
  private var inFlightTasks: [QuotaProvider: Task<Void, Never>] = [:]
  private var inFlightTokens: [QuotaProvider: UUID] = [:]
  private var timerTask: Task<Void, Never>?
  private var hasStarted = false

  init(
    fetcher: any QuotaFetching = CodexBarQuotaFetcher(),
    cacheStore: QuotaCacheStore = QuotaCacheStore(),
    refreshInterval: TimeInterval = QuotaStore.defaultRefreshInterval,
    staleAfter: TimeInterval = QuotaStore.defaultStaleAfter,
    googleBinding: @escaping @MainActor () -> GoogleQuotaBinding = { .ambient },
    identityProvider: @escaping @MainActor () -> String? = {
      CodexAuthIdentityReader().read()?.cacheKey
    }
  ) {
    self.fetcher = fetcher
    self.cacheStore = cacheStore
    self.refreshInterval = refreshInterval
    self.staleAfter = staleAfter
    self.identityProvider = identityProvider
    self.googleBinding = googleBinding

    let now = Date()
    self.snapshots = Dictionary(
      cacheStore.load().filter { snapshot in
        if snapshot.provider == .codex {
          return snapshot.accountKey != nil && snapshot.accountKey == identityProvider()
        }
        return googleBinding().accepts(snapshot)
      }.map { snapshot in
        (snapshot.provider, snapshot.markingCached(now: now, staleAfter: staleAfter))
      }, uniquingKeysWith: { first, second in first.updatedAt > second.updatedAt ? first : second })
  }

  func start() {
    guard !self.hasStarted else { return }
    self.hasStarted = true
    self.refresh(providers: self.activeProviders, force: false)
  }

  func stop() {
    self.timerTask?.cancel()
    self.timerTask = nil
    for task in self.inFlightTasks.values {
      task.cancel()
    }
    self.inFlightTasks.removeAll()
    self.inFlightTokens.removeAll()
    self.hasStarted = false
    self.refreshingProviders.removeAll()
  }

  func setActiveProviders(_ providers: Set<QuotaProvider>) {
    guard providers != self.activeProviders else { return }

    let newlyEnabled = providers.subtracting(self.activeProviders)
    let newlyDisabled = self.activeProviders.subtracting(providers)
    self.activeProviders = providers

    if !newlyDisabled.isEmpty {
      for provider in newlyDisabled {
        self.inFlightTasks[provider]?.cancel()
        self.inFlightTasks.removeValue(forKey: provider)
        self.inFlightTokens.removeValue(forKey: provider)
        self.refreshingProviders.remove(provider)
        self.snapshots.removeValue(forKey: provider)
        self.lastAttemptByProvider.removeValue(forKey: provider)
        self.lastCompletionByProvider.removeValue(forKey: provider)
      }
      self.cacheStore.save(Array(self.snapshots.values))
    }

    guard self.hasStarted else { return }
    self.refresh(providers: newlyEnabled, force: false)
    self.scheduleNextRefresh()
  }

  func refresh() {
    self.refresh(providers: self.activeProviders, force: true)
  }

  func refresh(_ provider: QuotaProvider) {
    self.refresh(providers: [provider], force: true)
  }

  func refreshIfStale(maxAge: TimeInterval = 15) {
    let now = Date()
    let due = self.activeProviders.filter { provider in
      guard self.inFlightTasks[provider] == nil else { return false }
      let lastRefresh = max(
        self.lastAttemptByProvider[provider] ?? .distantPast,
        self.lastCompletionByProvider[provider] ?? .distantPast)
      let effectiveMaxAge = self.staleRefreshAge(for: provider, maxAge: maxAge)
      return now.timeIntervalSince(lastRefresh) >= effectiveMaxAge
    }
    guard !due.isEmpty else { return }
    self.refresh(providers: due, force: true)
  }

  func forceRefreshAll() {
    for provider in self.activeProviders {
      self.cancelInFlightRefresh(provider)
    }
    self.refresh(providers: self.activeProviders, force: true)
  }

  func invalidateAndRefresh(_ provider: QuotaProvider) {
    self.cancelInFlightRefresh(provider)
    self.snapshots.removeValue(forKey: provider)
    self.lastAttemptByProvider.removeValue(forKey: provider)
    self.lastCompletionByProvider.removeValue(forKey: provider)
    self.failureCounts.removeValue(forKey: provider)
    self.cacheStore.save(Array(self.snapshots.values))
    self.refresh(providers: [provider], force: true)
  }

  func cancelInFlightRefresh(_ provider: QuotaProvider) {
    self.inFlightTasks[provider]?.cancel()
    self.inFlightTasks.removeValue(forKey: provider)
    self.inFlightTokens.removeValue(forKey: provider)
    self.refreshingProviders.remove(provider)
    self.scheduleNextRefresh()
  }

  func snapshot(for provider: QuotaProvider) -> QuotaSnapshot? {
    self.snapshots[provider]
  }

  private func refresh(providers: Set<QuotaProvider>, force: Bool) {
    guard self.hasStarted else { return }

    let now = Date()
    for provider in providers where self.activeProviders.contains(provider) {
      if provider == .codex,
        let previous = self.snapshots[provider],
        previous.accountKey != self.identityProvider()
      {
        self.cancelInFlightRefresh(provider)
        self.snapshots.removeValue(forKey: provider)
        self.lastAttemptByProvider.removeValue(forKey: provider)
        self.lastCompletionByProvider.removeValue(forKey: provider)
      }
      guard self.inFlightTasks[provider] == nil else { continue }
      guard
        force
          || QuotaRefreshPolicy.isDue(
            lastAttemptAt: self.lastAttemptByProvider[provider],
            now: now,
            refreshInterval: self.retryInterval(provider))
      else {
        continue
      }
      self.startRefresh(provider: provider, now: now)
    }
    self.scheduleNextRefresh()
  }

  private func startRefresh(provider: QuotaProvider, now: Date) {
    let token = UUID()
    let fetcher = self.fetcher

    self.lastAttemptByProvider[provider] = now
    self.lastRefreshAttempt = now
    let accountKey: String?
    if provider == .codex {
      guard let codexKey = self.identityProvider() else {
        self.snapshots.removeValue(forKey: provider)
        self.applyFailure(provider: provider, message: "login required", now: now)
        self.cacheStore.save(Array(self.snapshots.values))
        return
      }
      accountKey = codexKey
    } else {
      accountKey = self.googleBinding().accountKey
    }
    self.inFlightTokens[provider] = token

    self.inFlightTasks[provider] = Task { [weak self] in
      let outcome: QuotaRefreshOutcome
      do {
        let snapshot = try await Self.fetchWithTimeout(
          provider: provider, fetcher: fetcher, timeoutSeconds: 45)
        outcome = QuotaRefreshOutcome(
          provider: provider,
          snapshot: snapshot,
          errorDescription: nil,
          wasCancelled: false)
      } catch is CancellationError {
        outcome = QuotaRefreshOutcome(
          provider: provider,
          snapshot: nil,
          errorDescription: nil,
          wasCancelled: true)
      } catch {
        outcome = QuotaRefreshOutcome(
          provider: provider,
          snapshot: nil,
          errorDescription: error.localizedDescription,
          wasCancelled: false)
      }

      guard let self else { return }
      self.finishRefresh(outcome, token: token, accountKey: accountKey)
    }
    self.refreshingProviders.insert(provider)
  }

  private enum FetchTimeoutError: LocalizedError {
    case timedOut
    var errorDescription: String? { "request timed out" }
  }

  private static func fetchWithTimeout(
    provider: QuotaProvider,
    fetcher: any QuotaFetching,
    timeoutSeconds: TimeInterval
  ) async throws -> QuotaSnapshot {
    try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
      group.addTask {
        try await fetcher.fetch(provider)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw FetchTimeoutError.timedOut
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  private func finishRefresh(_ outcome: QuotaRefreshOutcome, token: UUID, accountKey: String?) {
    guard self.inFlightTokens[outcome.provider] == token else { return }

    self.inFlightTasks.removeValue(forKey: outcome.provider)
    self.inFlightTokens.removeValue(forKey: outcome.provider)

    let currentKey = outcome.provider == .codex ? self.identityProvider() : self.googleBinding().accountKey
    if currentKey != accountKey {
      self.invalidateAndRefresh(outcome.provider)
      return
    }

    let now = Date()
    self.lastCompletionByProvider[outcome.provider] = now
    if !outcome.wasCancelled {
      if let snapshot = outcome.snapshot {
        let matchesIdentity = outcome.provider == .codex
          ? snapshot.provider == .codex && (snapshot.accountKey == nil || snapshot.accountKey == accountKey)
          : self.googleBinding().accepts(snapshot)
        if matchesIdentity {
          var updated = snapshot.replacing(
            freshness: snapshot.freshness, message: snapshot.message,
            accountKey: accountKey ?? snapshot.accountKey)
          if outcome.provider == .codex,
            let check = updated.subscriptionCheck, check.metadata == nil, check.message != nil,
            let previous = self.snapshots[outcome.provider], previous.accountKey == accountKey,
            let metadata = previous.subscriptionCheck?.metadata
          {
            updated.subscriptionCheck = CodexSubscriptionCheck(
              metadata: metadata.markingCached(), attemptedAt: check.attemptedAt,
              message: check.message)
          }
          self.snapshots[outcome.provider] = updated
          self.failureCounts[outcome.provider] = 0
        } else {
          self.applyFailure(provider: outcome.provider, message: "账号身份不一致，等待重新同步", now: now)
        }
      } else if let message = outcome.errorDescription {
        self.failureCounts[outcome.provider, default: 0] += 1
        self.applyFailure(provider: outcome.provider, message: message, now: now)
      }
      self.cacheStore.save(Array(self.snapshots.values))
    }

    self.refreshingProviders.remove(outcome.provider)
    self.scheduleNextRefresh()
  }

  private func scheduleNextRefresh() {
    self.timerTask?.cancel()
    self.timerTask = nil

    guard self.hasStarted else { return }

    let now = Date()
    let nextDate = self.activeProviders.compactMap { provider -> Date? in
      guard self.inFlightTasks[provider] == nil else { return nil }
      guard let lastAttempt = self.lastAttemptByProvider[provider] else { return now }
      return lastAttempt.addingTimeInterval(self.retryInterval(provider))
    }.min()

    guard let nextDate else { return }
    let delay = max(0.05, nextDate.timeIntervalSince(now))
    self.timerTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      self.timerTask = nil
      self.refresh(providers: self.activeProviders, force: false)
    }
  }

  private func usesAmbientInterval(_ provider: QuotaProvider) -> Bool {
    provider == .antigravity && self.googleBinding() == .ambient
      && self.refreshInterval == Self.defaultRefreshInterval
  }

  func staleRefreshAge(for provider: QuotaProvider, maxAge: TimeInterval) -> TimeInterval {
    self.usesAmbientInterval(provider) ? max(maxAge, 45) : maxAge
  }

  func retryInterval(_ provider: QuotaProvider) -> TimeInterval {
    let baseInterval = self.usesAmbientInterval(provider) ? Self.ambientGoogleRefreshInterval : self.refreshInterval
    return min(
      900, baseInterval * pow(2, Double(min(3, self.failureCounts[provider, default: 0]))))
  }

  private func applyFailure(provider: QuotaProvider, message: String, now: Date) {
    let displayMessage = self.userFacingMessage(provider: provider, message: message)
    if let previous = self.snapshots[provider], previous.hasQuotaData,
      provider == .codex || self.googleBinding().accepts(previous)
    {
      let retained = previous.markingFailure(
        displayMessage,
        now: now,
        staleAfter: self.staleAfter)
      self.snapshots[provider] =
        Self.failureState(message) == .authRequired
        ? retained.replacing(
          freshness: .authRequired,
          message: displayMessage)
        : retained
      return
    }

    self.snapshots[provider] = QuotaSnapshot(
      provider: provider,
      session: nil,
      weekly: nil,
      resetCredits: nil,
      accountEmail: nil,
      accountKey: provider == .codex ? self.identityProvider() : self.googleBinding().accountKey,
      source: "auto",
      updatedAt: now,
      freshness: Self.failureState(message),
      message: displayMessage)
  }

  private static func failureState(_ message: String) -> QuotaFreshness {
    if message == GoogleAccountError.invalidIdentity.localizedDescription
      || message == GoogleOAuthError.invalidToken.localizedDescription { return .authRequired }
    let lower = message.lowercased()
    let authMarkers = [
      "401", "unauthorized", "token", "credential", "api key", "login", "log in", "authenticate",
      "scope", "invalid_grant",
    ]
    return authMarkers.contains(where: lower.contains) ? .authRequired : .unavailable
  }

  private func userFacingMessage(provider: QuotaProvider, message: String) -> String {
    switch provider {
    case .codex:
      return switch Self.failureState(message) {
      case .authRequired:
        "登录已失效，请重新登录 Codex"
      default:
        "额度读取失败，保留上次数据；请稍后刷新"
      }
    case .antigravity:
      if message == QuotaFetchError.unsupportedAgyVersion.localizedDescription
        || message == GoogleAccountError.invalidIdentity.localizedDescription { return message }
      switch self.googleBinding() {
      case .unreadable:
        return "无法读取本机 Google 账号文件，已暂停额度查询"
      case .saved:
        return Self.failureState(message) == .authRequired
          ? "Google 授权已失效，请重新添加该邮箱"
          : "所选 Google 账号的额度暂时不可用，请稍后刷新"
      case .ambient:
        break
      }
      return switch Self.failureState(message) {
      case .authRequired:
        "Antigravity 未登录，请在终端运行 agy 登录后刷新"
      default:
        "新版 Antigravity 需安装官方 CLI（brew install --cask antigravity-cli）并运行 agy 登录"
      }
    }
  }
}
