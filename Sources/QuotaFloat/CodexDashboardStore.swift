import Combine
import Foundation

@MainActor
final class CodexDashboardStore: ObservableObject {
  @Published private(set) var quota: QuotaSnapshot?
  @Published private(set) var googleQuota: QuotaSnapshot?
  @Published private(set) var refreshingProviders: Set<QuotaProvider>
  @Published private(set) var currentAccountEmail: String?
  @Published private(set) var subscription: CodexSubscriptionMetadata?
  @Published private(set) var localUsage: CodexLocalUsageSnapshot?
  @Published private(set) var isLoadingLocalUsage = false
  @Published private(set) var localUsageMessage: String?
  @Published private(set) var now = Date()
  private(set) var lastLocalAttempt: Date?

  var isRefreshing: Bool { !self.refreshingProviders.isEmpty }
  var isRefreshingCodex: Bool { self.refreshingProviders.contains(.codex) }
  var isRefreshingGoogle: Bool { self.refreshingProviders.contains(.antigravity) }

  var effectiveSubscription: CodexSubscriptionMetadata? {
    CodexSubscriptionCheck.resolve(
      record: subscription, snapshot: quota, accountKey: quota?.accountKey)
  }

  private let quotaStore: QuotaStore
  private let localUsageFetcher: any CodexLocalUsageFetching
  private var localUsageTask: Task<Void, Never>?
  private var localUsageToken: UUID?
  private var timerTask: Task<Void, Never>?
  private var lastBoundaryKey: String?
  private var cancellables: Set<AnyCancellable> = []

  init(
    quotaStore: QuotaStore,
    accountManager: CodexAccountManager? = nil,
    localUsageFetcher: any CodexLocalUsageFetching = CodexCostHelper()
  ) {
    self.quotaStore = quotaStore
    self.localUsageFetcher = localUsageFetcher
    self.quota = quotaStore.snapshot(for: .codex)
    self.googleQuota = quotaStore.snapshot(for: .antigravity)
    self.refreshingProviders = quotaStore.refreshingProviders
    self.currentAccountEmail = accountManager?.currentSystemEmail
    self.subscription = accountManager?.currentSubscription
    quotaStore.$snapshots
      .receive(on: DispatchQueue.main)
      .sink { [weak self] snapshots in
        self?.quota = snapshots[.codex]
        self?.googleQuota = snapshots[.antigravity]
      }
      .store(in: &self.cancellables)
    quotaStore.$refreshingProviders
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.refreshingProviders = $0 }
      .store(in: &self.cancellables)
    if let accountManager {
      accountManager.$currentSubscription
        .combineLatest(accountManager.$currentSystemEmail)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] subscription, email in
          self?.subscription = subscription
          self?.currentAccountEmail = email
        }
        .store(in: &self.cancellables)
    }
  }

  func start() {
    guard self.timerTask == nil else { return }
    self.tick()
    self.timerTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        guard !Task.isCancelled else { return }
        self?.tick()
      }
    }
  }

  func tick(now: Date = Date(), menuOpened: Bool = false) {
    self.now = now
    if let quota = self.quota, let key = quota.accountKey {
      let dates =
        [quota.session?.resetsAt, quota.weekly?.resetsAt].compactMap { $0 }
        + (quota.resetCredits?.expirationDates ?? [])
      if let crossed = dates.filter({ $0 <= now && $0 >= quota.updatedAt }).max() {
        let boundaryKey = "\(key):\(crossed.timeIntervalSince1970)"
        if self.lastBoundaryKey != boundaryKey {
          self.lastBoundaryKey = boundaryKey
          self.quotaStore.refresh()
        }
      }
    }
    let interval: TimeInterval = menuOpened ? 60 : 120
    let crossedDay =
      self.localUsage?.updatedAt.map {
        !Calendar.current.isDate($0, inSameDayAs: now)
      } ?? false
    if self.lastLocalAttempt == nil
      || now.timeIntervalSince(self.lastLocalAttempt!) >= interval
      || (crossedDay && now.timeIntervalSince(self.lastLocalAttempt!) >= 30)
    {
      self.refreshLocalUsage()
    }
  }

  func refreshLocalUsage(force: Bool = false) {
    guard self.localUsageTask == nil else { return }
    self.lastLocalAttempt = Date()
    let fetcher = self.localUsageFetcher
    let token = UUID()
    self.isLoadingLocalUsage = true
    self.localUsageMessage = nil
    self.localUsageToken = token
    self.localUsageTask = Task { [weak self] in
      do {
        let snapshot = try await fetcher.fetch(forceRefresh: force)
        guard let self, !Task.isCancelled, self.localUsageToken == token else { return }
        self.localUsage = snapshot
        self.localUsageMessage = nil
        self.finishLocalUsageRefresh(token: token)
      } catch is CancellationError {
        self?.finishLocalUsageRefresh(token: token)
      } catch {
        guard let self, self.localUsageToken == token else { return }
        self.localUsageMessage = "本机用量读取失败，显示上次扫描结果"
        self.finishLocalUsageRefresh(token: token)
      }
    }
  }

  func cancelLocalUsageRefresh() {
    self.localUsageTask?.cancel()
    self.localUsageTask = nil
    self.localUsageToken = nil
    self.isLoadingLocalUsage = false
  }

  func stop() {
    self.timerTask?.cancel()
    self.timerTask = nil
    self.cancelLocalUsageRefresh()
  }

  private func finishLocalUsageRefresh(token: UUID) {
    guard self.localUsageToken == token else { return }
    self.localUsageTask = nil
    self.localUsageToken = nil
    self.isLoadingLocalUsage = false
  }
}
