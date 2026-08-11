import Combine
import Foundation

@MainActor
final class CodexDashboardStore: ObservableObject {
  @Published private(set) var quota: QuotaSnapshot?
  @Published private(set) var currentAccountEmail: String?
  @Published private(set) var subscription: CodexSubscriptionMetadata?
  @Published private(set) var localUsage: CodexLocalUsageSnapshot?
  @Published private(set) var isLoadingLocalUsage = false
  @Published private(set) var localUsageMessage: String?

  private let quotaStore: QuotaStore
  private let localUsageFetcher: any CodexLocalUsageFetching
  private var localUsageTask: Task<Void, Never>?
  private var localUsageToken: UUID?
  private var cancellables: Set<AnyCancellable> = []

  init(
    quotaStore: QuotaStore,
    accountManager: CodexAccountManager? = nil,
    localUsageFetcher: any CodexLocalUsageFetching = CodexCostHelper()
  ) {
    self.quotaStore = quotaStore
    self.localUsageFetcher = localUsageFetcher
    self.quota = quotaStore.snapshot(for: .codex)
    self.currentAccountEmail = accountManager?.currentSystemEmail
    self.subscription = accountManager?.currentSubscription
    quotaStore.$snapshots
      .map { $0[.codex] }
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.quota = $0 }
      .store(in: &self.cancellables)
    if let accountManager {
      accountManager.$currentSubscription
        .combineLatest(accountManager.$currentSystemEmail)
        .receive(on: RunLoop.main)
        .sink { [weak self] subscription, email in
          self?.subscription = subscription
          self?.currentAccountEmail = email
        }
        .store(in: &self.cancellables)
    }
  }

  func refreshLocalUsage(force: Bool = false) {
    if force {
      self.cancelLocalUsageRefresh()
    } else {
      guard self.localUsageTask == nil else { return }
    }
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
        self.localUsageMessage = error.localizedDescription
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
    self.cancelLocalUsageRefresh()
  }

  private func finishLocalUsageRefresh(token: UUID) {
    guard self.localUsageToken == token else { return }
    self.localUsageTask = nil
    self.localUsageToken = nil
    self.isLoadingLocalUsage = false
  }
}
