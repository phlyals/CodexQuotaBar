import Foundation

private struct QuotaRefreshOutcome: Sendable {
  let provider: QuotaProvider
  let snapshot: QuotaSnapshot?
  let errorDescription: String?
  let wasCancelled: Bool
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
  static let defaultRefreshInterval: TimeInterval = 120
  static let defaultStaleAfter: TimeInterval = 300

  @Published private(set) var snapshots: [QuotaProvider: QuotaSnapshot] = [:]
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastRefreshAttempt: Date?

  private let fetcher: any QuotaFetching
  private let cacheStore: QuotaCacheStore
  private let refreshInterval: TimeInterval
  private let staleAfter: TimeInterval
  private let identityProvider: @MainActor () -> String?
  private var failureCounts: [QuotaProvider: Int] = [:]
  private var activeProviders: Set<QuotaProvider> = [.codex]
  private var lastAttemptByProvider: [QuotaProvider: Date] = [:]
  private var inFlightTasks: [QuotaProvider: Task<Void, Never>] = [:]
  private var inFlightTokens: [QuotaProvider: UUID] = [:]
  private var timerTask: Task<Void, Never>?
  private var hasStarted = false

  init(
    fetcher: any QuotaFetching = CodexBarQuotaFetcher(),
    cacheStore: QuotaCacheStore = QuotaCacheStore(),
    refreshInterval: TimeInterval = QuotaStore.defaultRefreshInterval,
    staleAfter: TimeInterval = QuotaStore.defaultStaleAfter,
    identityProvider: @escaping @MainActor () -> String? = {
      CodexAuthIdentityReader().read()?.cacheKey
    }
  ) {
    self.fetcher = fetcher
    self.cacheStore = cacheStore
    self.refreshInterval = refreshInterval
    self.staleAfter = staleAfter
    self.identityProvider = identityProvider

    let now = Date()
    self.snapshots = Dictionary(
      cacheStore.load().filter { snapshot in
        if snapshot.provider == .codex {
          return snapshot.accountKey != nil && snapshot.accountKey == identityProvider()
        }
        return true
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
    self.isRefreshing = false
  }

  func setActiveProviders(_ providers: Set<QuotaProvider>) {
    guard providers != self.activeProviders else { return }

    let newlyEnabled = providers.subtracting(self.activeProviders)
    self.activeProviders = providers

    guard self.hasStarted else { return }
    self.refresh(providers: newlyEnabled, force: false)
    self.scheduleNextRefresh()
  }

  func refresh() {
    self.refresh(providers: self.activeProviders, force: true)
  }

  func invalidateAndRefresh(_ provider: QuotaProvider) {
    self.cancelInFlightRefresh(provider)
    self.snapshots.removeValue(forKey: provider)
    self.lastAttemptByProvider.removeValue(forKey: provider)
    self.cacheStore.save(Array(self.snapshots.values))
    self.refresh(providers: [provider], force: true)
  }

  func cancelInFlightRefresh(_ provider: QuotaProvider) {
    self.inFlightTasks[provider]?.cancel()
    self.inFlightTasks.removeValue(forKey: provider)
    self.inFlightTokens.removeValue(forKey: provider)
    self.isRefreshing = !self.inFlightTasks.isEmpty
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
      accountKey = nil
    }
    self.inFlightTokens[provider] = token
    self.isRefreshing = true

    self.inFlightTasks[provider] = Task { [weak self] in
      let outcome: QuotaRefreshOutcome
      do {
        let snapshot = try await fetcher.fetch(provider)
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
  }

  private func finishRefresh(_ outcome: QuotaRefreshOutcome, token: UUID, accountKey: String?) {
    guard self.inFlightTokens[outcome.provider] == token else { return }

    self.inFlightTasks.removeValue(forKey: outcome.provider)
    self.inFlightTokens.removeValue(forKey: outcome.provider)

    if outcome.provider == .codex, self.identityProvider() != accountKey {
      self.snapshots.removeValue(forKey: outcome.provider)
      self.lastAttemptByProvider.removeValue(forKey: outcome.provider)
      self.isRefreshing = !self.inFlightTasks.isEmpty
      self.refresh(providers: [outcome.provider], force: true)
      return
    }

    if !outcome.wasCancelled {
      let now = Date()
      if let snapshot = outcome.snapshot {
        if outcome.provider != .codex || snapshot.accountKey == nil
          || snapshot.accountKey == accountKey
        {
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

    self.isRefreshing = !self.inFlightTasks.isEmpty
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

  private func retryInterval(_ provider: QuotaProvider) -> TimeInterval {
    min(
      900, self.refreshInterval * pow(2, Double(min(3, self.failureCounts[provider, default: 0]))))
  }

  private func applyFailure(provider: QuotaProvider, message: String, now: Date) {
    if let previous = self.snapshots[provider], previous.hasQuotaData {
      let retained = previous.markingFailure(
        Self.userFacingMessage(provider: provider, message: message),
        now: now,
        staleAfter: self.staleAfter)
      self.snapshots[provider] =
        Self.failureState(message) == .authRequired
        ? retained.replacing(
          freshness: .authRequired,
          message: Self.userFacingMessage(provider: provider, message: message))
        : retained
      return
    }

    self.snapshots[provider] = QuotaSnapshot(
      provider: provider,
      session: nil,
      weekly: nil,
      resetCredits: nil,
      accountEmail: nil,
      accountKey: provider == .codex ? self.identityProvider() : "antigravity",
      source: "auto",
      updatedAt: now,
      freshness: Self.failureState(message),
      message: Self.userFacingMessage(provider: provider, message: message))
  }

  private static func failureState(_ message: String) -> QuotaFreshness {
    let lower = message.lowercased()
    let authMarkers = [
      "401", "unauthorized", "token", "credential", "api key", "login", "log in", "authenticate",
      "scope",
    ]
    return authMarkers.contains(where: lower.contains) ? .authRequired : .unavailable
  }

  private static func userFacingMessage(provider: QuotaProvider, message: String) -> String {
    switch provider {
    case .codex:
      return switch Self.failureState(message) {
      case .authRequired:
        "登录已失效，请重新登录 Codex"
      default:
        "额度读取失败，保留上次数据；请稍后刷新"
      }
    case .antigravity:
      return switch Self.failureState(message) {
      case .authRequired:
        "未检测到 Antigravity 登录状态"
      default:
        "Google 额度暂不可用，请确认 Antigravity 已运行或已登录"
      }
    }
  }
}
